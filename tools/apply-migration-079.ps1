# Apply migration 079
param([Parameter(Mandatory = $true)][string]$DbPassword)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_kyno-env.ps1')
$ref = 'pyxwpwbuwfrzqsnzhxip'
$sql = Join-Path $PSScriptRoot '..\supabase\migrations\079_auth_session_revocation.sql'
$conn = "postgresql://postgres.${ref}:${DbPassword}@aws-0-eu-central-1.pooler.supabase.com:6543/postgres"
& psql $conn -v ON_ERROR_STOP=1 -f $sql
if ($LASTEXITCODE -ne 0) { throw "079 failed" }
Write-Output '079 applied'
