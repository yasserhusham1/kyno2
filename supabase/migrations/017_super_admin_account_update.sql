-- ============================================================
-- 017 — تحديث حساب السوبر أدمن (اسم مستخدم / بريد / كلمة مرور)
-- شغّل بعد 016
-- ============================================================

CREATE OR REPLACE FUNCTION saas_update_saas_account(
  p_user_id INTEGER,
  p_username TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_password TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  uid INTEGER := p_user_id;
  actor_id INTEGER;
  uname TEXT;
  hash TEXT;
  row_out RECORD;
BEGIN
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := auth_saas_user_id();

  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF actor_id IS NOT NULL AND actor_id <> uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_only');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users WHERE id = uid AND role = 'super_admin' AND is_active = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  uname := lower(trim(COALESCE(p_username, '')));
  IF uname IS NOT NULL AND length(uname) >= 3 THEN
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname AND id <> uid) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;
  ELSE
    uname := NULL;
  END IF;

  UPDATE saas_users SET
    username = COALESCE(uname, username),
    email = CASE WHEN p_email IS NOT NULL THEN NULLIF(trim(p_email), '') ELSE email END,
    updated_at = NOW()
  WHERE id = uid AND role = 'super_admin'
  RETURNING * INTO row_out;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;
    UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', row_out.id,
      'username', row_out.username,
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT) TO authenticated;
