# Deploy KYNO auth Edge Functions (requires SUPABASE_ACCESS_TOKEN)
# Usage: $env:SUPABASE_ACCESS_TOKEN='sbp_...'; powershell -File tools/deploy-edge-auth.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_kyno-env.ps1')

$token = [Environment]::GetEnvironmentVariable('SUPABASE_ACCESS_TOKEN')
if ([string]::IsNullOrWhiteSpace($token)) {
  throw 'Set SUPABASE_ACCESS_TOKEN before running (Supabase Dashboard > Account > Access Tokens)'
}

$root = Split-Path $PSScriptRoot -Parent
Write-Host 'Preparing function bundles (_shared copies)...'
& (Join-Path $PSScriptRoot 'prepare-edge-functions.ps1') | Out-Null

$supabaseExe = & (Join-Path $PSScriptRoot 'ensure-supabase-cli.ps1')
Write-Host "Using Supabase CLI: $supabaseExe"

Push-Location $root
try {
  $projectRef = 'qalcnvygyjltmlauvzlk'
  foreach ($fn in @('auth-login', 'auth-session', 'auth-logout', 'auth-set-password')) {
    Write-Host "Deploying $fn ..."
    & $supabaseExe functions deploy $fn --project-ref $projectRef --no-verify-jwt
  }
  Write-Host 'Done. In Dashboard: Edge Functions > each function > Verify JWT = OFF'
} finally {
  Pop-Location
}
