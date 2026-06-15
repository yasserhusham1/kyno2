-- 072: Stabilize app_settings / super-admin prefs / RLS / hot indexes
-- Fixes repeated 57014 timeouts and closes global:sa_user prefs leakage.

-- ----------------------------------------------------------
-- 1) Hot indexes (safe / idempotent)
-- ----------------------------------------------------------
CREATE INDEX IF NOT EXISTS app_settings_key_like_idx
  ON app_settings (key text_pattern_ops);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'subscriptions'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'subscriptions' AND column_name = 'company_id'
    ) AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'subscriptions' AND column_name = 'created_at'
    ) THEN
      EXECUTE 'CREATE INDEX IF NOT EXISTS subscriptions_company_latest_idx ON subscriptions (company_id, created_at DESC, id DESC)';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'attendance'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'attendance' AND column_name = 'employee_id'
    ) AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'attendance' AND column_name = 'date_iso'
    ) THEN
      EXECUTE 'CREATE INDEX IF NOT EXISTS attendance_employee_date_idx ON attendance (employee_id, date_iso DESC)';
    END IF;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'salary_records'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'salary_records' AND column_name = 'paid_at'
    ) THEN
      ALTER TABLE salary_records ADD COLUMN paid_at TIMESTAMPTZ;
    END IF;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'employee_notifications'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'employee_notifications' AND column_name = 'employee_id'
    ) AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'employee_notifications' AND column_name = 'created_at'
    ) THEN
      EXECUTE 'CREATE INDEX IF NOT EXISTS employee_notifications_emp_created_idx ON employee_notifications (employee_id, created_at DESC)';
    END IF;
  END IF;
END $$;

-- ----------------------------------------------------------
-- 2) Tight app_settings RLS
-- ----------------------------------------------------------
DROP POLICY IF EXISTS "settings_read" ON app_settings;
DROP POLICY IF EXISTS "settings_write" ON app_settings;
DROP POLICY IF EXISTS "settings_update" ON app_settings;
DROP POLICY IF EXISTS "settings_deny_anon" ON app_settings;
DROP POLICY IF EXISTS "settings_select_tenant" ON app_settings;
DROP POLICY IF EXISTS "settings_write_tenant" ON app_settings;
DROP POLICY IF EXISTS "settings_update_tenant" ON app_settings;
DROP POLICY IF EXISTS "tenant_settings_only" ON app_settings;
DROP POLICY IF EXISTS "super_admin_access_settings" ON app_settings;
DROP POLICY IF EXISTS deny_anon_app_settings ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_only ON app_settings;
DROP POLICY IF EXISTS app_settings_super_admin ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_select ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_insert ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_update ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_delete ON app_settings;

CREATE POLICY deny_anon_app_settings ON app_settings
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY app_settings_tenant_select ON app_settings
  FOR SELECT TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND (
        key LIKE ('company:' || auth_company_id()::text || ':%')
        OR key IN (
          'global:support_whatsapp',
          'global:support_whatsapp_team',
          'global:platform_announcements',
          'platform:system_version'
        )
      )
    )
  );

CREATE POLICY app_settings_tenant_insert ON app_settings
  FOR INSERT TO authenticated
  WITH CHECK (
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND key LIKE ('company:' || auth_company_id()::text || ':%')
    )
  );

CREATE POLICY app_settings_tenant_update ON app_settings
  FOR UPDATE TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND key LIKE ('company:' || auth_company_id()::text || ':%')
    )
  )
  WITH CHECK (
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND key LIKE ('company:' || auth_company_id()::text || ':%')
    )
  );

CREATE POLICY app_settings_tenant_delete ON app_settings
  FOR DELETE TO authenticated
  USING (auth_is_super_admin());

-- ----------------------------------------------------------
-- 3) Super admin prefs: parse safely, cap activity_log, avoid huge-row timeouts
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_super_admin_extract_theme_from_raw(p_raw TEXT)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  m TEXT[];
  theme TEXT;
BEGIN
  IF p_raw IS NULL OR p_raw = '' THEN
    RETURN '{}'::jsonb;
  END IF;
  m := regexp_match(p_raw, '"ui_theme"\s*:\s*"([^"]+)"');
  IF m IS NOT NULL THEN
    theme := m[1];
    IF theme IN ('light', 'dark') THEN
      RETURN jsonb_build_object('ui_theme', theme);
    END IF;
  END IF;
  m := regexp_match(p_raw, '"theme"\s*:\s*"([^"]+)"');
  IF m IS NOT NULL THEN
    theme := m[1];
    IF theme IN ('light', 'dark') THEN
      RETURN jsonb_build_object('theme', theme);
    END IF;
  END IF;
  RETURN '{}'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_trim_activity_log(p_log JSONB, p_max INTEGER DEFAULT 120)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  arr JSONB;
  max_n INTEGER := GREATEST(20, LEAST(COALESCE(p_max, 120), 200));
