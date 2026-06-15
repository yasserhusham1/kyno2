-- ============================================================
-- KYNO 033 — Final Production Lockdown
-- Requires 030 + 031 + 032 applied first
-- REVOKE direct writes — RPC (SECURITY DEFINER) only
-- Does NOT alter RLS 030 policies
-- ============================================================

-- ----------------------------------------------------------
-- 0) Fix legacy device token RPC — no company_id = 1
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_device_token(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_token TEXT,
  p_label TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tok TEXT := NULLIF(trim(p_token), '');
  tenant JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT company_id INTO cid FROM employees WHERE id = p_employee_id LIMIT 1;
  IF NOT FOUND OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id,
    fingerprint, ip, linked_at, token_used_at, last_login
  ) VALUES (
    p_employee_id, p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok, NOW(), cid, '', '', NULL, NULL, NULL
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, NOW()),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = cid,
    fingerprint = CASE WHEN employee_devices.fingerprint IS NOT NULL AND employee_devices.fingerprint <> '' THEN employee_devices.fingerprint ELSE '' END,
    ip = CASE WHEN employee_devices.ip IS NOT NULL AND employee_devices.ip <> '' THEN employee_devices.ip ELSE '' END;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'slot', p_slot, 'token', tok);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ----------------------------------------------------------
