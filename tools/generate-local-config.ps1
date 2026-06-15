# Writes config/local.config.js from environment variables (PowerShell fallback)
param(
  [string]$SupabaseUrl = $env:BASMA_SUPABASE_URL,
  [string]$AnonKey = $env:BASMA_SUPABASE_ANON_KEY,
  [string]$AppEnv = $(if ($env:BASMA_APP_ENV) { $env:BASMA_APP_ENV } else { 'production' })
)

$ErrorActionPreference = 'Stop'
$isProd = $AppEnv -eq 'production'
if (-not $SupabaseUrl -or -not $AnonKey) {
  Write-Warning '[generate-local-config] Set BASMA_SUPABASE_URL and BASMA_SUPABASE_ANON_KEY'
}

$cfg = @{
  supabaseUrl = ($SupabaseUrl | ForEach-Object { "$_".Trim() })
  supabaseAnonKey = ($AnonKey | ForEach-Object { "$_".Trim() })
  appEnv = $AppEnv
  authUseCookies = ($env:BASMA_AUTH_USE_COOKIES -ne 'false')
  kynoRpcMode = if ($env:BASMA_KYNO_RPC_MODE -eq 'true') { $true } elseif ($env:BASMA_KYNO_RPC_MODE -eq 'false') { $false } else { $isProd }
  kynoFinalLockdown = ($env:BASMA_KYNO_FINAL_LOCKDOWN -ne 'false') -and $isProd
  sentryDsn = ($env:BASMA_SENTRY_DSN | ForEach-Object { "$_".Trim() })
  pageSize = [Math]::Max(20, [int]($env:BASMA_PAGE_SIZE -as [int] -or 100))
}

$out = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\local.config.js'
$json = ($cfg | ConvertTo-Json -Depth 5)
$content = "/** Auto-generated at build - do not commit */`nwindow.__BASMA_LOCAL_CONFIG__ = $json;`n"
Set-Content -LiteralPath $out -Value $content -Encoding UTF8
Write-Output "[generate-local-config] wrote $out (appEnv=$AppEnv)"
