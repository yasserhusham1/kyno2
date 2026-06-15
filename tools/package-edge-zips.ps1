# Package Edge Functions as ZIP (for CLI deploy or backup)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $root 'tools\edge-zips'
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-FuncZip($slug, [string[]]$files) {
  $zipPath = Join-Path $outDir "$slug.zip"
  $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($rel in $files) {
      $full = Join-Path $root $rel
      if (-not (Test-Path -LiteralPath $full)) { throw "Missing: $rel" }
      $entry = ($rel -replace '\\', '/')
      if ($entry.StartsWith('supabase/functions/')) {
        $entry = $entry.Substring('supabase/functions/'.Length)
      }
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $full, $entry) | Out-Null
    }
  } finally { $zip.Dispose() }
  Write-Output "Created $zipPath"
}

New-FuncZip 'auth-login' @('supabase/functions/auth-login/index.ts')
New-FuncZip 'auth-session' @(
  'supabase/functions/auth-session/index.ts',
  'supabase/functions/_shared/session.ts',
  'supabase/functions/_shared/supabase.ts',
  'supabase/functions/_shared/types.ts',
  'supabase/functions/_shared/auth-jwt.ts'
)
New-FuncZip 'auth-logout' @(
  'supabase/functions/auth-logout/index.ts',
  'supabase/functions/_shared/session.ts',
  'supabase/functions/_shared/supabase.ts'
)
New-FuncZip 'auth-set-password' @(
  'supabase/functions/auth-set-password/index.ts',
  'supabase/functions/_shared/session.ts',
  'supabase/functions/_shared/supabase.ts',
  'supabase/functions/_shared/types.ts'
)

Write-Output "ZIP files in: $outDir"
