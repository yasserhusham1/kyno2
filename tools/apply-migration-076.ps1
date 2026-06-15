# Apply migration 076 to Supabase Postgres
param(
  [Parameter(Mandatory = $true)]
  [string]$DbPassword
)

$ErrorActionPreference = 'Stop'
$projectRef = 'pyxwpwbuwfrzqsnzhxip'
$migration = Join-Path $PSScriptRoot '..\supabase\migrations\076_super_admin_password_hardening.sql'
$connStr = "postgresql://postgres.${projectRef}:${DbPassword}@aws-0-eu-central-1.pooler.supabase.com:6543/postgres"

Write-Output 'Applying 076_super_admin_password_hardening.sql ...'
$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($psql) {
  & psql $connStr -v ON_ERROR_STOP=1 -f $migration
  if ($LASTEXITCODE -ne 0) { throw "psql failed with exit code $LASTEXITCODE" }
} else {
  throw 'psql not found'
}
Write-Output 'Done - 076 applied.'
