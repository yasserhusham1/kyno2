# KYNO — Credential environment variables

Never commit real passwords or `service_role` keys to Git.

## Variables

| Variable | Used by | Purpose |
|----------|---------|---------|
| `KYNO_TEST_PASSWORD` | `tests/enterprise/run-all.ps1` | Login for automated tests |
| `KYNO_SUPER_ADMIN_PASSWORD` | `tools/rotate-super-admin-password.ps1` | **New** super admin password (12+ chars) when rotating |
| `KYNO_SUPABASE_SERVICE_ROLE_KEY` | `tools/rotate-super-admin-password.ps1` | Supabase service role (Dashboard → API) |
| `KYNO_SUPER_ADMIN_USERNAME` | rotate script (optional) | Default: `yasser` |

Also: `BASMA_SUPABASE_URL`, `BASMA_SUPABASE_ANON_KEY` (see `.env.example`).

## Rotate super admin password + force logout

1. Apply migration `076_super_admin_password_hardening.sql` on Supabase.
2. In PowerShell (secrets **not** saved to disk):

```powershell
$env:KYNO_SUPER_ADMIN_PASSWORD = 'YourNewSecurePassword12+'
$env:KYNO_SUPABASE_SERVICE_ROLE_KEY = '<from-supabase-dashboard>'
powershell -NoProfile -ExecutionPolicy Bypass -File tools/rotate-super-admin-password.ps1
```

3. Set the same value in `KYNO_TEST_PASSWORD` for local tests if needed.

## Windows (persistent session)

```powershell
[System.Environment]::SetEnvironmentVariable('KYNO_TEST_PASSWORD', '...', 'User')
```

Do **not** store `KYNO_SUPABASE_SERVICE_ROLE_KEY` in User env on dev machines unless necessary.
