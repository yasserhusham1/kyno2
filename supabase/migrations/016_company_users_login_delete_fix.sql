-- ============================================================
-- 016 — إصلاح دخول مستخدمي الشركة + صلاحية الحذف لمدير الشركة
-- شغّل بعد 014 و 015
-- ============================================================

-- ----------------------------------------------------------
-- 1) هوية المستخدم من JWT + التحقق من DB (أدق من claims فقط)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION auth_saas_user_id()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT NULLIF(
    COALESCE(
      auth.jwt() -> 'app_metadata' ->> 'saas_user_id',
      auth.jwt() ->> 'saas_user_id'
    ),
    ''
  )::INTEGER;
$$;

CREATE OR REPLACE FUNCTION auth_can_manage_tenant_users(p_company_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  actor_id INTEGER;
  actor_role TEXT;
  actor_cid INTEGER;
  actor_perms JSONB;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN FALSE;
  END IF;

  IF auth_is_super_admin() THEN
    RETURN TRUE;
  END IF;

  actor_id := auth_saas_user_id();
  IF actor_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT role, company_id, COALESCE(permissions, '{}'::jsonb)
  INTO actor_role, actor_cid, actor_perms
  FROM saas_users
  WHERE id = actor_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  IF actor_cid IS NULL OR actor_cid <> p_company_id THEN
    RETURN FALSE;
  END IF;

  IF actor_role IN ('company_admin', 'super_admin') THEN
    RETURN TRUE;
  END IF;

  IF actor_role = 'company_user'
     AND COALESCE((actor_perms ->> 'users_permissions')::boolean, false) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;

GRANT EXECUTE ON FUNCTION auth_can_manage_tenant_users(INTEGER) TO authenticated;

-- ----------------------------------------------------------
-- 2) إصلاح تسجيل الدخول (حساسية حروف اسم المستخدم + bcrypt)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_verify_login(p_username TEXT, p_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  u RECORD;
  legacy_hash TEXT;
  uname TEXT := lower(trim(p_username));
BEGIN
  IF uname IS NULL OR length(uname) < 2 OR p_password IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT su.*, c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE lower(su.username) = uname AND su.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  legacy_hash := encode(convert_to(p_password, 'UTF8'), 'base64');

  IF COALESCE(u.password_algo, 'legacy_b64') = 'bcrypt'
     OR (u.password_hash IS NOT NULL AND u.password_hash LIKE '$2%') THEN
    IF u.password_hash IS NULL OR u.password_hash = '' THEN
      RETURN NULL;
    END IF;
    IF extensions.crypt(p_password, u.password_hash) IS DISTINCT FROM u.password_hash THEN
      RETURN NULL;
    END IF;
  ELSIF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(extensions.digest(p_password || ':' || u.id::text, 'sha256'), 'hex') THEN
      RETURN NULL;
    END IF;
  ELSIF u.password_hash IS DISTINCT FROM legacy_hash THEN
    RETURN NULL;
  END IF;

  UPDATE saas_users SET last_login = NOW() WHERE id = u.id;

  RETURN jsonb_build_object(
    'id', u.id,
    'username', u.username,
    'display_name', COALESCE(u.display_name, ''),
    'email', COALESCE(u.email, ''),
    'role', u.role,
    'permissions', COALESCE(u.permissions, '{}'::jsonb),
    'company_id', u.company_id,
    'company_name', u.company_name,
    'company_code', u.company_code,
    'company_status', u.company_status,
    'max_employees', COALESCE(u.max_employees, 0)
  );
END;
$$;

-- مستخدمون أُضيفوا بـ bcrypt لكن password_algo بقي legacy
UPDATE saas_users
SET password_algo = 'bcrypt'
WHERE password_hash LIKE '$2%'
  AND COALESCE(password_algo, 'legacy_b64') <> 'bcrypt';

REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT) TO anon, authenticated;

GRANT EXECUTE ON FUNCTION saas_hash_password_bcrypt(TEXT) TO authenticated, service_role;

-- ----------------------------------------------------------
-- 3) RPCs — صلاحية من DB (مدير الشركة وليس super_admin فقط)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_list_company_users(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
BEGIN
  IF cid IS NULL OR cid <= 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
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
SET row_security = off
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

  IF NOT auth_can_manage_tenant_users(cid) THEN
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
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uid INTEGER := p_user_id;
  actor_id INTEGER;
  deleted_count INTEGER;
BEGIN
  IF uid IS NULL OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := auth_saas_user_id();

  IF actor_id IS NOT NULL AND actor_id = uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_delete');
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

  DELETE FROM saas_sessions WHERE user_id = uid;
  DELETE FROM saas_users WHERE id = uid AND company_id = cid;
  GET DIAGNOSTICS deleted_count = ROW_COUNT;

  IF deleted_count < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'delete_failed');
  END IF;

  RETURN jsonb_build_object('ok', true, 'deleted_id', uid);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT DELETE ON TABLE saas_users TO authenticated;

DROP POLICY IF EXISTS "saas_users_delete_super" ON saas_users;
DROP POLICY IF EXISTS "saas_users_delete_tenant" ON saas_users;

CREATE POLICY "saas_users_delete_tenant" ON saas_users
  FOR DELETE TO authenticated
  USING (
    role <> 'super_admin'
    AND auth_can_manage_tenant_users(company_id)
  );

REVOKE ALL ON FUNCTION saas_list_company_users(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_company_users(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) TO authenticated;
