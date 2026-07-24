# Pre-flight checks before Netlify deploy
# Usage: powershell -File tools/preflight-netlify.ps1
# Optional: $env:KYNO_SUPABASE_SERVICE_ROLE_KEY='...' for DB super-admin check

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_kyno-env.ps1')

$root = Split-Path $PSScriptRoot -Parent
$base = Get-KynoSupabaseUrl
$anon = Get-KynoSupabaseAnonKey
$projectRef = ($base -replace 'https://', '' -replace '.supabase.co', '').Trim()
$pass = 0
$fail = 0
$warn = 0

function Ok($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green;  $script:pass++ }
function Bad($msg)  { Write-Host "[FAIL] $msg" -ForegroundColor Red;    $script:fail++ }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow; $script:warn++ }

Write-Host "`n=== KYNO Pre-flight (Netlify) ===" -ForegroundColor Cyan
Write-Host "Project: $projectRef`n"

# --- Config files ---
$defaultsPath = Join-Path $root 'config\supabase.defaults.js'
if (Test-Path -LiteralPath $defaultsPath) {
  $defaults = Get-Content -LiteralPath $defaultsPath -Raw
  if ($defaults -match [regex]::Escape($base)) { Ok "config/supabase.defaults.js -> $projectRef" }
  else { Bad "config/supabase.defaults.js URL mismatch (expected $base)" }
} else {
  Bad 'Missing config/supabase.defaults.js'
}

# --- Edge Functions (retry DNS flakiness) ---
$headers = @{ apikey = $anon; Authorization = "Bearer $anon" }
function Invoke-EdgeCheck {
  param([string]$Fn)
  $uri = "$base/functions/v1/$Fn"
  for ($i = 1; $i -le 3; $i++) {
    try {
      $res = Invoke-WebRequest -Uri $uri -Method GET -Headers $headers -UseBasicParsing -TimeoutSec 30
      return @{ ok = $true; code = $res.StatusCode; msg = '' }
    } catch {
      $code = $_.Exception.Response.StatusCode.value__
      if ($code -eq 401 -or $code -eq 405) { return @{ ok = $true; code = $code; msg = '' } }
      $msg = $_.Exception.Message
      if ($i -lt 3 -and $msg -match 'could not be resolved|NameResolutionFailure') {
        Start-Sleep -Seconds 2
        continue
      }
      return @{ ok = $false; code = $code; msg = $msg }
    }
  }
  return @{ ok = $false; code = 0; msg = 'unknown' }
}

foreach ($fn in @('auth-login', 'auth-session', 'auth-logout', 'auth-set-password')) {
  $r = Invoke-EdgeCheck -Fn $fn
  if ($r.ok) {
    if ($r.code -eq 200) { Ok "Edge function $fn responds HTTP 200" }
    else { Ok "Edge function $fn reachable (HTTP $($r.code))" }
  } else {
    Bad "Edge function ${fn}: $($r.msg)"
  }
}

# --- Login flow (wrong password = DB + RPC OK) ---
try {
  $loginBody = '{"username":"yasser","password":"__preflight_wrong__"}'
  $loginRes = Invoke-RestMethod -Uri "$base/functions/v1/auth-login" -Method POST -Headers (@{
    apikey = $anon; Authorization = "Bearer $anon"; 'Content-Type' = 'application/json'
  }) -Body $loginBody -ErrorAction Stop
  Bad 'auth-login should reject wrong password with 401'
} catch {
  $resp = $_.ErrorDetails.Message
  if ($resp -match 'invalid_credentials') { Ok 'auth-login + saas_verify_login RPC working' }
  elseif ($resp -match 'rate_limited') { Warn 'Login rate-limited — clear login_attempts in SQL Editor' }
  else { Bad "auth-login POST: $resp" }
}

# --- RLS lockdown (anon must NOT read employees) ---
try {
  Invoke-RestMethod -Uri "$base/rest/v1/employees?select=id&limit=1" -Method GET -Headers $headers -ErrorAction Stop
  Bad 'anon can SELECT employees — migrations 033/084 may be missing'
} catch {
  $resp = $_.ErrorDetails.Message
  if ($resp -match 'permission denied|42501|401') { Ok 'RLS: anon blocked from employees (expected)' }
  else { Warn "employees check: $resp" }
}

# --- Super admin (needs service role) ---
$svc = Get-KynoEnvOptional -Name 'KYNO_SUPABASE_SERVICE_ROLE_KEY'
if ($svc) {
  try {
    $svcHeaders = @{ apikey = $svc; Authorization = "Bearer $svc" }
    $admins = Invoke-RestMethod -Uri "$base/rest/v1/saas_users?role=eq.super_admin&select=id,username,is_active&is_active=eq.true" -Method GET -Headers $svcHeaders
    if ($admins -and $admins.Count -gt 0) {
      Ok ("Super admin exists: " + ($admins | ForEach-Object { $_.username }) -join ', ')
    } else {
      Bad 'No active super_admin — run tools/sql/bootstrap-super-admin.sql'
    }
  } catch {
    Bad "Super admin check failed: $($_.Exception.Message)"
  }
} else {
  Warn 'Set KYNO_SUPABASE_SERVICE_ROLE_KEY to verify super_admin user exists'
  Warn 'Or run tools/sql/check-super-admin.sql in Supabase SQL Editor'
}

# --- Netlify env reminder ---
Write-Host "`n--- Netlify env (Site settings > Environment variables) ---" -ForegroundColor Cyan
Write-Host "  BASMA_SUPABASE_URL       = $base"
Write-Host "  BASMA_SUPABASE_ANON_KEY  = (anon key from Dashboard)"
Write-Host "  BASMA_APP_ENV            = production"
Write-Host "  (optional) BASMA_AUTH_USE_COOKIES = true"

Write-Host "`n--- Manual Dashboard checks ---" -ForegroundColor Cyan
Write-Host "  [ ] Edge Functions > each auth-* > Verify JWT = OFF"
Write-Host "  [ ] SQL: tools/sql/check-db-migration-markers.sql (all markers true)"
Write-Host "  [ ] Login test on site after deploy (Ctrl+Shift+R)"

Write-Host "`n=== Summary: $pass OK, $warn WARN, $fail FAIL ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
