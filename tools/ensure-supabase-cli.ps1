# Ensure supabase.exe is available; returns full path to executable.
param(
  [string]$InstallDir = (Join-Path $env:TEMP 'supabase-cli')
)

$ErrorActionPreference = 'Stop'

$cli = Get-Command supabase -ErrorAction SilentlyContinue
if ($cli) { return $cli.Source }

$bundled = Join-Path $InstallDir 'supabase.exe'
if (Test-Path -LiteralPath $bundled) { return $bundled }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$zipPath = Join-Path $InstallDir 'supabase-cli.zip'

# GitHub release asset name (Windows amd64)
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/supabase/cli/releases/latest' -Headers @{ 'User-Agent' = 'kyno-deploy' }
$asset = $release.assets | Where-Object { $_.name -match 'windows_amd64' } | Select-Object -First 1
if (-not $asset) { throw 'Could not find supabase Windows release asset on GitHub' }

Write-Host "Downloading Supabase CLI $($release.tag_name) ..."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
Expand-Archive -Path $zipPath -DestinationPath $InstallDir -Force
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $bundled)) {
  $found = Get-ChildItem -Path $InstallDir -Recurse -Filter 'supabase.exe' | Select-Object -First 1
  if ($found) { return $found.FullName }
  throw "supabase.exe not found after extract in $InstallDir"
}

return $bundled
