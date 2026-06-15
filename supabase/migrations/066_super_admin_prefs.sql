-- ============================================================
-- KYNO 066 — Super Admin user prefs (theme, activity log reads)
-- Fixes no_company_context when super admin saves notifications
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

CREATE OR REPLACE FUNCTION saas_super_admin_user_id()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_prefs_key(p_user_id INTEGER)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'global:sa_user:' || p_user_id::TEXT || ':prefs';
$$;

CREATE OR REPLACE FUNCTION saas_get_super_admin_prefs()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  raw TEXT;
  prefs JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = saas_super_admin_prefs_key(uid)
  LIMIT 1;

  prefs := COALESCE(NULLIF(trim(raw), '')::jsonb, '{}'::jsonb);
  IF jsonb_typeof(prefs) <> 'object' THEN
    prefs := '{}'::jsonb;
  END IF;

  RETURN jsonb_build_object('ok', true, 'prefs', prefs, 'user_id', uid);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_super_admin_prefs(p_prefs JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  db_key TEXT;
  existing JSONB := '{}'::jsonb;
  merged JSONB;
  raw TEXT;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  IF p_prefs IS NULL OR jsonb_typeof(p_prefs) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_prefs');
  END IF;

  db_key := saas_super_admin_prefs_key(uid);

  SELECT s.value INTO raw FROM app_settings s WHERE s.key = db_key LIMIT 1;
  IF raw IS NOT NULL AND trim(raw) <> '' THEN
    BEGIN
      existing := raw::jsonb;
    EXCEPTION WHEN others THEN
      existing := '{}'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(existing) <> 'object' THEN
    existing := '{}'::jsonb;
  END IF;

  merged := existing || p_prefs;

  INSERT INTO app_settings (key, value, updated_at)
  VALUES (db_key, merged::text, NOW())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

  RETURN jsonb_build_object('ok', true, 'prefs', merged, 'user_id', uid);
END;
$$;

REVOKE ALL ON FUNCTION saas_super_admin_user_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_prefs_key(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_get_super_admin_prefs() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_upsert_super_admin_prefs(JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_get_super_admin_prefs() TO authenticated;
GRANT EXECUTE ON FUNCTION saas_upsert_super_admin_prefs(JSONB) TO authenticated;
