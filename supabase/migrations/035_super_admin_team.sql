-- ============================================================
-- KYNO 035 — Super Admin team, granular permissions, sender names
-- Run after 034 on production
-- ============================================================

-- ── Default permission set (all true for legacy accounts) ──
CREATE OR REPLACE FUNCTION saas_super_admin_default_perms()
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'job_title', '',
    'companies_view', true,
    'companies_create', true,
    'companies_edit', true,
    'companies_delete', true,
    'companies_suspend', true,
    'subscriptions_renew', true,
    'subscriptions_delete', true,
    'users_manage', true,
    'platform_whatsapp', true,
    'platform_announce', true,
    'platform_announce_manage', true,
    'team_manage', true,
    'stats_view', true
  );
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_effective_perms(p_user_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  uid INTEGER := COALESCE(p_user_id, auth_saas_user_id());
  stored JSONB;
  defaults JSONB := saas_super_admin_default_perms();
  merged JSONB;
  k TEXT;
BEGIN
  IF uid IS NULL OR uid <= 0 THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT u.permissions->'super_admin' INTO stored
  FROM saas_users u
  WHERE u.id = uid AND u.role = 'super_admin' AND u.is_active = true
  LIMIT 1;

  IF NOT FOUND OR stored IS NULL OR stored = 'null'::jsonb OR stored = '{}'::jsonb THEN
    RETURN defaults;
  END IF;

  merged := defaults;
  FOR k IN SELECT jsonb_object_keys(stored)
  LOOP
    merged := merged || jsonb_build_object(k, stored->k);
  END LOOP;
  RETURN merged;
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_can(p_perm TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  perms JSONB;
  raw TEXT;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN FALSE;
  END IF;
  IF p_perm IS NULL OR trim(p_perm) = '' THEN
    RETURN FALSE;
  END IF;

  perms := saas_super_admin_effective_perms(auth_saas_user_id());
  raw := perms->>p_perm;
  IF raw IS NULL THEN
    RETURN TRUE;
  END IF;
  RETURN lower(trim(raw)) NOT IN ('false', '0', 'no');
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_sender_meta(p_user_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  uid INTEGER := COALESCE(p_user_id, auth_saas_user_id());
  u RECORD;
  perms JSONB;
  jt TEXT;
BEGIN
  SELECT id, username, display_name, permissions INTO u
  FROM saas_users
  WHERE id = uid AND role = 'super_admin'
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('senderId', NULL, 'senderName', 'الإدارة', 'senderJobTitle', '');
  END IF;
  perms := saas_super_admin_effective_perms(u.id);
  jt := COALESCE(NULLIF(trim(perms->>'job_title'), ''), '');
  RETURN jsonb_build_object(
    'senderId', u.id,
    'senderName', COALESCE(NULLIF(trim(u.display_name), ''), u.username, 'الإدارة'),
    'senderJobTitle', jt
  );
END;
$$;

-- ── Team CRUD ──
CREATE OR REPLACE FUNCTION saas_list_super_admins()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  rows JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  IF NOT saas_super_admin_can('team_manage') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', u.id,
      'username', u.username,
      'display_name', COALESCE(u.display_name, ''),
      'email', COALESCE(u.email, ''),
      'is_active', u.is_active,
      'last_login', u.last_login,
      'created_at', u.created_at,
      'permissions', saas_super_admin_effective_perms(u.id),
      'is_self', u.id = auth_saas_user_id()
    ) ORDER BY u.id
  ), '[]'::jsonb) INTO rows
  FROM saas_users u
  WHERE u.role = 'super_admin';

  RETURN jsonb_build_object('ok', true, 'data', rows);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_super_admin(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  uid INTEGER;
  actor_id INTEGER;
  uname TEXT;
  hash TEXT;
  perms JSONB;
  perm_block JSONB;
  row_out RECORD;
  is_new BOOLEAN := false;
  k TEXT;
  defaults JSONB := saas_super_admin_default_perms();
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  IF NOT saas_super_admin_can('team_manage') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  actor_id := auth_saas_user_id();
  uid := NULLIF((p_payload->>'id')::INTEGER, 0);

  uname := lower(trim(COALESCE(p_payload->>'username', '')));
  IF length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_required');
  END IF;

  IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname AND (uid IS NULL OR id <> uid)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
  END IF;

  perm_block := defaults;
  IF p_payload ? 'permissions' AND jsonb_typeof(p_payload->'permissions') = 'object' THEN
    FOR k IN SELECT jsonb_object_keys(p_payload->'permissions')
    LOOP
      IF k = 'job_title' THEN
        perm_block := perm_block || jsonb_build_object('job_title', p_payload->'permissions'->>'job_title');
      ELSIF defaults ? k THEN
        perm_block := perm_block || jsonb_build_object(k, (p_payload->'permissions'->>k)::boolean);
      END IF;
    END LOOP;
  END IF;
  IF p_payload ? 'job_title' THEN
    perm_block := perm_block || jsonb_build_object('job_title', trim(p_payload->>'job_title'));
  END IF;

  perms := jsonb_build_object('super_admin', perm_block);

  IF uid IS NULL THEN
    IF p_payload->>'password' IS NULL OR length(trim(p_payload->>'password')) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;
    hash := saas_hash_password_bcrypt(trim(p_payload->>'password'));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;
    is_new := true;
    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, company_id, permissions, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_payload->>'display_name'), ''), uname),
      NULLIF(trim(p_payload->>'email'), ''),
      hash, 'bcrypt',
      'super_admin', NULL, perms,
      COALESCE((p_payload->>'is_active')::boolean, true)
    )
    RETURNING * INTO row_out;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM saas_users WHERE id = uid AND role = 'super_admin') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_payload->>'display_name'), ''), display_name, uname),
      email = CASE WHEN p_payload ? 'email' THEN NULLIF(trim(p_payload->>'email'), '') ELSE email END,
      permissions = perms,
      is_active = COALESCE((p_payload->>'is_active')::boolean, is_active),
      updated_at = NOW()
    WHERE id = uid AND role = 'super_admin'
    RETURNING * INTO row_out;

    IF p_payload->>'password' IS NOT NULL AND length(trim(p_payload->>'password')) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_payload->>'password'));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  END IF;

  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'super_admin_created' ELSE 'super_admin_updated' END,
    'saas_users',
    'Super admin ' || row_out.username,
    COALESCE(row_out.display_name, row_out.username),
    row_out.id,
    NULL,
    jsonb_build_object('username', row_out.username, 'permissions', perm_block)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'id', row_out.id,
      'username', row_out.username,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'is_active', row_out.is_active,
      'permissions', perm_block
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_super_admin(p_user_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  actor_id INTEGER;
  target RECORD;
  remaining INTEGER;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  IF NOT saas_super_admin_can('team_manage') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_user_id IS NULL OR p_user_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := auth_saas_user_id();
  IF actor_id = p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cannot_delete_self');
  END IF;

  SELECT * INTO target FROM saas_users WHERE id = p_user_id AND role = 'super_admin' LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  SELECT COUNT(*) INTO remaining FROM saas_users WHERE role = 'super_admin' AND is_active = true;
  IF remaining <= 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'last_super_admin');
  END IF;

  DELETE FROM saas_users WHERE id = p_user_id AND role = 'super_admin';

  PERFORM saas_v3_write_audit(
    'super_admin_deleted', 'saas_users',
    'Deleted super admin id ' || p_user_id::text,
    COALESCE(target.display_name, target.username),
    p_user_id,
    to_jsonb(target),
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'id', p_user_id);
END;
$$;

