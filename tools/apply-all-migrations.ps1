# Apply KYNO migrations 000..084 via Supabase Management API
# Usage:
#   $env:SUPABASE_ACCESS_TOKEN = 'sbp_...'
#   $env:KYNO_SUPABASE_PROJECT_REF = 'your-project-ref'   # optional
#   powershell -File tools/apply-all-migrations.ps1

param(
  [string]$ProjectRef = $(if ($env:KYNO_SUPABASE_PROJECT_REF) { $env:KYNO_SUPABASE_PROJECT_REF } else { 'qalcnvygyjtlmlauvzlk' }),
  [string]$From = '000',
  [string]$To = '084'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$apply = Join-Path $PSScriptRoot 'apply-migration-api.ps1'

if (-not (Test-Path -LiteralPath $apply)) {
  throw "Missing: $apply"
}
if ([string]::IsNullOrWhiteSpace($env:SUPABASE_ACCESS_TOKEN)) {
  throw 'Set SUPABASE_ACCESS_TOKEN (Supabase Dashboard → Account → Access Tokens)'
}

$migrationsDir = Join-Path $root 'supabase\migrations'
$files = Get-ChildItem -LiteralPath $migrationsDir -Filter '*.sql' |
  Sort-Object { [int]($_.BaseName -replace '^(\d+).*', '$1') }, Name

$fromNum = [int]$From
$toNum = [int]$To
$selected = @($files | Where-Object {
  $n = [int]($_.BaseName -replace '^(\d+).*', '$1')
  $n -ge $fromNum -and $n -le $toNum
})

if (-not $selected.Count) {
  throw "No migration files found between $From and $To"
}

Write-Host "Project: $ProjectRef" -ForegroundColor Cyan
Write-Host "Applying $($selected.Count) migration file(s)..." -ForegroundColor Cyan

$i = 0
foreach ($f in $selected) {
  $i++
  Write-Host "[$i/$($selected.Count)] $($f.Name)" -ForegroundColor Yellow
  & $apply -SqlFile $f.FullName -ProjectRef $ProjectRef
  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Failed on $($f.Name)"
  }
  Start-Sleep -Milliseconds 500
}

Write-Host 'All migrations applied.' -ForegroundColor Green
Write-Host 'Next: run tools/sql/bootstrap-super-admin.sql then deploy Edge Functions.' -ForegroundColor Cyan
