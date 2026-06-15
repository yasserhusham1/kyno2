# Netlify build fallback (no Node) — minimal dist/ artifact
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'

if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

foreach ($f in @('index.html', 'supabase_integration.js')) {
  $src = Join-Path $root $f
  if (-not (Test-Path -LiteralPath $src)) { throw "Missing: $f" }
  Copy-Item -LiteralPath $src -Destination (Join-Path $dist $f)
}

foreach ($d in @('css', 'js', 'assets', 'fonts')) {
  $srcDir = Join-Path $root $d
  if (Test-Path -LiteralPath $srcDir) {
    Copy-Item -LiteralPath $srcDir -Destination (Join-Path $dist $d) -Recurse
  }
}

$configDir = Join-Path $dist 'config'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
foreach ($f in @('public.config.js', 'supabase.defaults.js')) {
  Copy-Item -LiteralPath (Join-Path $root "config\$f") -Destination (Join-Path $configDir $f)
}

$overrides = @{}
if ($env:BASMA_SUPABASE_URL) { $overrides['supabaseUrl'] = $env:BASMA_SUPABASE_URL.Trim() }
if ($env:BASMA_SUPABASE_ANON_KEY) { $overrides['supabaseAnonKey'] = $env:BASMA_SUPABASE_ANON_KEY.Trim() }
if ($env:BASMA_APP_ENV) { $overrides['appEnv'] = $env:BASMA_APP_ENV.Trim() }
if ($env:BASMA_SENTRY_DSN) { $overrides['sentryDsn'] = $env:BASMA_SENTRY_DSN.Trim() }

$json = ($overrides | ConvertTo-Json -Depth 5)
if (-not $json -or $json -eq '{}') { $json = '{}' }
Set-Content -LiteralPath (Join-Path $configDir 'local.config.js') -Value "/** Optional overrides */`nwindow.__BASMA_LOCAL_CONFIG__ = $json;`n" -Encoding UTF8

Set-Content -LiteralPath (Join-Path $dist '_redirects') -Value "/sb/*  /.netlify/functions/supabase-proxy/:splat  200!`n" -Encoding ASCII

$files = (Get-ChildItem -LiteralPath $dist -Recurse -File).Count
$bytes = (Get-ChildItem -LiteralPath $dist -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Output "[build-netlify] dist ready: $files files, $([math]::Round($bytes/1KB,1)) KB"
