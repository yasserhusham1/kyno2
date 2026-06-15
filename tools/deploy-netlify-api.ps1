# Deploy release/ via Netlify digest API (site files + supabase-proxy function)
param(
  [string]$Token = $env:NETLIFY_AUTH_TOKEN,
  [string]$SiteName = $(if ($env:NETLIFY_SITE_NAME) { $env:NETLIFY_SITE_NAME } else { 'jazzy-gumdrop-43cf1a' }),
  [string]$SiteId = $env:NETLIFY_SITE_ID
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$release = Join-Path $root 'release'
$fnSrc = Join-Path $root 'netlify\functions\supabase-proxy.js'
$fnZipPath = Join-Path $root 'supabase-proxy-fn.zip'

function Get-FileSha1([string]$Path) {
  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return -join ($sha1.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
  } finally { $sha1.Dispose() }
}

function Get-FileSha256([string]$Path) {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return -join ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
  } finally { $sha256.Dispose() }
}

if (-not (Test-Path -LiteralPath (Join-Path $release 'index.html'))) {
  & (Join-Path $PSScriptRoot 'build-netlify-release.ps1')
} else {
  Write-Host 'Rebuilding release bundle...' -ForegroundColor Cyan
  & (Join-Path $PSScriptRoot 'build-netlify-release.ps1')
}

if ([string]::IsNullOrWhiteSpace($Token)) {
  Write-Host 'Usage: powershell -File tools/deploy-netlify-api.ps1 -Token nfp_...' -ForegroundColor Red
  exit 1
}

$headers = @{ Authorization = "Bearer $Token" }

if ([string]::IsNullOrWhiteSpace($SiteId)) {
  Write-Host "Looking up site: $SiteName ..."
  $sites = Invoke-RestMethod -Uri 'https://api.netlify.com/api/v1/sites?filter=all&per_page=100' -Headers $headers
  $match = @($sites | Where-Object { $_.name -eq $SiteName })
  if (-not $match -or $match.Count -eq 0) { throw "Site not found: $SiteName" }
  $SiteId = $match[0].id
  Write-Host "Site ID: $SiteId"
}

Write-Host '[1/4] Build function zip ...' -ForegroundColor Cyan
$fnTemp = Join-Path $root '.tmp-fn-build'
if (Test-Path -LiteralPath $fnTemp) { Remove-Item -LiteralPath $fnTemp -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $fnTemp -Force | Out-Null
Copy-Item -LiteralPath $fnSrc -Destination (Join-Path $fnTemp 'supabase-proxy.js') -Force
if (Test-Path -LiteralPath $fnZipPath) { Remove-Item -LiteralPath $fnZipPath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($fnTemp, $fnZipPath)
Remove-Item -LiteralPath $fnTemp -Recurse -Force -ErrorAction SilentlyContinue
$fnSha = Get-FileSha256 -Path $fnZipPath

Write-Host '[2/4] Create deploy digest ...' -ForegroundColor Cyan
$fileMap = @{}
Get-ChildItem -LiteralPath $release -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($release.Length).Replace('\', '/')
  if (-not $rel.StartsWith('/')) { $rel = '/' + $rel }
  $fileMap[$rel] = Get-FileSha1 -Path $_.FullName
}
Write-Host ('  Files: ' + $fileMap.Count)

$deployBody = @{
  async = $true
  files = $fileMap
  functions = @{ 'supabase-proxy' = $fnSha }
}
$json = $deployBody | ConvertTo-Json -Depth 20 -Compress
$deployUri = "https://api.netlify.com/api/v1/sites/$SiteId/deploys"
$deploy = Invoke-RestMethod -Uri $deployUri -Method Post -Headers ($headers + @{ 'Content-Type' = 'application/json' }) -Body $json
$deployId = $deploy.id
Write-Host "  Deploy ID: $deployId"

Write-Host '[3/4] Wait for manifest ...' -ForegroundColor Cyan
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Seconds 2
  $st = Invoke-RestMethod -Uri "https://api.netlify.com/api/v1/deploys/$deployId" -Headers $headers
  if ($st.state -in @('prepared', 'uploading', 'uploaded', 'ready')) { $deploy = $st; break }
  if ($st.state -eq 'error') { throw 'Netlify deploy manifest error' }
}

$required = @($deploy.required)
$reqFn = @($deploy.required_functions)
Write-Host ('  Required files: ' + $required.Count + ', functions: ' + $reqFn.Count)

Write-Host '[4/4] Upload files + function ...' -ForegroundColor Cyan
if ($required.Count -gt 0) {
  $shaToPath = @{}
  foreach ($kv in $fileMap.GetEnumerator()) { $shaToPath[$kv.Value] = $kv.Key }
  foreach ($sha in $required) {
    $webPath = $shaToPath[$sha]
    if (-not $webPath) { continue }
    $localPath = Join-Path $release ($webPath.TrimStart('/').Replace('/', '\'))
    $encPath = [Uri]::EscapeDataString($webPath).Replace('%2F', '/')
    $putUri = "https://api.netlify.com/api/v1/deploys/$deployId/files$webPath"
    $bytes = [System.IO.File]::ReadAllBytes($localPath)
    Invoke-RestMethod -Uri $putUri -Method Put -Headers ($headers + @{ 'Content-Type' = 'application/octet-stream' }) -Body $bytes | Out-Null
  }
}

if ($reqFn.Count -gt 0 -or $fnSha) {
  $fnBytes = [System.IO.File]::ReadAllBytes($fnZipPath)
  $uploaded = $false
  foreach ($rt in @('nodejs20', 'nodejs18', 'js')) {
    try {
      $fnPut = "https://api.netlify.com/api/v1/deploys/$deployId/functions/supabase-proxy?runtime=$rt"
      Invoke-RestMethod -Uri $fnPut -Method Put -Headers ($headers + @{ 'Content-Type' = 'application/zip' }) -Body $fnBytes | Out-Null
      Write-Host "  Function uploaded (runtime=$rt)" -ForegroundColor Green
      $uploaded = $true
      break
    } catch {
      Write-Host ('  runtime=' + $rt + ': ' + $_.Exception.Message) -ForegroundColor Yellow
    }
  }
  if (-not $uploaded) { throw 'Function upload failed' }
}

Write-Host 'Waiting for ready ...' -ForegroundColor Cyan
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Seconds 3
  $st = Invoke-RestMethod -Uri "https://api.netlify.com/api/v1/deploys/$deployId" -Headers $headers
  Write-Host "  state=$($st.state)"
  if ($st.state -eq 'ready') { $deploy = $st; break }
  if ($st.state -eq 'error') { throw 'Deploy failed' }
}

Write-Host ''
Write-Host 'Done!' -ForegroundColor Green
Write-Host ('  https://' + $SiteName + '.netlify.app/sb/functions/v1/auth-session')