BEGIN
  IF p_log IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  arr := p_log;
  IF jsonb_typeof(arr) = 'string' THEN
    BEGIN
      arr := (p_log #>> '{}')::jsonb;
    EXCEPTION WHEN others THEN
      RETURN '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN (
    SELECT COALESCE(jsonb_agg(x ORDER BY keep_ord), '[]'::jsonb)
    FROM (
      SELECT x, keep_ord
      FROM (
        SELECT DISTINCT ON (COALESCE(x->>'id', ord::text))
          x,
          ord AS keep_ord
        FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord)
        ORDER BY COALESCE(x->>'id', ord::text), ord
      ) dedup
      ORDER BY keep_ord
      LIMIT max_n
    ) limited
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_parse_activity_log(p_val JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  raw TEXT;
BEGIN
  IF p_val IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_val) = 'array' THEN
    RETURN saas_super_admin_trim_activity_log(p_val, 120);
  END IF;
  IF jsonb_typeof(p_val) = 'string' THEN
    raw := p_val #>> '{}';
    IF raw IS NULL OR trim(raw) = '' OR length(raw) > 800000 THEN
      RETURN '[]'::jsonb;
    END IF;
    BEGIN
      RETURN saas_super_admin_trim_activity_log(raw::jsonb, 120);
    EXCEPTION WHEN others THEN
      RETURN '[]'::jsonb;
    END;
  END IF;
  RETURN '[]'::jsonb;
