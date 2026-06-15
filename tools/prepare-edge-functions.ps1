# Copy _shared into each Edge Function folder (fixes bundler "Module not found _shared/session.ts")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sharedSrc = Join-Path $root 'supabase\functions\_shared'
$targets = @(
  @{ Slug = 'auth-session'; Files = @('session.ts', 'supabase.ts', 'types.ts', 'auth-jwt.ts') },
  @{ Slug = 'auth-logout'; Files = @('session.ts', 'supabase.ts') },
  @{ Slug = 'auth-set-password'; Files = @('session.ts', 'supabase.ts', 'types.ts') }
)

foreach ($t in $targets) {
  $destDir = Join-Path $root "supabase\functions\$($t.Slug)\_shared"
  if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Recurse -Force }
  New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  foreach ($f in $t.Files) {
    $src = Join-Path $sharedSrc $f
    if (-not (Test-Path -LiteralPath $src)) { throw "Missing shared file: $f" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $destDir $f)
  }
  Write-Output "OK $($t.Slug) -> _shared ($($t.Files.Count) files)"
}

Write-Output 'Done. Deploy with: npx supabase functions deploy auth-session --project-ref qalcnvygyjltmlauvzlk --no-verify-jwt'
