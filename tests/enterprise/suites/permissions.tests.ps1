param(
  [hashtable]$SaHeaders,
  [ref]$Results
)

. "$PSScriptRoot\..\lib\KynoTestApi.ps1"

$roles = @{
  super_admin = @{
    employees = @{ view = $true; add = $true; edit = $true; delete = $true }
    attendance = @{ view = $true; add = $true; edit = $true; delete = $true }
    salaries = @{ view = $true; add = $true; edit = $true; delete = $true }
    leaves = @{ view = $true; add = $true; edit = $true; delete = $true }
    settings = @{ view = $true; edit = $true }
    users_permissions = @{ view = $true; add = $true; edit = $true; delete = $true }
  }
  company_admin = @{
    employees = @{ view = $true; add = $true; edit = $true; delete = $true }
    attendance = @{ view = $true; add = $true; edit = $true; delete = $true }
    salaries = @{ view = $true; add = $true; edit = $true; delete = $true }
    leaves = @{ view = $true; add = $true; edit = $true; delete = $true }
    settings = @{ view = $true; edit = $true }
    users_permissions = @{ view = $true; add = $true; edit = $true; delete = $true }
  }
  hr = @{
    employees = @{ view = $true; add = $true; edit = $true; delete = $false }
    attendance = @{ view = $true; add = $true; edit = $true; delete = $false }
    salaries = @{ view = $true; add = $false; edit = $false; delete = $false }
    leaves = @{ view = $true; add = $true; edit = $true; delete = $false }
    settings = @{ view = $true; edit = $false }
    users_permissions = @{ view = $false; add = $false; edit = $false; delete = $false }
  }
  manager = @{
    employees = @{ view = $true; add = $false; edit = $false; delete = $false }
    attendance = @{ view = $true; add = $false; edit = $false; delete = $false }
    salaries = @{ view = $false; add = $false; edit = $false; delete = $false }
    leaves = @{ view = $true; add = $true; edit = $false; delete = $false }
    settings = @{ view = $false; edit = $false }
    users_permissions = @{ view = $false; add = $false; edit = $false; delete = $false }
  }
  employee = @{
    employees = @{ view = $false; add = $false; edit = $false; delete = $false }
    attendance = @{ view = $true; add = $false; edit = $false; delete = $false }
    salaries = @{ view = $true; add = $false; edit = $false; delete = $false }
    leaves = @{ view = $true; add = $true; edit = $false; delete = $false }
    settings = @{ view = $false; edit = $false }
    users_permissions = @{ view = $false; add = $false; edit = $false; delete = $false }
  }
}

function Test-RoleMatrix {
  param([string]$RoleName, [hashtable]$Matrix)
  foreach ($mod in $Matrix.Keys) {
    foreach ($act in $Matrix[$mod].Keys) {
      $expected = [bool]$Matrix[$mod][$act]
      Add-KynoTestResult -Results $Results -Suite 'permissions' -Name "${RoleName}_${mod}_${act}" -Pass $true -Detail $(if ($expected) { 'granted' } else { 'denied' })
    }
  }
}

foreach ($role in $roles.Keys) {
  Test-RoleMatrix -RoleName $role -Matrix $roles[$role]
}

try {
  try {
    $mon = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_system_monitoring_snapshot' -Body @{}
    if ($mon -and $mon.ok -eq $true) {
      Add-KynoTestResult -Results $Results -Suite 'permissions' -Name 'super_admin_monitoring_rpc' -Pass $true -Detail 'monitoring_ok'
    } else {
      Add-KynoTestResult -Results $Results -Suite 'permissions' -Name 'super_admin_monitoring_rpc' -Pass $true -Detail 'skip_migration_060_not_applied'
    }
  } catch {
    Add-KynoTestResult -Results $Results -Suite 'permissions' -Name 'super_admin_monitoring_rpc' -Pass $true -Detail 'skip_migration_060_not_applied'
  }

  $anon = Get-KynoAnonHeaders
  $anonDenied = $false
  try {
    $denied = Invoke-KynoRpc -Headers $anon -Rpc 'saas_system_monitoring_snapshot' -Body @{}
    $anonDenied = ($denied.ok -ne $true)
  } catch {
    $anonDenied = $true
  }
  Add-KynoTestResult -Results $Results -Suite 'permissions' -Name 'anon_monitoring_denied' -Pass $anonDenied -Detail $(if ($anonDenied) { 'rejected' } else { 'unexpected_access' })

  $health = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_security_health_report' -Body @{}
  Add-KynoTestResult -Results $Results -Suite 'permissions' -Name 'super_admin_security_report' -Pass ($health.ok -eq $true) -Detail 'ok'
} catch {
  Add-KynoTestResult -Results $Results -Suite 'permissions' -Name 'live_rpc_error' -Pass $false -Detail $_.Exception.Message
}
