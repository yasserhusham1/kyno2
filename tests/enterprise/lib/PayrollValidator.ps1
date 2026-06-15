# Validates saas_preview_salary / saas_v3_compute_salary output against expected formula
function Test-PayrollCalcConsistency {
  param([object]$Calc)
  if (-not $Calc -or $Calc.ok -ne $true) {
    return @{ pass = $false; detail = 'calc_not_ok' }
  }
  $base = [int]$Calc.base_salary
  $bonus = [int]$Calc.bonus
  $late = [int]$Calc.late_deduct
  $absent = [int]$Calc.absent_deduct
  $leave = [int]$Calc.leave_deduct
  $manual = [int]$Calc.manual_deduct
  $loan = [int]$Calc.loan_deduct
  $ot = [int]$Calc.overtime_amount
  $totalDeduct = [int]$Calc.total_deduct
  $net = [int]$Calc.net_salary
  $includeOt = ($Calc.include_overtime_in_salary -eq $true) -or ($Calc.overtime_in_net -eq $true)

  $sumDeduct = $late + $absent + $leave + $manual + $loan
  if ($sumDeduct -ne $totalDeduct) {
    return @{ pass = $false; detail = "total_deduct mismatch: $sumDeduct vs $totalDeduct" }
  }

  $expectedNet = [Math]::Max(0, $base + $bonus - $totalDeduct + $(if ($includeOt) { $ot } else { 0 }))
  if ($expectedNet -ne $net) {
    return @{ pass = $false; detail = "net_salary mismatch: expected $expectedNet got $net" }
  }
  return @{ pass = $true; detail = 'formula_ok' }
}

function Get-PayrollScenarioTag {
  param([object]$Calc)
  if (-not $Calc -or $Calc.ok -ne $true) { return 'invalid' }
  $hasOt = ([int]$Calc.overtime_amount) -gt 0
  $hasManual = ([int]$Calc.manual_deduct) -gt 0
  $hasLoan = ([int]$Calc.loan_deduct) -gt 0
  $hasLeave = ([int]$Calc.leave_deduct) -gt 0 -or ([int]$Calc.leave_days) -gt 0
  $hasLate = ([int]$Calc.late_deduct) -gt 0
  $hasBonus = ([int]$Calc.bonus) -gt 0
  $hasAbsent = ([int]$Calc.absent_deduct) -gt 0

  if ($hasOt -and $hasManual -and $hasLoan -and $hasLeave -and $hasLate -and $hasBonus) { return 'all_components' }
  if ($hasBonus -and -not $hasOt -and -not $hasManual -and -not $hasLoan -and -not $hasLeave -and -not $hasLate) { return 'bonus_only' }
  if ($hasLate -and -not $hasOt -and -not $hasManual -and -not $hasLoan -and -not $hasLeave) { return 'late_only' }
  if ($hasLeave -and -not $hasOt) { return 'leave_paid_or_unpaid' }
  if ($hasLoan) { return 'loan' }
  if ($hasManual) { return 'deductions' }
  if ($hasOt) { return 'overtime' }
  if ($baseOnly -eq $true) { return 'basic_only' }
  if (-not $hasOt -and -not $hasManual -and -not $hasLoan -and -not $hasLeave -and -not $hasLate -and -not $hasBonus) { return 'basic_only' }
  return 'mixed'
}

function Test-PayrollScenarioFromCalc {
  param(
    [string]$ScenarioName,
    [object]$Calc
  )
  $consistency = Test-PayrollCalcConsistency -Calc $Calc
  if (-not $consistency.pass) {
    return @{ pass = $false; detail = $consistency.detail }
  }

  switch ($ScenarioName) {
    'basic_only' {
      $ok = ([int]$Calc.bonus) -eq 0 -and ([int]$Calc.total_deduct) -eq 0 -and ([int]$Calc.overtime_amount) -eq 0
      return @{ pass = $ok; detail = if ($ok) { 'basic_only_ok' } else { 'expected no bonus/deduct/ot' } }
    }
    'overtime' {
      $ok = ([int]$Calc.overtime_amount) -gt 0
      return @{ pass = $ok; detail = if ($ok) { 'overtime_ok' } else { 'no overtime in calc' } }
    }
    'deductions' {
      $ok = ([int]$Calc.manual_deduct) -gt 0
      return @{ pass = $ok; detail = if ($ok) { 'deductions_ok' } else { 'no manual deduct' } }
    }
    'loan' {
      $ok = ([int]$Calc.loan_deduct) -gt 0
      return @{ pass = $ok; detail = if ($ok) { 'loan_ok' } else { 'no loan deduct' } }
    }
    'leave_paid_or_unpaid' {
      $ok = ([int]$Calc.leave_deduct) -ge 0 -and ([int]$Calc.leave_days) -ge 0
      return @{ pass = $ok; detail = 'leave_fields_present' }
    }
    'late_only' {
      $ok = ([int]$Calc.late_deduct) -gt 0
      return @{ pass = $ok; detail = if ($ok) { 'late_ok' } else { 'no late deduct' } }
    }
    'bonus_only' {
      $ok = ([int]$Calc.bonus) -gt 0
      return @{ pass = $ok; detail = if ($ok) { 'bonus_ok' } else { 'no bonus' } }
    }
    'all_components' {
      $ok = ([int]$Calc.bonus) -gt 0 -and ([int]$Calc.late_deduct) -gt 0 -and ([int]$Calc.loan_deduct) -gt 0 -and ([int]$Calc.manual_deduct) -gt 0
      return @{ pass = $ok; detail = if ($ok) { 'all_components_ok' } else { 'missing component' } }
    }
    default {
      return @{ pass = $true; detail = 'formula_only' }
    }
  }
}
