# Install Netlify CLI to %TEMP%\netlify-cli if missing
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:TEMP 'netlify-cli'
$exe = Join-Path $dir 'netlify.cmd'
if (Test-Path -LiteralPath $exe) { Write-Output $exe; exit 0 }
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Write-Host "Installing Netlify CLI to $dir ..."
npm install --prefix $dir netlify-cli --no-save 2>&1 | Out-Host
if (-not (Test-Path -LiteralPath $exe)) {
  $alt = Join-Path $dir 'node_modules\.bin\netlify.cmd'
  if (Test-Path -LiteralPath $alt) { Write-Output $alt; exit 0 }
  throw 'Netlify CLI install failed — install Node.js then: npm install -g netlify-cli'
}
Write-Output $exe
