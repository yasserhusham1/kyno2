-- ============================================================
-- KYNO 038 — Company user password verify + repair RPC
-- Fixes login failures when password_algo/hash mismatch after create
-- ============================================================

-- Backfill inconsistent rows (bcrypt hash vs legacy algo label)
UPDATE saas_users
SET password_algo = 'bcrypt'
WHERE password_hash LIKE '$2%'
  AND COALESCE(password_algo, 'legacy_b64') <> 'bcrypt';

UPDATE saas_users
SET password_algo = 'legacy_b64'
WHERE password_hash IS NOT NULL
  AND password_hash NOT LIKE '$2%'
  AND password_algo = 'bcrypt';

CREATE OR REPLACE FUNCTION saas_rehash_company_user_password(
  p_user_id INTEGER,
  p_company_id INTEGER,
  p_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  uid INTEGER := p_user_id;
  cid INTEGER := p_company_id;
  hash TEXT;
  stored TEXT;
BEGIN
  IF uid IS NULL OR uid <= 0 OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_required');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users
    WHERE id = uid AND company_id = cid AND role <> 'super_admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  hash := saas_hash_password_bcrypt(trim(p_password));
  IF hash IS NULL OR hash = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
  END IF;

  UPDATE saas_users
  SET password_hash = hash, password_algo = 'bcrypt'
  WHERE id = uid AND company_id = cid;

  SELECT password_hash INTO stored FROM saas_users WHERE id = uid LIMIT 1;
  IF stored IS NULL OR extensions.crypt(trim(p_password), stored) IS DISTINCT FROM stored THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_verify_failed');
  END IF;

  RETURN jsonb_build_object('ok', true, 'user_id', uid);
END;
$$;

REVOKE ALL ON FUNCTION saas_rehash_company_user_password(INTEGER, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_rehash_company_user_password(INTEGER, INTEGER, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION saas_upsert_company_user(
  p_company_id INTEGER,
  p_username TEXT,
  p_display_name TEXT DEFAULT '',
  p_email TEXT DEFAULT NULL,
  p_role TEXT DEFAULT 'company_user',
  p_password TEXT DEFAULT NULL,
  p_permissions JSONB DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE,
  p_user_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uname TEXT := lower(trim(p_username));
  uid INTEGER := p_user_id;
  role_in TEXT := COALESCE(NULLIF(trim(p_role), ''), 'company_user');
  hash TEXT;
  stored_hash TEXT;
  perms JSONB := COALESCE(p_permissions, '{}'::jsonb);
  row_out RECORD;
  active_chk JSONB;
BEGIN
  IF cid IS NULL OR cid <= 0 OR uname IS NULL OR length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF role_in NOT IN ('company_user', 'company_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT auth_is_super_admin() THEN
    active_chk := saas_assert_company_active(cid);
    IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'subscription_inactive',
        'detail', COALESCE(active_chk->>'error', 'unknown')
      );
    END IF;
  END IF;

  IF uid IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM saas_users
      WHERE id = uid AND company_id = cid AND role <> 'super_admin'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name, ''),
      email = NULLIF(trim(p_email), ''),
      role = role_in,
      permissions = perms,
      is_active = COALESCE(p_is_active, true)
    WHERE id = uid AND company_id = cid
    RETURNING * INTO row_out;

    IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;

    IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;

    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;

    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, permissions, company_id, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_display_name), ''), uname),
      NULLIF(trim(p_email), ''),
      hash, 'bcrypt',
      role_in, perms, cid, COALESCE(p_is_active, true)
    )
    RETURNING * INTO row_out;
    uid := row_out.id;
  END IF;

  IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
    SELECT password_hash INTO stored_hash FROM saas_users WHERE id = uid LIMIT 1;
    IF stored_hash IS NULL OR stored_hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_verify_failed');
    END IF;
    IF extensions.crypt(trim(p_password), stored_hash) IS DISTINCT FROM stored_hash THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
      IF extensions.crypt(trim(p_password), hash) IS DISTINCT FROM hash THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_verify_failed');
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', uid,
      'username', uname,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'permissions', COALESCE(row_out.permissions, '{}'::jsonb),
      'company_id', cid,
      'is_active', COALESCE(row_out.is_active, true)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;
