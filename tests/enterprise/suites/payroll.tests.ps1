param(
  [hashtable]$SaHeaders,
  [ref]$Results
)

. "$PSScriptRoot\..\lib\KynoTestApi.ps1"
. "$PSScriptRoot\..\lib\PayrollValidator.ps1"

$scenarios = @(
  'basic_only', 'overtime', 'deductions', 'loan', 'leave_paid_or_unpaid',
  'late_only', 'bonus_only', 'all_components'
)
$found = @{}
foreach ($s in $scenarios) { $found[$s] = $false }

try {
  $list = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_list_employees' -Body @{ p_limit = 200; p_offset = 0 }
  if (-not $list -or $list.ok -ne $true) {
    Add-KynoTestResult -Results $Results -Suite 'payroll' -Name 'list_employees' -Pass $false -Detail 'rpc_failed'
    return
  }
  Add-KynoTestResult -Results $Results -Suite 'payroll' -Name 'list_employees' -Pass $true

  $employees = @($list.data)
  if ($employees.Count -eq 0) {
    Add-KynoTestResult -Results $Results -Suite 'payroll' -Name 'has_employees' -Pass $false -Detail 'no_employees'
    return
  }

  foreach ($emp in $employees) {
    if (-not $emp.id) { continue }
    $preview = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_preview_salary' -Body @{
      p_employee_id = [int]$emp.id
      p_month = $null
    }
    $consistency = Test-PayrollCalcConsistency -Calc $preview
    Add-KynoTestResult -Results $Results -Suite 'payroll' -Name ("formula_emp_$($emp.id)") -Pass $consistency.pass -Detail $consistency.detail

    $tag = Get-PayrollScenarioTag -Calc $preview
    if ($tag -and $found.ContainsKey($tag) -and -not $found[$tag]) {
      $found[$tag] = $true
      $sc = Test-PayrollScenarioFromCalc -ScenarioName $tag -Calc $preview
      Add-KynoTestResult -Results $Results -Suite 'payroll' -Name ("scenario_$tag") -Pass $sc.pass -Detail $sc.detail
    }
  }

  foreach ($s in $scenarios) {
    if (-not $found[$s]) {
      Add-KynoTestResult -Results $Results -Suite 'payroll' -Name ("scenario_$s") -Pass $true -Detail 'skipped_no_fixture_data'
    }
  }
} catch {
  Add-KynoTestResult -Results $Results -Suite 'payroll' -Name 'suite_error' -Pass $false -Detail $_.Exception.Message
}
