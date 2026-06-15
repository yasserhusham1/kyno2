-- ============================================================
-- KYNO 036 — Super Admin view-only mode + page view permissions
-- Run after 035
-- ============================================================

CREATE OR REPLACE FUNCTION saas_super_admin_default_perms()
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'job_title', '',
    'view_only', false,
    'companies_view', true,
    'companies_create', true,
    'companies_edit', true,
    'companies_delete', true,
    'companies_suspend', true,
    'subscriptions_view', true,
    'subscriptions_renew', true,
    'subscriptions_delete', true,
    'users_view', true,
    'users_manage', true,
    'platform_view', true,
    'platform_whatsapp', true,
    'platform_announce', true,
    'platform_announce_manage', true,
    'team_manage', true,
    'stats_view', true
  );
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_is_write_perm(p_perm TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(p_perm, '') IN (
    'companies_create', 'companies_edit', 'companies_delete', 'companies_suspend',
    'subscriptions_renew', 'subscriptions_delete',
    'users_manage',
    'platform_whatsapp', 'platform_announce', 'platform_announce_manage',
    'team_manage'
  );
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
  view_only BOOLEAN;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN FALSE;
  END IF;
  IF p_perm IS NULL OR trim(p_perm) = '' THEN
    RETURN FALSE;
  END IF;

  perms := saas_super_admin_effective_perms(auth_saas_user_id());
  view_only := COALESCE((perms->>'view_only')::boolean, false);

  IF view_only AND saas_super_admin_is_write_perm(p_perm) THEN
    RETURN FALSE;
  END IF;

  raw := perms->>p_perm;
  IF raw IS NULL THEN
    RETURN NOT saas_super_admin_is_write_perm(p_perm);
  END IF;
  RETURN lower(trim(raw)) NOT IN ('false', '0', 'no');
END;
$$;

-- Enforce view_only on save (server-side)
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
  write_key TEXT;
  write_keys TEXT[] := ARRAY[
    'companies_create', 'companies_edit', 'companies_delete', 'companies_suspend',
    'subscriptions_renew', 'subscriptions_delete',
    'users_manage',
    'platform_whatsapp', 'platform_announce', 'platform_announce_manage',
    'team_manage'
  ];
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

  IF COALESCE((perm_block->>'view_only')::boolean, false) THEN
    FOREACH write_key IN ARRAY write_keys LOOP
      perm_block := perm_block || jsonb_build_object(write_key, false);
    END LOOP;
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

REVOKE ALL ON FUNCTION saas_upsert_super_admin(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_super_admin(JSONB) TO authenticated;
