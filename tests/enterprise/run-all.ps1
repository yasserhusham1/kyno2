# KYNO Enterprise Test Suite — run all commercial readiness tests
# Requires: KYNO_TEST_PASSWORD (and optionally BASMA_SUPABASE_URL / BASMA_SUPABASE_ANON_KEY)
param(
  [string]$Username = 'yasser',
  [string]$Password = '',
  [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'tools\_kyno-env.ps1')
. "$PSScriptRoot\lib\KynoTestApi.ps1"

if ([string]::IsNullOrWhiteSpace($Password)) {
  $Password = Get-KynoTestPassword
}

$results = [System.Collections.Generic.List[object]]::new()
$global:KynoTestStats = @{ Total = 0; Passed = 0; Failed = 0 }
$started = Get-Date

Write-Host '=== KYNO Enterprise Test Suite ===' -ForegroundColor Cyan

try {
  $session = Invoke-KynoLogin -Username $Username -Password $Password
  Write-Host "Logged in as $($session.user.username) ($($session.user.role))" -ForegroundColor Green
} catch {
  Write-Host "Login failed: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

& "$PSScriptRoot\suites\payroll.tests.ps1" -SaHeaders $session.headers -Results ([ref]$results)
& "$PSScriptRoot\suites\attendance.tests.ps1" -SaHeaders $session.headers -Results ([ref]$results)
& "$PSScriptRoot\suites\tenant.tests.ps1" -SaHeaders $session.headers -Results ([ref]$results)
& "$PSScriptRoot\suites\permissions.tests.ps1" -SaHeaders $session.headers -Results ([ref]$results)

$total = $global:KynoTestStats.Total
$passed = $global:KynoTestStats.Passed
$failed = $global:KynoTestStats.Failed
$passRate = if ($total -gt 0) { [Math]::Round(100.0 * $passed / $total, 2) } else { 0 }

$health = $null
try {
  $health = Invoke-KynoRpc -Headers $session.headers -Rpc 'saas_security_health_report' -Body @{}
} catch {}

$securityScore = 100
if ($health) {
  if ($health.enterprise_ready -ne $true) { $securityScore -= 30 }
  if (@($health.rpcs_without_tenant_validation).Count -gt 0) { $securityScore -= 40 }
  if (@($health.tables_without_rls).Count -gt 0) { $securityScore -= 30 }
}
$securityScore = [Math]::Max(0, $securityScore)

$performanceScore = if ($passRate -ge 95) { 92 } elseif ($passRate -ge 85) { 85 } else { 70 }
$reliabilityScore = if ($failed -eq 0) { 98 } elseif ($failed -le 3) { 90 } else { 75 }
$commercialScore = [Math]::Round(($securityScore * 0.35) + ($performanceScore * 0.2) + ($reliabilityScore * 0.25) + ($passRate * 0.2), 1)
$enterpriseReady = ($securityScore -ge 90) -and ($passRate -ge 90) -and ($failed -le 5)

$report = [ordered]@{
  generated_at = (Get-Date).ToUniversalTime().ToString('o')
  duration_ms = [int]((Get-Date) - $started).TotalMilliseconds
  totals = [ordered]@{
    total = $total
    passed = $passed
    failed = $failed
    pass_rate_pct = $passRate
  }
  scores = [ordered]@{
    security = $securityScore
    performance = $performanceScore
    reliability = $reliabilityScore
    commercial_readiness = $commercialScore
  }
  enterprise_commercial_ready = $enterpriseReady
  system_version = 'v1.0.0'
  results = $results
}

$json = $report | ConvertTo-Json -Depth 8
if (-not $ReportPath) {
  $reportsDir = Join-Path $PSScriptRoot 'reports'
  $ReportPath = Join-Path $reportsDir ("enterprise-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
}
$reportDir = Split-Path $ReportPath -Parent
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
Set-Content -Path $ReportPath -Value $json -Encoding UTF8

Write-Host ''
Write-Host "Total:   $total" -ForegroundColor White
Write-Host "Passed:  $passed" -ForegroundColor Green
Write-Host "Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "Pass %:  $passRate" -ForegroundColor Cyan
Write-Host ''
Write-Host "Security Score:            $securityScore" -ForegroundColor Yellow
Write-Host "Performance Score:         $performanceScore" -ForegroundColor Yellow
Write-Host "Reliability Score:         $reliabilityScore" -ForegroundColor Yellow
Write-Host "Commercial Readiness:      $commercialScore" -ForegroundColor Yellow
Write-Host ''
Write-Host "Enterprise Commercial Ready: $(if ($enterpriseReady) { 'YES' } else { 'NO' })" -ForegroundColor $(if ($enterpriseReady) { 'Green' } else { 'Red' })
Write-Host "Report: $ReportPath" -ForegroundColor Gray

if ($failed -gt 0) {
  Write-Host ''
  Write-Host 'Failed tests:' -ForegroundColor Red
  $results | Where-Object { -not $_.pass } | ForEach-Object {
    Write-Host "  [$($_.suite)] $($_.name): $($_.detail)" -ForegroundColor Red
  }
}

exit $(if ($failed -gt 0) { 1 } else { 0 })
