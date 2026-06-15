# Local static server (no Python/Node required)
# Usage: powershell -File tools/serve-local.ps1
# Open: http://localhost:5500

param(
  [int]$Port = 5500,
  [string]$Root = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$prefix = "http://localhost:$Port/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Host "KYNO local server: $prefix" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop." -ForegroundColor Gray

function Get-ContentType([string]$path) {
  switch -Regex ($path) {
    '\.html?$' { return 'text/html; charset=utf-8' }
    '\.js$'    { return 'application/javascript; charset=utf-8' }
    '\.css$'   { return 'text/css; charset=utf-8' }
    '\.json$'  { return 'application/json; charset=utf-8' }
    '\.png$'   { return 'image/png' }
    '\.jpg$'   { return 'image/jpeg' }
    '\.svg$'   { return 'image/svg+xml' }
    '\.woff2$' { return 'font/woff2' }
    '\.ico$'   { return 'image/x-icon' }
    default    { return 'application/octet-stream' }
  }
}

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    try {
      $rel = [Uri]::UnescapeDataString($request.Url.LocalPath.TrimStart('/'))
      if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
      $full = Join-Path $Root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
      $full = [IO.Path]::GetFullPath($full)
      $rootFull = [IO.Path]::GetFullPath($Root)

      if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        $response.StatusCode = 403
        $bytes = [Text.Encoding]::UTF8.GetBytes('403 Forbidden')
      } elseif (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $response.StatusCode = 404
        $bytes = [Text.Encoding]::UTF8.GetBytes('404 Not Found')
      } else {
        $bytes = [IO.File]::ReadAllBytes($full)
        $response.StatusCode = 200
        $response.ContentType = Get-ContentType $full
      }

      $response.ContentLength64 = $bytes.Length
      $response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
      $response.StatusCode = 500
      $msg = [Text.Encoding]::UTF8.GetBytes('500 Internal Server Error')
      $response.ContentLength64 = $msg.Length
      $response.OutputStream.Write($msg, 0, $msg.Length)
    } finally {
      $response.OutputStream.Close()
    }
  }
} finally {
  $listener.Stop()
}
