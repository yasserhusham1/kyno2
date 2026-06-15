# Diagnose super admin login + optional password reset / clear rate limit
# Required for list/reset: KYNO_SUPABASE_SERVICE_ROLE_KEY
# Optional: KYNO_SUPER_ADMIN_USERNAME (default yasser), KYNO_SUPER_ADMIN_PASSWORD (for -Reset)

param(
  [string]$Username = '',
  [switch]$ClearRateLimit,
  [switch]$Reset,
  [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_kyno-env.ps1')

$base = Get-KynoSupabaseUrl
$svcHeaders = Get-KynoServiceHeaders

Write-Host "Supabase: $base" -ForegroundColor Cyan

# List active super_admin accounts (no password data)
$listUri = "$base/rest/v1/saas_users?role=eq.super_admin&select=id,username,display_name,is_active,password_algo,force_password_reset,last_login&order=id.asc"
$admins = Invoke-RestMethod -Uri $listUri -Method GET -Headers $svcHeaders

if (-not $admins -or $admins.Count -eq 0) {
  Write-Host 'No super_admin users found in saas_users.' -ForegroundColor Red
  Write-Host 'Create one via Supabase SQL or saas_upsert_super_admin RPC.' -ForegroundColor Yellow
  exit 1
}

Write-Host "`nSuper admin accounts:" -ForegroundColor Green
$admins | ForEach-Object {
  Write-Host ("  id={0} username={1} active={2} algo={3} force_reset={4} last_login={5}" -f `
    $_.id, $_.username, $_.is_active, $_.password_algo, $_.force_password_reset, $_.last_login)
}

if ($ListOnly) { exit 0 }

$targetUser = $Username.Trim().ToLower()
if (-not $targetUser) {
  $targetUser = (Get-KynoEnvOptional -Name 'KYNO_SUPER_ADMIN_USERNAME' -Default 'yasser').Trim().ToLower()
}

$match = $admins | Where-Object { $_.username.ToLower() -eq $targetUser -and $_.is_active -eq $true }
if (-not $match) {
  Write-Host "`nUsername '$targetUser' not found among active super admins." -ForegroundColor Red
  Write-Host 'Use one of the usernames listed above (lowercase).' -ForegroundColor Yellow
  exit 1
}

if ($ClearRateLimit) {
  $delUserUri = "$base/rest/v1/login_attempts?username=eq.$([uri]::EscapeDataString($targetUser))"
  try {
    Invoke-RestMethod -Uri $delUserUri -Method DELETE -Headers $svcHeaders | Out-Null
    Write-Host "Cleared login_attempts for username $targetUser" -ForegroundColor Green
  } catch {
    Write-Warning "login_attempts clear (username): $($_.Exception.Message)"
  }
  # Also clear all super_admin usernames
  foreach ($a in $admins) {
    if (-not $a.is_active) { continue }
    $u = [uri]::EscapeDataString($a.username.ToLower())
    try {
      Invoke-RestMethod -Uri "$base/rest/v1/login_attempts?username=eq.$u" -Method DELETE -Headers $svcHeaders | Out-Null
    } catch { /* ignore */ }
  }
  Write-Host 'Cleared login_attempts for all active super_admin usernames' -ForegroundColor Green
}

if ($Reset) {
  $newPassword = Get-KynoSuperAdminPassword
  if ($newPassword.Length -lt 12) {
    throw 'KYNO_SUPER_ADMIN_PASSWORD must be at least 12 characters'
  }
  $body = @{ p_username = $targetUser; p_new_password = $newPassword } | ConvertTo-Json -Compress
  $result = Invoke-RestMethod -Uri "$base/rest/v1/rpc/saas_rotate_user_password" -Method POST -Headers $svcHeaders -Body $body
  if (-not $result.ok) {
    throw "saas_rotate_user_password failed: $($result | ConvertTo-Json -Compress)"
  }
  Write-Host "Password rotated for $targetUser (sessions revoked: $($result.sessions_revoked))" -ForegroundColor Green
  Write-Host 'Sign in with KYNO_SUPER_ADMIN_PASSWORD on Netlify.' -ForegroundColor Cyan
  exit 0
}

Write-Host "`n401 invalid_credentials usually means wrong username/password in DB." -ForegroundColor Yellow
Write-Host "Try login with username: $($match.username) (all lowercase)" -ForegroundColor Yellow
Write-Host 'If password unknown after migration 076, run:' -ForegroundColor Yellow
Write-Host "  `$env:KYNO_SUPER_ADMIN_PASSWORD='YourNewSecurePass12+'" -ForegroundColor Gray
Write-Host "  `$env:KYNO_SUPABASE_SERVICE_ROLE_KEY='...'" -ForegroundColor Gray
Write-Host "  .\tools\diagnose-super-admin-login.ps1 -Username $($match.username) -ClearRateLimit -Reset" -ForegroundColor Gray
