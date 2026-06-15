-- ============================================================
-- KYNO 039 — Preserve permissions on partial user update + device cleanup
-- ============================================================

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
    RETURN saas_super_admin_can('users_manage');
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

  IF actor_role = 'company_user' THEN
    IF COALESCE((actor_perms ->> 'users_permissions')::boolean, false) THEN
      RETURN TRUE;
    END IF;
    IF COALESCE((actor_perms ->> 'users_permissions_view')::boolean, false)
       OR COALESCE((actor_perms ->> 'users_permissions_add')::boolean, false)
       OR COALESCE((actor_perms ->> 'users_permissions_edit')::boolean, false)
       OR COALESCE((actor_perms ->> 'users_permissions_delete')::boolean, false) THEN
      RETURN TRUE;
    END IF;
  END IF;

  RETURN FALSE;
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
  stored_hash TEXT;
  perms JSONB;
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

    perms := CASE
      WHEN p_permissions IS NULL THEN (
        SELECT COALESCE(permissions, '{}'::jsonb) FROM saas_users WHERE id = uid LIMIT 1
      )
      ELSE COALESCE(p_permissions, '{}'::jsonb)
    END;

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

    perms := COALESCE(p_permissions, '{}'::jsonb);

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

CREATE OR REPLACE FUNCTION saas_delete_employee(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(emp);

  DELETE FROM employee_devices WHERE employee_id = p_employee_id;
  DELETE FROM employees WHERE id = p_employee_id;

  PERFORM saas_v3_write_audit(
    'employee_deleted', 'employees',
    'Deleted employee ' || p_employee_id::TEXT,
    emp.name,
    emp.company_id,
    before_row,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;
