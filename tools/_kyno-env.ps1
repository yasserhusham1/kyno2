# KYNO — shared environment helpers (no secrets in repo)
# Usage: . (Join-Path $PSScriptRoot '_kyno-env.ps1')

function Get-KynoEnvRequired {
  param([Parameter(Mandatory = $true)][string]$Name)
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($v)) {
    throw "Missing required environment variable: $Name"
  }
  return $v.Trim()
}

function Get-KynoEnvOptional {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Default = ''
  )
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
  return $v.Trim()
}

function Get-KynoTestPassword {
  return Get-KynoEnvRequired -Name 'KYNO_TEST_PASSWORD'
}

function Get-KynoSuperAdminPassword {
  return Get-KynoEnvRequired -Name 'KYNO_SUPER_ADMIN_PASSWORD'
}

function Get-KynoSupabaseUrl {
  $v = Get-KynoEnvOptional -Name 'BASMA_SUPABASE_URL'
  if ($v) { return $v.TrimEnd('/') }
  $v = Get-KynoEnvOptional -Name 'SUPABASE_URL'
  if ($v) { return $v.TrimEnd('/') }
  $defaultsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\supabase.defaults.js'
  if (Test-Path $defaultsPath) {
    $src = Get-Content -Raw -Path $defaultsPath
    if ($src -match "supabaseUrl:\s*'([^']+)'") { return $Matches[1].TrimEnd('/') }
  }
  throw 'Missing BASMA_SUPABASE_URL (or config/supabase.defaults.js)'
}

function Get-KynoSupabaseAnonKey {
  $v = Get-KynoEnvOptional -Name 'BASMA_SUPABASE_ANON_KEY'
  if ($v) { return $v }
  $v = Get-KynoEnvOptional -Name 'SUPABASE_ANON_KEY'
  if ($v) { return $v }
  $defaultsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\supabase.defaults.js'
  if (Test-Path $defaultsPath) {
    $src = Get-Content -Raw -Path $defaultsPath
    if ($src -match "supabaseAnonKey:\s*'([^']+)'") { return $Matches[1] }
  }
  throw 'Missing BASMA_SUPABASE_ANON_KEY (or config/supabase.defaults.js)'
}

function Get-KynoServiceRoleKey {
  return Get-KynoEnvRequired -Name 'KYNO_SUPABASE_SERVICE_ROLE_KEY'
}

function Get-KynoServiceHeaders {
  $key = Get-KynoServiceRoleKey
  return @{
    apikey         = $key
    Authorization  = "Bearer $key"
    'Content-Type' = 'application/json'
  }
}

function Get-KynoAnonHeaders {
  $key = Get-KynoSupabaseAnonKey
  return @{
    apikey         = $key
    Authorization  = "Bearer $key"
    'Content-Type' = 'application/json'
  }
}
