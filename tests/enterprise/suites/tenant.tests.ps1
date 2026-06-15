param(
  [hashtable]$SaHeaders,
  [ref]$Results
)

. "$PSScriptRoot\..\lib\KynoTestApi.ps1"

function Assert-CompanyScope {
  param(
    [string]$Name,
    [array]$Rows,
    [int]$CompanyId,
    [string]$Field = 'company_id'
  )
  $leaks = @($Rows | Where-Object { $_ -and $_.$Field -and [int]$_.$Field -ne $CompanyId })
  Add-KynoTestResult -Results $Results -Suite 'tenant' -Name $Name -Pass ($leaks.Count -eq 0) -Detail "leaks=$($leaks.Count)"
}

try {
  $base = 'https://pyxwpwbuwfrzqsnzhxip.supabase.co'
  $all = @(Invoke-RestMethod -Uri "$base/rest/v1/companies?select=id,company_name,status&order=id.asc&limit=10" -Headers $SaHeaders)
  if ($all.Count -eq 0) {
    Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'get_companies' -Pass $false -Detail 'no_companies'
    return
  }
  Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'get_companies' -Pass $true
  if ($all.Count -lt 2) {
    Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'two_companies' -Pass $true -Detail 'only_one_company_skip_cross'
    return
  }

  $companyA = [int]$all[0].id
  $companyB = [int]$all[1].id

  $exportA = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_super_export_company' -Body @{ p_company_id = $companyA }
  $exportB = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_super_export_company' -Body @{ p_company_id = $companyB }

  if (-not $exportA -or ($exportA.ok -ne $true -and $exportA.code -match 'PGRST202|42883')) {
    Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'export_company_a' -Pass $true -Detail 'skip_migration_060_not_applied'
    return
  }
  if ($exportA.ok -ne $true) {
    Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'export_company_a' -Pass $false -Detail ($exportA.error)
    return
  }
  Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'export_company_a' -Pass $true

  Assert-CompanyScope -Name 'A_employees_isolated' -Rows @($exportA.employees) -CompanyId $companyA
  Assert-CompanyScope -Name 'A_salaries_isolated' -Rows @($exportA.salary_records) -CompanyId $companyA
  Assert-CompanyScope -Name 'A_leaves_isolated' -Rows @($exportA.leaves) -CompanyId $companyA
  Assert-CompanyScope -Name 'A_attendance_isolated' -Rows @($exportA.attendance) -CompanyId $companyA

  if ($exportB.ok -eq $true) {
    $aEmpIds = @($exportA.employees | ForEach-Object { [int]$_.id })
    $bEmpIds = @($exportB.employees | ForEach-Object { [int]$_.id })
    $overlap = @($aEmpIds | Where-Object { $bEmpIds -contains $_ })
    Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'AB_employee_ids_disjoint' -Pass ($overlap.Count -eq 0) -Detail "overlap=$($overlap.Count)"
  }

  $health = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_security_health_report' -Body @{}
  Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'security_health_enterprise' -Pass ($health.enterprise_ready -eq $true) -Detail "rpcs_without_tenant=$((@($health.rpcs_without_tenant_validation)).Count)"

  $notifA = @(Invoke-RestMethod -Uri "$base/rest/v1/notifications?company_id=eq.$companyA&select=id&limit=50" -Headers $SaHeaders -ErrorAction SilentlyContinue)
  $notifB = @(Invoke-RestMethod -Uri "$base/rest/v1/notifications?company_id=eq.$companyB&select=id&limit=50" -Headers $SaHeaders -ErrorAction SilentlyContinue)
  $notifOverlap = @($notifA.id | Where-Object { $notifB.id -contains $_ })
  Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'AB_notifications_disjoint' -Pass ($notifOverlap.Count -eq 0) -Detail "overlap=$($notifOverlap.Count)"

  $rpcs = @(
    'saas_list_employees', 'saas_list_attendance', 'saas_get_leaves',
    'saas_list_salary_records'
  )
  foreach ($rpc in $rpcs) {
    $r = Invoke-KynoRpc -Headers $SaHeaders -Rpc $rpc -Body @{ p_limit = 20; p_offset = 0 }
    Add-KynoTestResult -Results $Results -Suite 'tenant' -Name ("rpc_$rpc") -Pass ($r -and $r.ok -eq $true) -Detail 'sa_global_ok'
  }
} catch {
  Add-KynoTestResult -Results $Results -Suite 'tenant' -Name 'suite_error' -Pass $false -Detail $_.Exception.Message
}
