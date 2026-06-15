# KYNO Enterprise Test API helper
param(
  [string]$BaseUrl = '',
  [string]$AnonKey = ''
)

if ([string]::IsNullOrWhiteSpace($BaseUrl) -or [string]::IsNullOrWhiteSpace($AnonKey)) {
  $envScript = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools\_kyno-env.ps1'
  if (Test-Path $envScript) {
    . $envScript
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = Get-KynoSupabaseUrl }
    if ([string]::IsNullOrWhiteSpace($AnonKey)) { $AnonKey = Get-KynoSupabaseAnonKey }
  }
}

if ([string]::IsNullOrWhiteSpace($BaseUrl) -or [string]::IsNullOrWhiteSpace($AnonKey)) {
  throw 'Set BASMA_SUPABASE_URL and BASMA_SUPABASE_ANON_KEY, or ensure config/supabase.defaults.js exists'
}

function Get-KynoAnonHeaders {
  return @{ apikey = $AnonKey; Authorization = "Bearer $AnonKey"; 'Content-Type' = 'application/json' }
}

function Invoke-KynoLogin {
  param([string]$Username, [string]$Password)
  $lh = Get-KynoAnonHeaders
  $body = @{ username = $Username; password = $Password } | ConvertTo-Json
  $login = Invoke-RestMethod -Uri "$BaseUrl/functions/v1/auth-login" -Method POST -Headers $lh -Body $body
  return @{
    jwt = $login.access_token
    user = $login.user
    headers = @{
      apikey = $AnonKey
      Authorization = "Bearer $($login.access_token)"
      'Content-Type' = 'application/json'
    }
  }
}

function Invoke-KynoRpc {
  param(
    [hashtable]$Headers,
    [string]$Rpc,
    [object]$Body = @{}
  )
  $json = if ($null -eq $Body) { '{}' } else { ($Body | ConvertTo-Json -Depth 12 -Compress) }
  return Invoke-RestMethod -Uri "$BaseUrl/rest/v1/rpc/$Rpc" -Method POST -Headers $Headers -Body $json
}

function Add-KynoTestResult {
  param(
    [ref]$Results,
    [string]$Suite,
    [string]$Name,
    [bool]$Pass,
    [string]$Detail = ''
  )
  if (-not $global:KynoTestStats) {
    $global:KynoTestStats = @{ Total = 0; Passed = 0; Failed = 0 }
  }
  $global:KynoTestStats.Total++
  if ($Pass) { $global:KynoTestStats.Passed++ } else { $global:KynoTestStats.Failed++ }
  $Results.Value += [pscustomobject]@{
    suite = $Suite
    name = $Name
    pass = $Pass
    detail = $Detail
  }
}

if (-not $global:KynoTestStats) {
  $global:KynoTestStats = @{ Total = 0; Passed = 0; Failed = 0 }
}
