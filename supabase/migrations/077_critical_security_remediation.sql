-- ============================================================
-- KYNO 077 — Critical + High security remediation
-- C1 notifications | H1 subscription_plans RLS | H2 read-only subscription RPC
-- H3 employee portal device auth (no remote_attend IDOR) | anon SELECT lockdown
-- ============================================================

-- ---------- Shared employee portal authorization (H3) ----------
CREATE OR REPLACE FUNCTION saas_v3_employee_portal_authorize(
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
  sub_chk JSONB;
  cid INTEGER;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  cid := auth_company_id();
  IF cid IS NOT NULL AND cid > 0 THEN
    IF emp.company_id IS DISTINCT FROM cid THEN
      RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
    END IF;
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 8 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 16 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'company_id', emp.company_id,
    'remote_attend', emp.remote_attend IS TRUE
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_employee_portal_authorize(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_employee_portal_authorize(INTEGER, TEXT, TEXT) TO anon, authenticated, service_role;

-- ---------- C1: Admin notification mark read (authenticated tenant only) ----------
CREATE OR REPLACE FUNCTION saas_mark_emp_notification_read(
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  updated_count INTEGER := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    IF auth_is_super_admin() THEN
      IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
        UPDATE employee_notifications SET is_read = TRUE
        WHERE id = p_notif_id;
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
      END IF;
      IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
        UPDATE employee_notifications SET is_read = TRUE
        WHERE notif_ref = btrim(p_notif_ref);
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id AND company_id = cid;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref) AND company_id = cid;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) TO authenticated, service_role;

-- ---------- C1: Employee portal mark read (device proof required) ----------
CREATE OR REPLACE FUNCTION saas_mark_employee_portal_notification_read(
  p_employee_id INTEGER,
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  cid INTEGER;
  updated_count INTEGER := 0;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  cid := (auth_result->>'company_id')::INTEGER;

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id
      AND company_id = cid
      AND employee_id = p_employee_id;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref)
      AND company_id = cid
      AND employee_id = p_employee_id;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;

-- ---------- H1: subscription_plans RLS (global catalog — no company_id column) ----------
ALTER TABLE subscription_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscription_plans_deny_anon ON subscription_plans;
CREATE POLICY subscription_plans_deny_anon ON subscription_plans
  FOR ALL TO anon
  USING (false)
  WITH CHECK (false);

DROP POLICY IF EXISTS subscription_plans_authenticated_read ON subscription_plans;
CREATE POLICY subscription_plans_authenticated_read ON subscription_plans
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS subscription_plans_super_admin ON subscription_plans;
CREATE POLICY subscription_plans_super_admin ON subscription_plans
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

REVOKE ALL ON TABLE subscription_plans FROM anon;
GRANT SELECT ON TABLE subscription_plans TO authenticated;

-- ---------- H2: subscription status read-only (no anon mutation) ----------
CREATE OR REPLACE FUNCTION saas_get_company_subscription_status(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
  days_left INTEGER;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('valid', true, 'status', 'active', 'message', '', 'daysLeft', 0);
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'status', 'pending', 'message', 'الشركة غير موجودة', 'daysLeft', 0);
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'suspended',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'daysLeft', 0
    );
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s
  WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'pending',
      'message', 'لا يوجد اشتراك نشط',
      'daysLeft', 0
    );
  END IF;

  days_left := (sub.end_date - CURRENT_DATE);

  IF sub.status = 'suspended' THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'suspended',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', 0
    );
  END IF;

  IF sub.status = 'pending' OR sub.end_date < CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'expired',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  IF sub.status = 'expired' AND sub.end_date >= CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'expired',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'status', 'active',
    'end_date', sub.end_date,
    'daysLeft', GREATEST(days_left, 0),
    'warning', days_left <= 10,
    'message', CASE
      WHEN days_left <= 10 THEN 'ينتهي الاشتراك خلال ' || GREATEST(days_left, 0)::text || ' يوم'
      ELSE ''
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_company_subscription_status(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_company_subscription_status(INTEGER) TO anon, authenticated, service_role;

-- ---------- H3: attendance punch — device required (no remote_attend bypass) ----------
CREATE OR REPLACE FUNCTION saas_upsert_attendance_by_device(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_date_iso TEXT,
  p_date_label TEXT DEFAULT NULL,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_hours TEXT DEFAULT NULL,
  p_late TEXT DEFAULT NULL,
  p_overtime TEXT DEFAULT NULL,
  p_status TEXT DEFAULT 'طبيعي',
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL,
  p_days INTEGER DEFAULT NULL,
  p_late_min INTEGER DEFAULT NULL,
  p_punch_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  dev_ok BOOLEAN := FALSE;
  att_id INTEGER;
  co_id INTEGER;
  active_chk JSONB;
  rate_chk JSONB;
  punch TEXT := lower(NULLIF(trim(p_punch_type), ''));
  srv_ts TIMESTAMPTZ;
  srv_date DATE;
  srv_ci TEXT;
  use_ci TEXT;
  use_co TEXT;
  use_date_iso DATE;
  use_date_label TEXT;
  use_late TEXT;
  use_ot TEXT;
  use_status TEXT;
  use_hours TEXT;
  actual_min INTEGER;
  official_min INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ci_min INTEGER;
  co_min INTEGER;
  official_co_min INTEGER;
  ot_min INTEGER;
  existing RECORD;
  att_row attendance%ROWTYPE;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF punch IN ('check_in', 'check_out') THEN
    rate_chk := saas_check_api_rate_limit(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'nodevice'),
      NULL,
      120,
      3600
    );
    IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'rate_limited',
        'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 3600)
      );
    END IF;
    PERFORM saas_record_api_attempt(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'nodevice'),
      NULL
    );
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  co_id := emp.company_id;

  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF fp IS NOT NULL AND length(fp) >= 8 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO dev_ok;
  END IF;

  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF p_days IS NOT NULL OR p_late_min IS NOT NULL THEN
    UPDATE employees SET
      days = COALESCE(p_days, days),
      late_min = COALESCE(p_late_min, late_min),
      updated_at = NOW()
    WHERE id = p_employee_id;
  END IF;

  srv_ts := basma_server_now_baghdad();
  srv_date := basma_date_iso_baghdad();
  srv_ci := basma_format_time_ampm(srv_ts);

  IF punch = 'check_in' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_ci := srv_ci;
    use_co := NULL;
    use_hours := NULL;
    use_ot := '—';

    IF emp.open_hours IS TRUE THEN
      use_late := '—';
      use_status := 'طبيعي';
    ELSE
      actual_min := basma_time_text_to_minutes(srv_ci);
      official_min := basma_db_time_to_minutes(emp.check_in);
      late_min := GREATEST(0, actual_min - official_min);
      IF late_min > late_threshold THEN
        use_status := 'متأخر';
        use_late := late_min || 'د';
      ELSIF late_min > 0 THEN
        use_status := 'طبيعي';
        use_late := late_min || 'د';
      ELSE
        use_status := 'طبيعي';
        use_late := '—';
      END IF;
    END IF;

  ELSIF punch = 'check_out' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_co := basma_format_time_ampm(srv_ts);

    SELECT a.check_in, a.late, a.status INTO existing
    FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = srv_date
    LIMIT 1;

    IF existing.check_in IS NOT NULL AND existing.check_in <> '—' THEN
      use_ci := existing.check_in;
      use_late := COALESCE(NULLIF(trim(existing.late), ''), '—');
      use_status := COALESCE(NULLIF(trim(existing.status), ''), 'طبيعي');
    ELSE
      use_ci := srv_ci;
      use_late := '—';
      use_status := 'طبيعي';
    END IF;

    IF emp.open_hours IS TRUE THEN
      use_hours := '—';
      use_late := '—';
      use_ot := '—';
      use_status := 'طبيعي';
    ELSE
      ci_min := basma_time_text_to_minutes(use_ci);
      co_min := basma_time_text_to_minutes(use_co);
      official_co_min := basma_db_time_to_minutes(emp.check_out);
      IF co_min >= ci_min THEN
        use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ELSE
        use_hours := '0س 0د';
      END IF;
      ot_min := GREATEST(0, co_min - official_co_min);
      IF ot_min > 0 THEN
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN
          use_status := 'إضافي';
        END IF;
      ELSE
        use_ot := '—';
      END IF;
    END IF;

  ELSE
    IF p_date_iso IS NULL OR length(trim(p_date_iso)) < 8 THEN
      IF NULLIF(trim(p_check_in), '') IS NULL
         AND NULLIF(trim(p_check_out), '') IS NULL
         AND NULLIF(trim(p_hours), '') IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    use_date_iso := p_date_iso::date;
    use_date_label := COALESCE(NULLIF(trim(p_date_label), ''), p_date_iso);
    use_ci := NULLIF(trim(p_check_in), '');
    use_co := NULLIF(trim(p_check_out), '');
    use_hours := NULLIF(trim(p_hours), '');
    use_late := NULLIF(trim(p_late), '');
    use_ot := NULLIF(trim(p_overtime), '');
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  END IF;

  IF punch IS NULL
     AND NULLIF(trim(p_check_in), '') IS NULL
     AND NULLIF(trim(p_check_out), '') IS NULL
     AND NULLIF(trim(p_hours), '') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
  END IF;

  INSERT INTO attendance (
    employee_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status, company_id
  ) VALUES (
    p_employee_id,
    COALESCE(NULLIF(trim(p_emp_name), ''), emp.name),
    COALESCE(NULLIF(trim(p_dept), ''), emp.dept),
    use_date_label,
    use_date_iso,
    use_ci,
    use_co,
    use_hours,
    use_late,
    use_ot,
    use_status,
    co_id
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = COALESCE(EXCLUDED.check_in, attendance.check_in),
    check_out = COALESCE(EXCLUDED.check_out, attendance.check_out),
    hours = COALESCE(EXCLUDED.hours, attendance.hours),
    late = COALESCE(EXCLUDED.late, attendance.late),
    overtime = COALESCE(EXCLUDED.overtime, attendance.overtime),
    status = COALESCE(EXCLUDED.status, attendance.status),
    company_id = EXCLUDED.company_id,
    updated_at = NOW()
  RETURNING * INTO att_row;

  att_id := att_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'attendance_id', att_id,
    'employee_id', p_employee_id,
    'check_in', COALESCE(att_row.check_in, '—'),
    'check_out', COALESCE(att_row.check_out, '—'),
    'date_iso', att_row.date_iso,
    'date_label', att_row.date_label,
    'hours', COALESCE(att_row.hours, '—'),
    'late', COALESCE(att_row.late, '—'),
    'overtime', COALESCE(att_row.overtime, '—'),
    'status', COALESCE(att_row.status, 'طبيعي'),
    'server_authoritative', punch IN ('check_in', 'check_out')
  );
