# Deploy dist + supabase-proxy function to Netlify
# Usage: powershell -File tools/deploy-netlify.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

Write-Host '=== KYNO Netlify Deploy ===' -ForegroundColor Cyan

Write-Host '[1/3] Build dist/...'
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  Push-Location $root
  try { & node (Join-Path $PSScriptRoot 'build-netlify.js') } finally { Pop-Location }
} else {
  & (Join-Path $PSScriptRoot 'build-netlify.ps1')
}

Write-Host '[2/3] Netlify CLI...'
$netlify = Get-Command netlify -ErrorAction SilentlyContinue
if (-not $netlify) {
  try {
    $cliPath = & (Join-Path $PSScriptRoot 'ensure-netlify-cli.ps1')
    if ($cliPath -and (Test-Path -LiteralPath $cliPath)) { $netlify = Get-Command $cliPath -ErrorAction SilentlyContinue }
  } catch {
    Write-Host $_.Exception.Message -ForegroundColor Yellow
  }
}

if (-not $netlify) {
  Write-Host ''
  Write-Host 'Netlify CLI required to deploy supabase-proxy function.' -ForegroundColor Red
  Write-Host '  npm install -g netlify-cli' -ForegroundColor White
  Write-Host '  netlify login && netlify link' -ForegroundColor White
  Write-Host '  netlify deploy --prod --dir=dist' -ForegroundColor White
  Write-Host ''
  Write-Host 'Without this, /sb returns 404. App will fallback to direct Supabase URL.' -ForegroundColor Yellow
  exit 1
}

Write-Host '[3/3] netlify deploy --prod --dir=dist ...'
Push-Location $root
try {
  & $netlify.Source deploy --prod --dir=dist
} finally {
  Pop-Location
}

Write-Host ''
Write-Host 'Verify: Netlify Dashboard > Functions > supabase-proxy' -ForegroundColor Green
Write-Host 'Test:   https://YOUR-SITE.netlify.app/sb/functions/v1/auth-session' -ForegroundColor Green