END;
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
  prefs JSONB := '{}'::jsonb;
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

  IF raw IS NULL OR trim(raw) = '' THEN
    RETURN jsonb_build_object('ok', true, 'prefs', '{}'::jsonb, 'user_id', uid);
  END IF;

  IF length(raw) > 800000 THEN
    prefs := saas_super_admin_extract_theme_from_raw(raw);
    RETURN jsonb_build_object('ok', true, 'prefs', prefs || jsonb_build_object('activity_log', '[]'::jsonb), 'user_id', uid, 'trim_required', true);
  END IF;

  BEGIN
    prefs := raw::jsonb;
  EXCEPTION WHEN others THEN
    prefs := '{}'::jsonb;
  END;

  IF jsonb_typeof(prefs) <> 'object' THEN
    prefs := '{}'::jsonb;
  END IF;

  IF prefs ? 'activity_log' THEN
    prefs := prefs - 'activity_log' || jsonb_build_object(
      'activity_log', saas_super_admin_parse_activity_log(prefs->'activity_log')
    );
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
  raw TEXT;
  existing JSONB := '{}'::jsonb;
  incoming JSONB;
  merged JSONB;
  existing_log JSONB := '[]'::jsonb;
  incoming_log JSONB := '[]'::jsonb;
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

  incoming := p_prefs;
  db_key := saas_super_admin_prefs_key(uid);

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = db_key
  LIMIT 1;

  IF raw IS NOT NULL AND trim(raw) <> '' THEN
    IF length(raw) > 800000 THEN
      existing := saas_super_admin_extract_theme_from_raw(raw);
    ELSE
      BEGIN
        existing := raw::jsonb;
      EXCEPTION WHEN others THEN
        existing := '{}'::jsonb;
      END;
    END IF;
  END IF;

  IF jsonb_typeof(existing) <> 'object' THEN
    existing := '{}'::jsonb;
  END IF;

  existing_log := saas_super_admin_parse_activity_log(existing->'activity_log');
  incoming_log := saas_super_admin_parse_activity_log(incoming->'activity_log');

  merged := existing || incoming;
  IF incoming ? 'activity_log' OR existing ? 'activity_log' THEN
    merged := merged - 'activity_log' || jsonb_build_object(
      'activity_log',
      saas_super_admin_trim_activity_log(incoming_log || existing_log, 120)
    );
  END IF;

  INSERT INTO app_settings (key, value, updated_at)
  VALUES (db_key, merged::text, NOW())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

  RETURN jsonb_build_object(
    'ok', true,
    'prefs', merged,
    'user_id', uid,
    'activity_count', jsonb_array_length(COALESCE(merged->'activity_log', '[]'::jsonb))
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- Replace bloated legacy super-admin prefs without parsing them.
UPDATE app_settings
SET value = saas_super_admin_extract_theme_from_raw(value)::text,
    updated_at = NOW()
WHERE key LIKE 'global:sa_user:%:prefs'
  AND length(COALESCE(value, '')) > 800000;

REVOKE ALL ON FUNCTION saas_super_admin_extract_theme_from_raw(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_trim_activity_log(JSONB, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_parse_activity_log(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_get_super_admin_prefs() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_upsert_super_admin_prefs(JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_get_super_admin_prefs() TO authenticated;
GRANT EXECUTE ON FUNCTION saas_upsert_super_admin_prefs(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_get_super_admin_prefs() IS
  'Safe super-admin prefs reader; avoids parsing bloated legacy JSON rows';
COMMENT ON FUNCTION saas_upsert_super_admin_prefs(JSONB) IS
  'Safe super-admin prefs writer; caps activity_log and preserves newest entries';

-- ----------------------------------------------------------
-- 4) Employee phone profile: return job / phone / salary fields
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_fetch_employee_client_profile(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  gps_prefix TEXT;
  v_lat TEXT;
  v_lng TEXT;
  v_range TEXT;
  v_name TEXT;
  v_finance TEXT;
  finance_arr JSONB := '[]'::jsonb;
  emp_finance JSONB := '[]'::jsonb;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF emp.company_id IS NOT NULL THEN
    gps_prefix := 'company:' || emp.company_id::text || ':';
    SELECT value INTO v_lat FROM app_settings WHERE key = gps_prefix || 'gps_lat' LIMIT 1;
    SELECT value INTO v_lng FROM app_settings WHERE key = gps_prefix || 'gps_lng' LIMIT 1;
    SELECT value INTO v_range FROM app_settings WHERE key = gps_prefix || 'gps_range' LIMIT 1;
    SELECT value INTO v_name FROM app_settings WHERE key = gps_prefix || 'gps_name' LIMIT 1;
    SELECT value INTO v_finance FROM app_settings WHERE key = gps_prefix || 'finance_items' LIMIT 1;
  END IF;

  IF v_finance IS NOT NULL AND v_finance <> '' THEN
    BEGIN
      finance_arr := v_finance::jsonb;
    EXCEPTION WHEN others THEN
      finance_arr := '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(COALESCE(finance_arr, '[]'::jsonb)) <> 'array' THEN
    finance_arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO emp_finance
  FROM jsonb_array_elements(COALESCE(finance_arr, '[]'::jsonb)) item
  WHERE (item->>'empId')::text = emp.id::text
     OR (item->>'emp_id')::text = emp.id::text
     OR (item->>'employee_id')::text = emp.id::text;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'role', emp.role,
    'phone', emp.phone,
    'salary', emp.salary,
    'salary_type', emp.salary_type,
    'salary_half', emp.salary_half,
    'daily_rate', emp.daily_rate,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE,
    'avatar_url', emp.avatar_url,
    'finance_items', emp_finance,
    'gps_lat', NULLIF(trim(v_lat), ''),
    'gps_lng', NULLIF(trim(v_lng), ''),
    'gps_range', NULLIF(trim(v_range), ''),
    'gps_name', NULLIF(trim(v_name), '')
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) TO anon, authenticated;

COMMENT ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) IS
  'Device-authorized employee profile with job, department, phone, salary and GPS settings';

CREATE OR REPLACE FUNCTION saas_fetch_employee_leaves(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  rows JSONB;
  lim INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 120), 300));
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.from_date DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT *
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = emp.company_id
    ORDER BY l.from_date DESC, l.id DESC
    LIMIT lim
  ) x;

  RETURN jsonb_build_object('ok', true, 'data', rows);
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_leaves(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_leaves(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

COMMENT ON FUNCTION saas_fetch_employee_leaves(INTEGER, TEXT, TEXT, INTEGER) IS
  'Device-authorized employee leave/absence list for the phone portal';

CREATE OR REPLACE FUNCTION saas_fetch_employee_notifications(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  table_rows JSONB := '[]'::jsonb;
  settings_rows JSONB := '[]'::jsonb;
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
  sub_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  IF emp.remote_attend IS TRUE THEN authorized := TRUE; END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  settings_key := 'company:' || emp.company_id::text || ':employee_notifications';
  SELECT value INTO raw_val FROM app_settings WHERE key = settings_key LIMIT 1;
  IF raw_val IS NULL THEN
    settings_key := 'company:' || emp.company_id::text || ':employeeNotifications';
    SELECT value INTO raw_val FROM app_settings WHERE key = settings_key LIMIT 1;
  END IF;

  IF raw_val IS NOT NULL AND raw_val <> '' THEN
    BEGIN
      arr := raw_val::jsonb;
    EXCEPTION WHEN others THEN
      arr := '[]'::jsonb;
    END;
  ELSE
    arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO settings_rows
  FROM (
    SELECT x
    FROM jsonb_array_elements(COALESCE(arr, '[]'::jsonb)) x
    WHERE (x->>'empId')::text = p_employee_id::text
       OR (x->>'emp_id')::text = p_employee_id::text
    ORDER BY COALESCE(x->>'ts', x->>'createdAt', x->>'created_at') DESC NULLS LAST
    LIMIT lim
  ) s;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', COALESCE(n.notif_ref, n.id::text),
        '_remote_id', n.id,
        'emp_id', n.employee_id,
        'employee_id', n.employee_id,
        'title', n.title,
        'body', n.body,
        'type', n.notif_type,
        'finance_type', n.notif_type,
        'is_read', n.is_read,
        'created_at', n.created_at,
        'company_id', n.company_id,
        '_source', 'table'
      ) ORDER BY n.created_at DESC
    ), '[]'::jsonb
  ) INTO table_rows
  FROM (
    SELECT * FROM employee_notifications en
    WHERE en.employee_id = p_employee_id AND en.company_id = emp.company_id
    ORDER BY en.created_at DESC LIMIT lim
  ) n;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'notifications', table_rows || settings_rows,
    'table_notifications', table_rows,
    'settings_notifications', settings_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

COMMENT ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) IS
  'Device-authorized merged employee notifications for the phone portal';

