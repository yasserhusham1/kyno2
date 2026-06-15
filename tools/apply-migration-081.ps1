# Apply migration 081 — super admin login rate limit exempt
param(
  [string]$ProjectRef = 'pyxwpwbuwfrzqsnzhxip',
  [string]$AccessToken = $env:SUPABASE_ACCESS_TOKEN
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sql = Join-Path $root 'supabase\migrations\081_super_admin_login_no_rate_limit.sql'

& (Join-Path $PSScriptRoot 'apply-migration-api.ps1') -SqlFile $sql -ProjectRef $ProjectRef -AccessToken $AccessToken
