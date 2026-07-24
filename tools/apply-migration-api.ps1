# Apply SQL migration via Supabase Management API (no psql required)
param(
  [Parameter(Mandatory = $true)][string]$SqlFile,
  [string]$ProjectRef = 'gxiofbdykxjkdgdcmsnp',
  [string]$AccessToken = $env:SUPABASE_ACCESS_TOKEN
)

$ErrorActionPreference = 'Stop'

function ConvertTo-JsonString([string]$Value) {
  if ($null -eq $Value) { return 'null' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $Value.ToCharArray()) {
    switch ($ch) {
      '"' { [void]$sb.Append('\"') }
      '\' { [void]$sb.Append('\\') }
      "`r" { [void]$sb.Append('\r') }
      "`n" { [void]$sb.Append('\n') }
      "`t" { [void]$sb.Append('\t') }
      default {
        if ([int][char]$ch -lt 32) {
          [void]$sb.AppendFormat('\u{0:x4}', [int][char]$ch)
        } else {
          [void]$sb.Append($ch)
        }
      }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
  throw 'Missing SUPABASE_ACCESS_TOKEN'
}
if (-not (Test-Path -LiteralPath $SqlFile)) {
  throw "SQL file not found: $SqlFile"
}

$sql = [string](Get-Content -Raw -LiteralPath $SqlFile)
$body = '{ "query": ' + (ConvertTo-JsonString $sql) + ' }'
$uri = "https://api.supabase.com/v1/projects/$ProjectRef/database/query"
$tmpBody = [System.IO.Path]::GetTempFileName() + '.json'
[System.IO.File]::WriteAllText($tmpBody, $body, [System.Text.UTF8Encoding]::new($false))

$resp = curl.exe -s -w "`nHTTP:%{http_code}" --max-time 120 -X POST $uri `
  -H "Authorization: Bearer $AccessToken" `
  -H "Content-Type: application/json; charset=utf-8" `
  --data-binary "@$tmpBody"

Write-Output $resp
if ($resp -notmatch 'HTTP:(200|201)') {
  throw "Migration failed for $(Split-Path -Leaf $SqlFile): $resp"
}
Write-Output ("Applied: " + (Split-Path -Leaf $SqlFile))
Remove-Item $tmpBody -Force -ErrorAction SilentlyContinue