CREATE OR REPLACE FUNCTION saas_fetch_employee_salary_records(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
  sub_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  IF emp.remote_attend IS TRUE THEN authorized := TRUE; END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(s.*) ORDER BY s.month_iso DESC), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM salary_records sr
    WHERE sr.employee_id = p_employee_id
      AND sr.company_id = emp.company_id
      AND sr.status = 'مدفوع'
    ORDER BY sr.month_iso DESC
    LIMIT lim
  ) s;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_salary_records(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_salary_records(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

COMMENT ON FUNCTION saas_fetch_employee_salary_records(INTEGER, TEXT, TEXT, INTEGER) IS
  'Device-authorized paid salary history for the employee phone portal';

CREATE OR REPLACE FUNCTION saas_mark_salary_record_paid(
  p_employee_id INTEGER,
  p_month TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  emp RECORD;
  rec salary_records%ROWTYPE;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 OR NULLIF(trim(COALESCE(p_month, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT * INTO emp FROM employees e
  WHERE e.id = p_employee_id AND e.company_id = cid
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
  END IF;

  UPDATE salary_records
  SET status = 'مدفوع',
      paid_at = COALESCE(paid_at, NOW()),
      issued_at = COALESCE(issued_at, NOW())
  WHERE employee_id = p_employee_id
    AND company_id = cid
    AND month_iso = p_month
  RETURNING * INTO rec;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'salary_record_not_found');
  END IF;

  UPDATE employees
  SET sal_status = 'مدفوع'
  WHERE id = p_employee_id AND company_id = cid;

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(rec));
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_salary_record_paid(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_salary_record_paid(INTEGER, TEXT) TO authenticated;

COMMENT ON FUNCTION saas_mark_salary_record_paid(INTEGER, TEXT) IS
  'Marks an issued salary record as paid so it appears in employee salary history';

DROP FUNCTION IF EXISTS saas_update_salary_record_status(INTEGER, TEXT, TEXT);
DROP FUNCTION IF EXISTS saas_update_salary_record_status(INTEGER, TEXT, TEXT, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION saas_update_salary_record_status(
  p_employee_id INTEGER,
  p_month TEXT,
  p_status TEXT,
  p_paid_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  emp RECORD;
  rec salary_records%ROWTYPE;
  st TEXT := NULLIF(trim(COALESCE(p_status, '')), '');
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 OR NULLIF(trim(COALESCE(p_month, '')), '') IS NULL OR st IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF st NOT IN ('معلق', 'مُصدر', 'مدفوع') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT * INTO emp FROM employees e
  WHERE e.id = p_employee_id AND e.company_id = cid
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
  END IF;

  UPDATE salary_records
  SET status = st,
      paid_at = CASE WHEN st = 'مدفوع' THEN COALESCE(p_paid_at, paid_at, NOW()) ELSE NULL END,
      issued_at = COALESCE(issued_at, NOW())
  WHERE employee_id = p_employee_id
    AND company_id = cid
    AND month_iso = p_month
  RETURNING * INTO rec;

  UPDATE employees
  SET sal_status = st
  WHERE id = p_employee_id AND company_id = cid;

  RETURN jsonb_build_object('ok', true, 'data', COALESCE(to_jsonb(rec), jsonb_build_object(
    'employee_id', p_employee_id,
    'company_id', cid,
    'month_iso', p_month,
    'status', st
  )));
END;
$$;

REVOKE ALL ON FUNCTION saas_update_salary_record_status(INTEGER, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_update_salary_record_status(INTEGER, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;

COMMENT ON FUNCTION saas_update_salary_record_status(INTEGER, TEXT, TEXT, TIMESTAMPTZ) IS
  'Updates salary record and employee salary status for pending/issued/paid transitions';
