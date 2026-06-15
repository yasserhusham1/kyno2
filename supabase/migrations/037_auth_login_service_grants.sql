-- ============================================================
-- KYNO 037 — service_role EXECUTE on auth RPCs (Edge Functions)
-- Run if auth-login returns 401/500 after migration 027+
-- ============================================================

GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) TO service_role;
