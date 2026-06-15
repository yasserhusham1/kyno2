# KYNO — Go-live: build dist + deploy Edge Functions + preflight
# Usage:
#   $env:SUPABASE_ACCESS_TOKEN = 'sbp_...'
#   powershell -File tools/go-live.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

Write-Host '=== KYNO Go-Live ===' -ForegroundColor Cyan

Write-Host '[1/4] Prepare Edge Function bundles...'
& (Join-Path $PSScriptRoot 'prepare-edge-functions.ps1') | Out-Null

Write-Host '[2/4] Deploy Edge Functions (if token set)...'
$token = [Environment]::GetEnvironmentVariable('SUPABASE_ACCESS_TOKEN')
if ([string]::IsNullOrWhiteSpace($token)) {
  Write-Host '  SKIP: set SUPABASE_ACCESS_TOKEN to deploy auth-* functions' -ForegroundColor Yellow
} else {
  & (Join-Path $PSScriptRoot 'deploy-edge-auth.ps1')
}

Write-Host '[3/4] Build dist/ for Netlify...'
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  Push-Location $root
  try { node (Join-Path $PSScriptRoot 'build-netlify.js') } finally { Pop-Location }
} else {
  & (Join-Path $PSScriptRoot 'build-netlify.ps1')
}

Write-Host '[4/4] Pre-flight checks...'
& (Join-Path $PSScriptRoot 'preflight-netlify.ps1')

Write-Host ''
Write-Host '=== Go-Live checklist ===' -ForegroundColor Green
Write-Host '  1. Supabase SQL: tools/sql/check-db-migration-markers.sql (all true)'
Write-Host '  2. Supabase SQL: bootstrap super admin if needed'
Write-Host '  3. Edge Functions: Verify JWT = OFF for auth-login/session/logout/set-password'
Write-Host '  4. Netlify env: BASMA_SUPABASE_URL, BASMA_SUPABASE_ANON_KEY, BASMA_APP_ENV=production'
Write-Host '[5/6] Deploy dist/ + supabase-proxy (required for /sb on Netlify)'
Write-Host '  Option A — PowerShell API (no Node):'
Write-Host '    $env:NETLIFY_AUTH_TOKEN = ''nfp_...''  # app.netlify.com/user/applications'
Write-Host '    $env:NETLIFY_SITE_NAME = ''jazzy-gumdrop-43cf1a'''
Write-Host '    powershell -File tools/deploy-netlify-api.ps1'
Write-Host '  Option B — Git: connect repo on Netlify (auto-build from netlify.toml)'
Write-Host '  Option C — CLI: netlify deploy --prod --dir=dist'
Write-Host '  Do NOT drag-drop dist/ only — causes /sb 404'
Write-Host '[6/6] Login test: yasser on live URL (Ctrl+Shift+R)'