END;
$$;

-- ---------- H3: Re-wrap employee fetch RPCs (072 bodies + shared authorize) ----------
-- saas_fetch_employee_attendance
CREATE OR REPLACE FUNCTION saas_fetch_employee_attendance(
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
  auth_result JSONB;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id, 'employee_id', a.employee_id, 'emp_name', a.emp_name,
        'dept', a.dept, 'date_label', a.date_label, 'date_iso', a.date_iso,
        'check_in', a.check_in, 'check_out', a.check_out, 'hours', a.hours,
        'late', a.late, 'overtime', a.overtime, 'status', a.status, 'company_id', a.company_id
      ) ORDER BY a.date_iso DESC
    ), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM attendance att
    WHERE att.employee_id = p_employee_id
    ORDER BY att.date_iso DESC LIMIT lim
  ) a;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

-- saas_fetch_employee_client_profile (072 fields)
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
  auth_result JSONB;
  emp RECORD;
  gps_prefix TEXT;
  v_lat TEXT;
  v_lng TEXT;
  v_range TEXT;
  v_name TEXT;
  v_finance TEXT;
  finance_arr JSONB := '[]'::jsonb;
  emp_finance JSONB := '[]'::jsonb;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

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

-- saas_fetch_employee_leaves
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
  auth_result JSONB;
  emp RECORD;
  lim INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 120), 300));
  rows JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

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

