-- ============================================================
-- 014 — إدارة مستخدمي الشركة (مدير الشركة)
-- شغّل بعد 004/003
-- ============================================================

CREATE OR REPLACE FUNCTION saas_list_company_users(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := p_company_id;
BEGIN
  IF cid IS NULL OR cid <= 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT auth_is_super_admin()
     AND NOT (auth_app_role() = 'company_admin' AND auth_company_id() = cid) THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', u.id,
      'username', u.username,
      'display_name', COALESCE(u.display_name, ''),
      'email', COALESCE(u.email, ''),
      'role', u.role,
      'permissions', COALESCE(u.permissions, '{}'::jsonb),
      'company_id', u.company_id,
      'is_active', COALESCE(u.is_active, true),
      'last_login', u.last_login,
      'created_at', u.created_at
    ) ORDER BY u.id)
    FROM saas_users u
    WHERE u.company_id = cid
      AND u.role <> 'super_admin'
  ), '[]'::jsonb);
END;
$$;

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
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uname TEXT := lower(trim(p_username));
  uid INTEGER := p_user_id;
  role_in TEXT := COALESCE(NULLIF(trim(p_role), ''), 'company_user');
  hash TEXT;
  perms JSONB := COALESCE(p_permissions, '{}'::jsonb);
  row_out RECORD;
BEGIN
  IF cid IS NULL OR cid <= 0 OR uname IS NULL OR length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF role_in NOT IN ('company_user', 'company_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  IF NOT auth_is_super_admin()
     AND NOT (auth_app_role() = 'company_admin' AND auth_company_id() = cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
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

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', uid,
      'username', row_out.username,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'permissions', COALESCE(row_out.permissions, '{}'::jsonb),
      'company_id', row_out.company_id,
      'is_active', COALESCE(row_out.is_active, true)
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_company_user(
  p_user_id INTEGER,
  p_company_id INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uid INTEGER := p_user_id;
BEGIN
  IF uid IS NULL OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF NOT auth_is_super_admin()
     AND NOT (auth_app_role() = 'company_admin' AND auth_company_id() = cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users
    WHERE id = uid AND company_id = cid AND role <> 'super_admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  DELETE FROM saas_users WHERE id = uid AND company_id = cid;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_list_company_users(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_company_users(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) TO authenticated;

-- السماح لمدير الشركة بحذف مستخدمي شركته (RLS 004 كان super_admin فقط)
DROP POLICY IF EXISTS "saas_users_delete_super" ON saas_users;
CREATE POLICY "saas_users_delete_tenant" ON saas_users
  FOR DELETE TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      auth_app_role() = 'company_admin'
      AND company_id = auth_company_id()
      AND role <> 'super_admin'
    )
  );
