# Deploy auth Edge Functions via Supabase Management API (no local CLI required)
# NOTE: Supabase deploy API currently returns HTTP 400 "Entrypoint path does not exist" (bug).
# Prefer: $env:SUPABASE_ACCESS_TOKEN='sbp_...'; powershell -File tools/deploy-edge-auth.ps1

param(
  [string]$ProjectRef = 'gxiofbdykxjkdgdcmsnp',
  [string]$AccessToken = $env:SUPABASE_ACCESS_TOKEN,
  [string]$Root = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
  throw 'Missing SUPABASE_ACCESS_TOKEN (Supabase Dashboard > Account > Access Tokens)'
}

Write-Host 'Preparing function bundles (_shared copies)...'
& (Join-Path $PSScriptRoot 'prepare-edge-functions.ps1') | Out-Null

function Deploy-FunctionFolder {
  param(
    [string]$Slug,
    [bool]$VerifyJwt = $false
  )

  $fnDir = Join-Path $Root "supabase\functions\$Slug"
  if (-not (Test-Path -LiteralPath $fnDir)) {
    throw "Missing function folder: $fnDir"
  }

  $tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) "kyno-$Slug-$(Get-Random).zip"
  if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }

  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::Open($tmpZip, [System.IO.Compression.ZipArchiveMode]::Create)

  try {
    Get-ChildItem -LiteralPath $fnDir -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($fnDir.Length).TrimStart('\', '/')
      $entryName = ($rel -replace '\\', '/')
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entryName) | Out-Null
    }
  } finally {
    $zip.Dispose()
  }

  $metadataPath = [System.IO.Path]::GetTempFileName() + '.json'
  $metaObj = @{
    name            = $Slug
    entrypoint_path = 'index.ts'
    verify_jwt      = $VerifyJwt
  }
  [System.IO.File]::WriteAllText($metadataPath, ($metaObj | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))

  $uri = "https://api.supabase.com/v1/projects/$ProjectRef/functions/deploy?slug=$Slug"
  Write-Host "Deploying $Slug ..."

  $out = curl.exe -s -w "`nHTTP:%{http_code}`n" -X POST $uri `
    -H "Authorization: Bearer $AccessToken" `
    -F "metadata=@$metadataPath;type=application/json" `
    -F "file=@$tmpZip;type=application/zip"
  Write-Output $out
  Remove-Item $metadataPath -Force -ErrorAction SilentlyContinue
  Remove-Item $tmpZip -Force
}

foreach ($slug in @('auth-login', 'auth-session', 'auth-logout', 'auth-set-password')) {
  Deploy-FunctionFolder -Slug $slug -VerifyJwt:$false
}

Write-Host 'Done. In Dashboard: Edge Functions > each function > Verify JWT = OFF'