-- saas_fetch_employee_notifications (072 merge + authorize)
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
  auth_result JSONB;
  emp RECORD;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  table_rows JSONB := '[]'::jsonb;
  settings_rows JSONB := '[]'::jsonb;
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

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

-- saas_fetch_employee_salary_records
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
  auth_result JSONB;
  emp RECORD;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

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

-- saas_update_employee_avatar — device proof required for anon path
CREATE OR REPLACE FUNCTION saas_update_employee_avatar(
  p_employee_id INTEGER,
  p_avatar_url TEXT,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  emp RECORD;
  url TEXT := NULLIF(trim(p_avatar_url), '');
  tenant JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;
  IF url IS NULL OR length(url) < 24 OR length(url) > 700000 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_avatar');
  END IF;
  IF url NOT LIKE 'data:image/%' AND url NOT LIKE 'http%' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_avatar_format');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF auth_company_id() IS NOT NULL OR auth_is_super_admin() THEN
    tenant := saas_v3_assert_tenant(emp.company_id);
    IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN tenant;
    END IF;
    UPDATE employees SET avatar_url = url WHERE id = p_employee_id;
    RETURN jsonb_build_object('ok', true);
  END IF;

  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  UPDATE employees SET avatar_url = url WHERE id = p_employee_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------- Medium: revoke blanket anon SELECT ----------
REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM anon;

-- Re-grant public platform read tables if any (none should need anon table SELECT — RPC only)

COMMENT ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) IS
  'Tenant-authenticated mark read only. anon revoked (077).';
COMMENT ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) IS
  'Employee phone portal mark read — requires device fingerprint/token (077).';
COMMENT ON FUNCTION saas_get_company_subscription_status(INTEGER) IS
  'Read-only subscription probe. No anon grant; no side-effect UPDATE (077).';
