-- ============================================================
-- KYNO 076 — Super Admin password rotation + force logout
-- Safe ops: no plaintext passwords in this file.
-- Rotate via: tools/rotate-super-admin-password.ps1
--   env: KYNO_SUPER_ADMIN_PASSWORD, KYNO_SUPABASE_SERVICE_ROLE_KEY
-- ============================================================

-- ---------- 1) Revoke all saas_sessions for one user ----------
CREATE OR REPLACE FUNCTION saas_revoke_all_sessions_for_user(p_user_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n INTEGER := 0;
BEGIN
  IF p_user_id IS NULL OR p_user_id < 1 THEN
    RETURN 0;
  END IF;
  UPDATE saas_sessions
  SET revoked_at = NOW()
  WHERE user_id = p_user_id
    AND revoked_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ---------- 2) Revoke all super_admin saas_sessions ----------
CREATE OR REPLACE FUNCTION saas_revoke_all_super_admin_sessions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n INTEGER := 0;
BEGIN
  UPDATE saas_sessions s
  SET revoked_at = NOW()
  FROM saas_users u
  WHERE s.user_id = u.id
    AND u.role = 'super_admin'
    AND u.is_active IS TRUE
    AND s.revoked_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ---------- 3) Internal GoTrue email (for admin logout scripts) ----------
CREATE OR REPLACE FUNCTION saas_user_auth_email(p_user_id INTEGER)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  u RECORD;
  safe_user TEXT;
BEGIN
  IF p_user_id IS NULL OR p_user_id < 1 THEN
    RETURN NULL;
  END IF;
  SELECT id, username, email INTO u
  FROM saas_users
  WHERE id = p_user_id AND is_active IS TRUE
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF u.email IS NOT NULL AND trim(u.email) <> '' AND position('@' IN u.email) > 0 THEN
    RETURN lower(trim(u.email));
  END IF;
  safe_user := regexp_replace(COALESCE(u.username, 'user'), '[^a-zA-Z0-9._-]', '_', 'g');
  RETURN format('saas_%s_%s@kyno.internal', u.id, safe_user);
END;
$$;

-- ---------- 4) Rotate password + invalidate saas_sessions (service_role only) ----------
CREATE OR REPLACE FUNCTION saas_rotate_user_password(
  p_username TEXT,
  p_new_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  uid INTEGER;
  urole TEXT;
  hash TEXT;
  revoked INTEGER := 0;
  pwd TEXT;
BEGIN
  pwd := trim(COALESCE(p_new_password, ''));
  IF p_username IS NULL OR length(trim(p_username)) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_username');
  END IF;
  IF length(pwd) < 12 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_too_short', 'min_length', 12);
  END IF;

  SELECT id, role INTO uid, urole
  FROM saas_users
  WHERE lower(username) = lower(trim(p_username))
    AND is_active IS TRUE
  LIMIT 1;

  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  hash := saas_hash_password_bcrypt(pwd);
  IF hash IS NULL OR hash = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
  END IF;

  UPDATE saas_users
  SET password_hash = hash,
      password_algo = 'bcrypt',
      force_password_reset = false,
      updated_at = NOW()
  WHERE id = uid;

  revoked := saas_revoke_all_sessions_for_user(uid);

  DELETE FROM login_attempts
  WHERE lower(username) = lower(trim(p_username));

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', uid,
    'username', trim(p_username),
    'role', urole,
    'sessions_revoked', revoked,
    'auth_email', saas_user_auth_email(uid),
    'force_relogin', true
  );
END;
$$;

-- ---------- 5) Legacy seed detection without embedded weak-hash literals ----------
CREATE OR REPLACE FUNCTION saas_count_legacy_seed_users()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer FROM saas_users
  WHERE lower(username) IN ('superadmin', 'admin')
    AND (
      password_algo IS NULL
      OR password_algo IN ('legacy_b64', 'sha256')
    );
$$;

-- Re-flag legacy accounts for mandatory rotation (idempotent)
UPDATE saas_users
SET force_password_reset = true
WHERE (password_algo IS NULL OR password_algo IN ('legacy_b64', 'sha256'))
  AND force_password_reset IS NOT TRUE;

-- ---------- Grants (service_role / Edge Functions only) ----------
REVOKE ALL ON FUNCTION saas_revoke_all_sessions_for_user(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_revoke_all_super_admin_sessions() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_user_auth_email(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_rotate_user_password(TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_revoke_all_sessions_for_user(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION saas_revoke_all_super_admin_sessions() TO service_role;
GRANT EXECUTE ON FUNCTION saas_user_auth_email(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION saas_rotate_user_password(TEXT, TEXT) TO service_role;

COMMENT ON FUNCTION saas_rotate_user_password(TEXT, TEXT) IS
  'Rotate saas_users password (bcrypt), revoke saas_sessions, clear login_attempts. service_role only. Pair with GoTrue admin logout for full JWT invalidation.';

COMMENT ON FUNCTION saas_revoke_all_super_admin_sessions() IS
  'Force logout: revoke all active saas_sessions for super_admin users.';