-- ── Self-service account (display name + job title) ──
DROP FUNCTION IF EXISTS saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION saas_update_saas_account(
  p_user_id INTEGER,
  p_username TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_password TEXT DEFAULT NULL,
  p_display_name TEXT DEFAULT NULL,
  p_job_title TEXT DEFAULT NULL
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
  perms JSONB;
  block JSONB;
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

  SELECT permissions INTO perms FROM saas_users WHERE id = uid;
  block := saas_super_admin_effective_perms(uid);
  IF p_job_title IS NOT NULL THEN
    block := block || jsonb_build_object('job_title', trim(p_job_title));
    perms := COALESCE(perms, '{}'::jsonb) || jsonb_build_object('super_admin', block);
  END IF;

  UPDATE saas_users SET
    username = COALESCE(uname, username),
    display_name = CASE
      WHEN p_display_name IS NOT NULL THEN COALESCE(NULLIF(trim(p_display_name), ''), display_name, username)
      ELSE display_name
    END,
    email = CASE WHEN p_email IS NOT NULL THEN NULLIF(trim(p_email), '') ELSE email END,
    permissions = CASE WHEN p_job_title IS NOT NULL THEN perms ELSE permissions END,
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
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'job_title', saas_super_admin_effective_perms(uid)->>'job_title'
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ── Platform globals with permission checks + sender stamping ──
CREATE OR REPLACE FUNCTION saas_save_platform_globals(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  cnt INTEGER := 0;
  old_ann JSONB := '[]'::jsonb;
  new_ann JSONB;
  merged JSONB := '[]'::jsonb;
  elem JSONB;
  old_ids TEXT[];
  sender JSONB;
  i INTEGER;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  IF p_payload ? 'support_whatsapp' OR p_payload ? 'support_whatsapp_team' THEN
    IF NOT saas_super_admin_can('platform_whatsapp') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
  END IF;

  IF p_payload ? 'announcements' THEN
    IF NOT saas_super_admin_can('platform_announce') AND NOT saas_super_admin_can('platform_announce_manage') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;

    SELECT COALESCE(value::jsonb, '[]'::jsonb) INTO old_ann
    FROM app_settings WHERE key = 'global:platform_announcements' LIMIT 1;
    IF old_ann IS NULL OR jsonb_typeof(old_ann) <> 'array' THEN
      old_ann := '[]'::jsonb;
    END IF;

    SELECT array_agg(x->>'id') INTO old_ids
    FROM jsonb_array_elements(old_ann) x
    WHERE x->>'id' IS NOT NULL;

    new_ann := p_payload->'announcements';
    IF new_ann IS NULL OR jsonb_typeof(new_ann) <> 'array' THEN
      new_ann := '[]'::jsonb;
    END IF;

    sender := saas_super_admin_sender_meta();

    FOR i IN 0 .. jsonb_array_length(new_ann) - 1 LOOP
      elem := new_ann->i;
      IF elem->>'id' IS NOT NULL AND old_ids IS NOT NULL AND elem->>'id' = ANY(old_ids) THEN
        merged := merged || jsonb_build_array(elem);
      ELSE
        merged := merged || jsonb_build_array(
          elem || jsonb_build_object(
            'senderId', sender->'senderId',
            'senderName', sender->>'senderName',
            'senderJobTitle', sender->>'senderJobTitle'
          )
        );
      END IF;
    END LOOP;

    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:platform_announcements', merged::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  IF p_payload ? 'support_whatsapp' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:support_whatsapp', trim(p_payload->>'support_whatsapp'), NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  IF p_payload ? 'support_whatsapp_team' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:support_whatsapp_team', trim(p_payload->>'support_whatsapp_team'), NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

-- ── Patch super-admin company RPCs with permission checks ──
CREATE OR REPLACE FUNCTION saas_super_upsert_company(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  before_row JSONB;
  after_row companies%ROWTYPE;
  new_code TEXT;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := NULLIF((p_payload->>'id')::INTEGER, 0);
  IF cid IS NULL THEN
    IF NOT saas_super_admin_can('companies_create') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
  ELSE
    IF NOT saas_super_admin_can('companies_edit') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
  END IF;

  new_code := upper(trim(COALESCE(p_payload->>'company_code', p_payload->>'code', '')));

  IF cid IS NOT NULL THEN
    SELECT to_jsonb(c.*) INTO before_row FROM companies c WHERE c.id = cid LIMIT 1;
    IF before_row IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
    END IF;

    UPDATE companies SET
      company_name = COALESCE(NULLIF(trim(p_payload->>'company_name'), ''), NULLIF(trim(p_payload->>'name'), ''), company_name),
      company_code = CASE WHEN new_code <> '' THEN new_code ELSE company_code END,
      status = COALESCE(NULLIF(trim(p_payload->>'status'), ''), status),
      max_employees = COALESCE((p_payload->>'max_employees')::INTEGER, max_employees),
      notes = COALESCE(p_payload->>'notes', notes),
      updated_at = NOW()
    WHERE id = cid
    RETURNING * INTO after_row;
  ELSE
    IF new_code = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_code_required');
    END IF;
    INSERT INTO companies (company_name, company_code, status, max_employees, notes)
    VALUES (
      COALESCE(NULLIF(trim(p_payload->>'company_name'), ''), NULLIF(trim(p_payload->>'name'), ''), 'شركة جديدة'),
      new_code,
      COALESCE(NULLIF(trim(p_payload->>'status'), ''), 'pending'),
      COALESCE((p_payload->>'max_employees')::INTEGER, 50),
      COALESCE(p_payload->>'notes', '')
    )
    RETURNING * INTO after_row;
    before_row := NULL;
  END IF;

  PERFORM saas_v3_write_audit(
    CASE WHEN cid IS NULL THEN 'company_created' ELSE 'company_updated' END,
    'companies',
    'Super admin company upsert id ' || after_row.id::text,
    after_row.company_name,
    after_row.id,
    before_row,
    to_jsonb(after_row)
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(after_row));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_code_duplicate');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_toggle_company_status(
  p_company_id INTEGER,
  p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  before_row JSONB;
  after_row companies%ROWTYPE;
  st TEXT := NULLIF(trim(p_status), '');
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('companies_suspend') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL OR st IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;
  IF st NOT IN ('active', 'suspended', 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  SELECT to_jsonb(c.*) INTO before_row FROM companies c WHERE c.id = p_company_id LIMIT 1;
  IF before_row IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;

  UPDATE companies SET status = st, updated_at = NOW()
  WHERE id = p_company_id
  RETURNING * INTO after_row;

  PERFORM saas_v3_write_audit(
    'company_status_changed', 'companies',
    'Status -> ' || st,
    after_row.company_name,
    after_row.id,
    before_row,
    to_jsonb(after_row)
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(after_row));
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_delete_company(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  comp RECORD;
  emp_ids INTEGER[];
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('companies_delete') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO comp FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;

  SELECT array_agg(e.id) INTO emp_ids FROM employees e WHERE e.company_id = p_company_id;

  DELETE FROM subscriptions WHERE company_id = p_company_id;
  DELETE FROM saas_users WHERE company_id = p_company_id;
  IF emp_ids IS NOT NULL THEN
    DELETE FROM employee_devices WHERE employee_id = ANY(emp_ids);
  END IF;
  DELETE FROM attendance WHERE company_id = p_company_id;
  DELETE FROM salary_records WHERE company_id = p_company_id;
  DELETE FROM employees WHERE company_id = p_company_id;
  DELETE FROM departments WHERE company_id = p_company_id;
  DELETE FROM notifications WHERE company_id = p_company_id;
  DELETE FROM companies WHERE id = p_company_id;

  PERFORM saas_v3_write_audit(
    'company_deleted', 'companies',
    'Deleted company ' || p_company_id::text,
    comp.company_name,
    p_company_id,
    to_jsonb(comp),
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'company_id', p_company_id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_renew_subscription(
  p_company_id INTEGER,
  p_duration_days INTEGER DEFAULT 30,
  p_amount INTEGER DEFAULT 0,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing RECORD;
  start_d DATE;
  end_d DATE;
  dur_days INTEGER := GREATEST(1, COALESCE(p_duration_days, 30));
  pay_amt INTEGER := GREATEST(0, COALESCE(p_amount, 0));
  dur_months INTEGER;
  note_text TEXT;
  actor TEXT;
  sub_id INTEGER;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('subscriptions_renew') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT * INTO existing FROM subscriptions
  WHERE company_id = p_company_id
  ORDER BY created_at DESC NULLS LAST, id DESC
  LIMIT 1;

  dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
  note_text := COALESCE(NULLIF(trim(p_notes), ''), 'تمديد ' || dur_days::text || ' يوم');
  actor := COALESCE(
    (saas_super_admin_sender_meta()->>'senderName'),
    auth.jwt() -> 'app_metadata' ->> 'display_name',
    auth.jwt() ->> 'email',
    'system'
  );

  IF existing.id IS NOT NULL AND existing.status = 'active' AND existing.end_date >= CURRENT_DATE THEN
    start_d := existing.start_date;
    end_d := existing.end_date + dur_days;
    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      status = 'active',
      duration_months = dur_months,
      amount = pay_amt,
      notes = note_text,
      activated_by = actor,
      updated_at = NOW()
    WHERE id = existing.id
    RETURNING id INTO sub_id;
  ELSIF existing.id IS NOT NULL THEN
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      status = 'active',
      duration_months = dur_months,
      amount = pay_amt,
      notes = note_text,
      activated_by = actor,
      updated_at = NOW()
    WHERE id = existing.id
    RETURNING id INTO sub_id;
  ELSE
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    INSERT INTO subscriptions (
      company_id, plan_name, start_date, end_date, status,
      duration_months, amount, notes, activated_by
    ) VALUES (
      p_company_id, 'PRO', start_d, end_d, 'active',
      dur_months, pay_amt, note_text, actor
    )
    RETURNING id INTO sub_id;
  END IF;

  UPDATE companies SET status = 'active', updated_at = NOW() WHERE id = p_company_id;

  PERFORM saas_v3_write_audit(
    'subscription_renewed', 'subscriptions',
    note_text,
    'company:' || p_company_id::text,
    p_company_id,
    CASE WHEN existing.id IS NOT NULL THEN to_jsonb(existing) ELSE NULL END,
    jsonb_build_object('subscription_id', sub_id, 'end_date', end_d)
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', sub_id, 'end_date', end_d);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_delete_subscription(p_subscription_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sub RECORD;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('subscriptions_delete') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_subscription_id IS NULL OR p_subscription_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO sub FROM subscriptions WHERE id = p_subscription_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  DELETE FROM subscriptions WHERE id = p_subscription_id;

  PERFORM saas_v3_write_audit(
    'subscription_deleted', 'subscriptions',
    'Deleted subscription ' || p_subscription_id::text,
    'company:' || sub.company_id::text,
    sub.company_id,
    to_jsonb(sub),
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'deleted', 1);
END;
$$;

-- ── Company user management permission for super admins ──
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

  IF actor_role = 'company_user'
     AND COALESCE((actor_perms ->> 'users_permissions')::boolean, false) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;

-- ── Grants ──
REVOKE ALL ON FUNCTION saas_super_admin_default_perms() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_effective_perms(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_can(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_sender_meta(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_list_super_admins() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_upsert_super_admin(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_delete_super_admin(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_list_super_admins() TO authenticated;
GRANT EXECUTE ON FUNCTION saas_upsert_super_admin(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION saas_delete_super_admin(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;
