# Apply migration 078 to Supabase Postgres
param(
  [Parameter(Mandatory = $true)]
  [string]$DbPassword
)

$ErrorActionPreference = 'Stop'
$projectRef = 'pyxwpwbuwfrzqsnzhxip'
$migration = Join-Path $PSScriptRoot '..\supabase\migrations\078_emergency_rpc_lockdown.sql'
$connStr = "postgresql://postgres.${projectRef}:${DbPassword}@aws-0-eu-central-1.pooler.supabase.com:6543/postgres"

Write-Output 'Applying 078_emergency_rpc_lockdown.sql ...'
$psql = Get-Command psql -ErrorAction SilentlyContinue
if (-not $psql) { throw 'psql not found — install PostgreSQL client' }
& psql $connStr -v ON_ERROR_STOP=1 -f $migration
if ($LASTEXITCODE -ne 0) { throw "psql failed with exit code $LASTEXITCODE" }
Write-Output 'Done - 078 applied. Run tools/verify-full-security-audit.ps1'
