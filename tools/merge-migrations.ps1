# Merge supabase/migrations/*.sql into one file for SQL Editor
param(
  [int]$From = 1,
  [int]$To = 84,
  [switch]$IncludeBaseline,
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$migrationsDir = Join-Path $root 'supabase\migrations'

if (-not $OutFile) {
  $suffix = if ($IncludeBaseline) { '000-084' } else { ('{0:D3}-{1:D3}' -f $From, $To) }
  $OutFile = Join-Path $root "tools\sql\kyno-merged-migrations-$suffix.sql"
}

$files = Get-ChildItem -LiteralPath $migrationsDir -Filter '*.sql' |
  ForEach-Object {
    $num = 0
    if ($_.BaseName -match '^(\d+)') { $num = [int]$Matches[1] }
    [PSCustomObject]@{ Num = $num; File = $_ }
  } |
  Sort-Object Num, { $_.File.Name }

$selected = @($files | Where-Object {
  if ($IncludeBaseline -and $_.Num -eq 0) { return $true }
  $_.Num -ge $From -and $_.Num -le $To
})

if (-not $selected.Count) {
  throw "No files for range $From..$To"
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('-- ============================================================')
[void]$sb.AppendLine('-- KYNO — Merged migrations (manual SQL Editor run)')
$rangeLabel = if ($IncludeBaseline) { "000-${From}-${To}" } else { "${From}-${To}" }
[void]$sb.AppendLine(('-- Range: {0} — {1} file(s)' -f $rangeLabel, $selected.Count))
[void]$sb.AppendLine(('-- Generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')))
[void]$sb.AppendLine('-- NOTE: Empty DB needs 000_kyno_baseline_schema.sql first if not included')
[void]$sb.AppendLine('-- NOTE: SQL Editor may timeout - split batches 001-030, 031-060, 061-084 if needed')
[void]$sb.AppendLine('-- ============================================================')
[void]$sb.AppendLine('')

foreach ($item in $selected) {
  $name = $item.File.Name
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('-- ============================================================')
  [void]$sb.AppendLine(('-- BEGIN: {0}' -f $name))
  [void]$sb.AppendLine('-- ============================================================')
  [void]$sb.AppendLine('')
  $content = [string](Get-Content -Raw -LiteralPath $item.File.FullName -Encoding UTF8)
  [void]$sb.AppendLine($content.TrimEnd())
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine(('-- END: {0}' -f $name))
}

$outDir = Split-Path $OutFile -Parent
if (-not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
$bytes = (Get-Item -LiteralPath $OutFile).Length
Write-Output ("Merged $($selected.Count) files -> $OutFile ($([math]::Round($bytes / 1KB, 1)) KB)")
