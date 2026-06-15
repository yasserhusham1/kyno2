# Rotate Super Admin password + force logout (no secrets in repo)
# Required env:
#   KYNO_SUPER_ADMIN_PASSWORD     — new password (min 12 chars)
#   KYNO_SUPABASE_SERVICE_ROLE_KEY — Supabase service role (never commit)
# Optional:
#   KYNO_SUPER_ADMIN_USERNAME     — default: yasser
#   BASMA_SUPABASE_URL / SUPABASE_URL

param(
  [string]$Username = $(if ($env:KYNO_SUPER_ADMIN_USERNAME) { $env:KYNO_SUPER_ADMIN_USERNAME } else { 'yasser' })
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_kyno-env.ps1')

$newPassword = Get-KynoSuperAdminPassword
if ($newPassword.Length -lt 12) {
  throw 'KYNO_SUPER_ADMIN_PASSWORD must be at least 12 characters'
}

$base = Get-KynoSupabaseUrl
$svcHeaders = Get-KynoServiceHeaders
$username = $Username.Trim().ToLower()

Write-Host "Rotating password for super admin: $username" -ForegroundColor Cyan

$body = @{
  p_username     = $username
  p_new_password = $newPassword
} | ConvertTo-Json -Compress

$rotateUri = "$base/rest/v1/rpc/saas_rotate_user_password"
$result = Invoke-RestMethod -Uri $rotateUri -Method POST -Headers $svcHeaders -Body $body

if (-not $result.ok) {
  throw "saas_rotate_user_password failed: $($result | ConvertTo-Json -Compress)"
}

Write-Host "DB password updated. saas_sessions revoked: $($result.sessions_revoked)" -ForegroundColor Green

# GoTrue — invalidate all JWT refresh tokens for this user
$authEmail = [string]$result.auth_email
if ($authEmail) {
  try {
    $listUri = "$base/auth/v1/admin/users?email=$([uri]::EscapeDataString($authEmail))"
    $usersRes = Invoke-RestMethod -Uri $listUri -Method GET -Headers $svcHeaders
    $authUserId = $null
    if ($usersRes -is [System.Array] -and $usersRes.Count -gt 0) {
      $authUserId = $usersRes[0].id
    } elseif ($usersRes.users -and $usersRes.users.Count -gt 0) {
      $authUserId = $usersRes.users[0].id
    } elseif ($usersRes.id) {
      $authUserId = $usersRes.id
    }
    if ($authUserId) {
      $logoutUri = "$base/auth/v1/admin/users/$authUserId/logout"
      Invoke-RestMethod -Uri $logoutUri -Method POST -Headers $svcHeaders -Body '{}' | Out-Null
      Write-Host "GoTrue global logout OK for auth user $authUserId" -ForegroundColor Green
    } else {
      Write-Host "GoTrue user not found for $authEmail — saas_sessions already revoked" -ForegroundColor Yellow
    }
  } catch {
    Write-Warning "GoTrue admin logout skipped: $($_.Exception.Message)"
    Write-Warning 'saas_sessions were revoked; ask user to clear browser storage / re-login.'
  }
}

# Belt-and-suspenders: revoke any remaining super_admin cookie sessions
try {
  $revokeAllUri = "$base/rest/v1/rpc/saas_revoke_all_super_admin_sessions"
  $revokedAll = Invoke-RestMethod -Uri $revokeAllUri -Method POST -Headers $svcHeaders -Body '{}'
  Write-Host "saas_revoke_all_super_admin_sessions: $revokedAll" -ForegroundColor Green
} catch {
  Write-Warning "saas_revoke_all_super_admin_sessions: $($_.Exception.Message)"
}

Write-Host 'Done. Super Admin must sign in again with the new password from KYNO_SUPER_ADMIN_PASSWORD.' -ForegroundColor Cyan
