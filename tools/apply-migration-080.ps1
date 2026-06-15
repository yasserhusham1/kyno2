# Apply migration 080
param([Parameter(Mandatory = $true)][string]$DbPassword)
$ErrorActionPreference = 'Stop'
$sql = Join-Path $PSScriptRoot '..\supabase\migrations\080_production_security_final.sql'
$ref = 'pyxwpwbuwfrzqsnzhxip'
$conn = "postgresql://postgres.${ref}:${DbPassword}@aws-0-eu-central-1.pooler.supabase.com:6543/postgres"
& psql $conn -v ON_ERROR_STOP=1 -f $sql
if ($LASTEXITCODE -ne 0) { throw "080 failed" }
Write-Output '080 applied'
