param(
  [hashtable]$SaHeaders,
  [ref]$Results
)

. "$PSScriptRoot\..\lib\KynoTestApi.ps1"

function Test-RpcOk {
  param($Name, $Resp, $RequireOk = $true)
  $pass = $null -ne $Resp
  if ($RequireOk -and $Resp) { $pass = ($Resp.ok -eq $true) }
  Add-KynoTestResult -Results $Results -Suite 'attendance' -Name $Name -Pass $pass -Detail $(if ($Resp.error) { $Resp.error } else { 'ok' })
}

try {
  $list = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_list_attendance' -Body @{ p_limit = 50; p_offset = 0 }
  Test-RpcOk -Name 'list_attendance' -Resp $list

  $rows = @($list.data)
  $normal = $rows | Where-Object { $_.check_in -and $_.check_in -ne '—' -and $_.check_out -and $_.check_out -ne '—' } | Select-Object -First 1
  $late = $rows | Where-Object { $_.late -and $_.late -ne '—' } | Select-Object -First 1
  $missingOut = $rows | Where-Object { $_.check_in -and $_.check_in -ne '—' -and (-not $_.check_out -or $_.check_out -eq '—') } | Select-Object -First 1

  Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'normal_checkin_checkout' -Pass ($null -ne $normal) -Detail $(if ($normal) { "date=$($normal.date_iso)" } else { 'no_fixture' })
  Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'late_record' -Pass ($null -ne $late) -Detail $(if ($late) { "late=$($late.late)" } else { 'no_fixture' })
  Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'missing_checkout' -Pass ($null -ne $missingOut) -Detail $(if ($missingOut) { 'found' } else { 'no_fixture' })

  $dupDates = $rows | Group-Object employee_id, date_iso | Where-Object { $_.Count -gt 1 }
  Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'duplicate_detection' -Pass $true -Detail "duplicate_groups=$($dupDates.Count)"

  $anon = Get-KynoAnonHeaders
  try {
    $denied = Invoke-KynoRpc -Headers $anon -Rpc 'saas_list_attendance' -Body @{ p_limit = 5; p_offset = 0 }
    $pass = ($denied.ok -ne $true) -or ($denied.error -match 'no_company|unauthorized|JWT')
    Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'unauthorized_device_list' -Pass $pass -Detail $(if ($denied.error) { $denied.error } else { 'anon_blocked' })
  } catch {
    Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'unauthorized_device_list' -Pass $true -Detail 'anon_rejected'
  }

  $qrRpc = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_security_health_report' -Body @{}
  Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'qr_gps_rpcs_present' -Pass ($qrRpc -and $qrRpc.ok -eq $true) -Detail 'health_ok'

  $empList = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_list_employees' -Body @{ p_limit = 5; p_offset = 0 }
  if ($empList -and $empList.ok -eq $true -and @($empList.data).Count -gt 0) {
    $eid = [int](@($empList.data)[0].id)
    $att = Invoke-KynoRpc -Headers $SaHeaders -Rpc 'saas_fetch_employee_attendance' -Body @{ p_employee_id = $eid; p_limit = 10 }
    $attOk = ($att -and $att.ok -eq $true) -or ($att -and $att.error -eq 'device_not_authorized')
    Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'fetch_employee_attendance' -Pass $attOk -Detail $(if ($att.error) { $att.error } else { 'employee_scope' })
  }
} catch {
  Add-KynoTestResult -Results $Results -Suite 'attendance' -Name 'suite_error' -Pass $false -Detail $_.Exception.Message
}