-- 1) Supplemental write RPCs (lockdown coverage)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_employee_device(
  p_employee_id INTEGER,
  p_slot INTEGER,
  p_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
  after_row JSONB;
  dev_id INTEGER;
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT to_jsonb(d.*) INTO before_row
  FROM employee_devices d
  WHERE d.employee_id = p_employee_id AND d.slot = p_slot
  LIMIT 1;

  INSERT INTO employee_devices (
    employee_id, company_id, slot, label, ip, fingerprint, pin, token,
    token_created_at, token_used_at, device_info, linked_at, last_login
  ) VALUES (
    p_employee_id,
    emp.company_id,
    p_slot,
    COALESCE(p_payload->>'label', 'الهاتف ' || p_slot::text),
    COALESCE(p_payload->>'ip', ''),
    COALESCE(p_payload->>'fingerprint', ''),
    COALESCE(p_payload->>'pin', ''),
    NULLIF(p_payload->>'token', ''),
    NULLIF(p_payload->>'token_created_at', '')::timestamptz,
    NULLIF(p_payload->>'token_used_at', '')::timestamptz,
    COALESCE(p_payload->'device_info', '{}'::jsonb),
    NULLIF(p_payload->>'linked_at', '')::timestamptz,
    NULLIF(p_payload->>'last_login', '')::timestamptz
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    label = COALESCE(NULLIF(EXCLUDED.label, ''), employee_devices.label),
    ip = CASE
      WHEN EXCLUDED.ip IS NOT NULL AND EXCLUDED.ip <> '' THEN EXCLUDED.ip
      ELSE employee_devices.ip
    END,
    fingerprint = CASE
      WHEN EXCLUDED.fingerprint IS NOT NULL AND EXCLUDED.fingerprint <> '' THEN EXCLUDED.fingerprint
      ELSE employee_devices.fingerprint
    END,
    pin = COALESCE(NULLIF(EXCLUDED.pin, ''), employee_devices.pin),
    token = COALESCE(EXCLUDED.token, employee_devices.token),
    token_created_at = COALESCE(EXCLUDED.token_created_at, employee_devices.token_created_at),
    token_used_at = COALESCE(EXCLUDED.token_used_at, employee_devices.token_used_at),
    device_info = CASE
      WHEN EXCLUDED.device_info IS NOT NULL AND EXCLUDED.device_info <> '{}'::jsonb THEN EXCLUDED.device_info
      ELSE employee_devices.device_info
    END,
    linked_at = COALESCE(EXCLUDED.linked_at, employee_devices.linked_at),
    last_login = COALESCE(EXCLUDED.last_login, employee_devices.last_login),
    company_id = emp.company_id
  RETURNING id INTO dev_id;

  SELECT to_jsonb(d.*) INTO after_row FROM employee_devices d WHERE d.id = dev_id;

  PERFORM saas_v3_write_audit(
    'employee_device_upsert', 'devices',
    'Device slot ' || p_slot::text || ' for employee ' || p_employee_id::text,
    emp.name,
    emp.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_attendance(
  p_employee_id INTEGER,
  p_date_iso DATE DEFAULT NULL,
  p_attendance_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  att RECORD;
  tenant JSONB;
  before_row JSONB;
BEGIN
  IF p_attendance_id IS NOT NULL THEN
    SELECT * INTO att FROM attendance a WHERE a.id = p_attendance_id LIMIT 1;
  ELSIF p_employee_id IS NOT NULL AND p_date_iso IS NOT NULL THEN
    SELECT * INTO att FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
    LIMIT 1;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attendance_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(att.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(att);
  DELETE FROM attendance WHERE id = att.id;

  PERFORM saas_v3_write_audit(
    'attendance_deleted', 'attendance',
    'Deleted attendance id ' || att.id::text,
    att.emp_name,
    att.company_id,
    before_row,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'attendance_id', att.id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_salary_record(
  p_employee_id INTEGER,
  p_month_iso TEXT DEFAULT NULL,
  p_period_prefix TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  deleted_count INTEGER := 0;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  IF p_month_iso IS NOT NULL AND trim(p_month_iso) <> '' THEN
    DELETE FROM salary_records
    WHERE employee_id = p_employee_id AND month_iso = trim(p_month_iso);
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
  ELSIF p_period_prefix IS NOT NULL AND trim(p_period_prefix) <> '' THEN
    DELETE FROM salary_records
    WHERE employee_id = p_employee_id AND month_iso LIKE trim(p_period_prefix) || '%';
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  PERFORM saas_v3_write_audit(
    'salary_record_deleted', 'payroll',
    'Deleted salary records count ' || deleted_count::text,
    emp.name,
    emp.company_id,
    NULL,
    jsonb_build_object('employee_id', p_employee_id, 'month_iso', p_month_iso, 'period_prefix', p_period_prefix)
  );

  RETURN jsonb_build_object('ok', true, 'deleted', deleted_count);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_tenant_settings(p_settings JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  k TEXT;
  v TEXT;
  db_key TEXT;
  cnt INTEGER := 0;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
  END IF;

  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_settings');
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(p_settings)
  LOOP
    IF k IS NULL OR k = '' THEN CONTINUE; END IF;
    db_key := 'company:' || cid::text || ':' || k;
    INSERT INTO app_settings (key, value, updated_at)
    VALUES (db_key, v, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END LOOP;

  PERFORM saas_v3_write_audit(
    'settings_updated', 'settings',
    'Updated ' || cnt::text || ' tenant settings',
    'company:' || cid::text,
    cid,
    NULL,
    p_settings
  );

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

CREATE OR REPLACE FUNCTION saas_save_platform_globals(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cnt INTEGER := 0;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
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

  IF p_payload ? 'announcements' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:platform_announcements', (p_payload->'announcements')::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

-- Harden employee upsert — tenants cannot override company_id via payload
CREATE OR REPLACE FUNCTION saas_upsert_employee(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  active_chk JSONB;
  lim_chk JSONB;
  emp_id INTEGER;
  before_row JSONB;
  after_row JSONB;
  is_new BOOLEAN := false;
  row employees%ROWTYPE;
BEGIN
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      IF NOT auth_is_super_admin() AND (before_row->>'company_id')::INTEGER <> cid THEN
        RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
      END IF;
      tenant := saas_v3_assert_tenant((before_row->>'company_id')::INTEGER);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
    END IF;
  ELSE
    is_new := true;
  END IF;

  IF is_new THEN
    lim_chk := saas_assert_employee_limit(cid);
    IF COALESCE((lim_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(lim_chk->>'error', 'employee_limit_reached'));
    END IF;
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      emp_id, cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      COALESCE((p_payload->>'salary')::INTEGER, 0),
      COALESCE(p_payload->>'salary_type', p_payload->>'salaryType', 'monthly'),
      COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0),
      COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0),
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    ON CONFLICT (id) DO UPDATE SET
      company_id = cid,
      name = EXCLUDED.name,
      dept = EXCLUDED.dept,
      role = EXCLUDED.role,
      phone = EXCLUDED.phone,
      salary = EXCLUDED.salary,
      salary_type = EXCLUDED.salary_type,
      salary_half = EXCLUDED.salary_half,
      daily_rate = EXCLUDED.daily_rate,
      days = EXCLUDED.days,
      late_min = EXCLUDED.late_min,
      check_in = EXCLUDED.check_in,
      check_out = EXCLUDED.check_out,
      open_hours = EXCLUDED.open_hours,
      remote_attend = EXCLUDED.remote_attend,
      sal_status = EXCLUDED.sal_status,
      sal_bonus = EXCLUDED.sal_bonus,
      sal_deleted_period = EXCLUDED.sal_deleted_period,
      avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      COALESCE((p_payload->>'salary')::INTEGER, 0),
      COALESCE(p_payload->>'salary_type', p_payload->>'salaryType', 'monthly'),
      COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0),
      COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0),
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    RETURNING * INTO row;
  END IF;

  after_row := to_jsonb(row);

  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,
    'employees',
    CASE WHEN is_new THEN 'Created employee' ELSE 'Updated employee' END,
    row.name,
    row.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

-- ----------------------------------------------------------
-- 2) RLS posture audit (run after lockdown)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_audit_rls_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  admin_all_count INTEGER;
  true_qual_count INTEGER;
  policy_counts JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COUNT(*) INTO admin_all_count
  FROM pg_policies
  WHERE schemaname = 'public' AND policyname LIKE 'admin_all_%';

  SELECT COUNT(*) INTO true_qual_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND (
      qual::text ~ '(^|[^a-z_])true([^a-z_]|$)'
      OR with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)'
    );

  SELECT COALESCE(jsonb_object_agg(tablename, cnt), '{}'::jsonb) INTO policy_counts
  FROM (
    SELECT tablename, COUNT(*)::INTEGER AS cnt
    FROM pg_policies
    WHERE schemaname = 'public'
    GROUP BY tablename
  ) s;

  RETURN jsonb_build_object(
    'ok', true,
    'admin_all_count', admin_all_count,
    'using_true_count', true_qual_count,
    'policy_counts', policy_counts,
    'enterprise_ready',
      admin_all_count = 0 AND true_qual_count = 0
  );
END;
$$;

-- ----------------------------------------------------------
-- 3) Drop risky views (admin_* only — keep v_* read views)
-- ----------------------------------------------------------
DO $$
DECLARE
  v RECORD;
BEGIN
  FOR v IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'v'
      AND c.relname LIKE 'admin\_%' ESCAPE '\'
  LOOP
    EXECUTE format('DROP VIEW IF EXISTS public.%I CASCADE', v.relname);
  END LOOP;
END $$;

-- ----------------------------------------------------------
-- 4) FINAL REVOKE — direct writes forbidden for anon + authenticated
-- SECURITY DEFINER RPCs (owner postgres) retain write access
-- ----------------------------------------------------------
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname NOT LIKE 'pg\_%' ESCAPE '\'
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON TABLE public.%I FROM anon', r.tablename);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON TABLE public.%I FROM authenticated', r.tablename);
  END LOOP;
END $$;

-- Ensure SELECT remains for RLS-protected reads
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;

-- ----------------------------------------------------------
-- 5) GRANTs — new RPCs
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_upsert_employee_device(INTEGER, INTEGER, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee_device(INTEGER, INTEGER, JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_attendance(INTEGER, DATE, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_attendance(INTEGER, DATE, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_salary_record(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_salary_record(INTEGER, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_tenant_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_tenant_settings(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_save_platform_globals(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_save_platform_globals(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_audit_rls_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_audit_rls_report() TO authenticated;

COMMENT ON FUNCTION saas_v3_audit_rls_report() IS
  'Post-lockdown RLS validation — admin_all_* must be 0, USING(true) must be 0';
