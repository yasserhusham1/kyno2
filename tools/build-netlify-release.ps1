# Build release/ zip for Netlify API deploy (includes supabase-proxy function)
# Output: release/ folder + release.zip
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$release = Join-Path $root 'release'
$zipPath = Join-Path $root 'release.zip'

Write-Host '[release] Building dist...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'build-netlify.ps1') | Out-Host

if (Test-Path -LiteralPath $release) { Remove-Item -LiteralPath $release -Recurse -Force }
New-Item -ItemType Directory -Path $release -Force | Out-Null

$dist = Join-Path $root 'dist'
if (-not (Test-Path -LiteralPath (Join-Path $dist 'index.html'))) {
  throw 'dist/index.html missing - run build-netlify.ps1 first'
}
Get-ChildItem -LiteralPath $dist -Force | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $release -Recurse -Force
}

$fnSrc = Join-Path $root 'netlify\functions'
$fnDst = Join-Path $release 'netlify\functions'
New-Item -ItemType Directory -Path $fnDst -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $fnSrc 'supabase-proxy.js') -Destination $fnDst -Force

$toml = @'
# KYNO release bundle - publish = "." (dist contents at zip root)
[build]
  publish = "."

[functions]
  directory = "netlify/functions"
  node_bundler = "esbuild"
'@
Set-Content -LiteralPath (Join-Path $release 'netlify.toml') -Value $toml -Encoding UTF8

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($release, $zipPath)

$mb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
Write-Host "[release] Ready: $release" -ForegroundColor Green
Write-Host "[release] Zip:   $zipPath ($mb MB)" -ForegroundColor Green
Write-Host 'Next: powershell -File tools/deploy-netlify-api.ps1' -ForegroundColor Yellow
