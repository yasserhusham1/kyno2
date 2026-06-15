-- ============================================================
-- KYNO 031 — Enterprise Hardening v3 (Core RPC Layer)
-- Additive — لا تغيير RLS 029/030
-- Server-authoritative payroll, attendance admin, employees
-- ============================================================

-- ----------------------------------------------------------
-- 0) Fix audit RPC — no company_id = 1 fallback
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_insert_audit_log(
  p_action TEXT,
  p_category TEXT DEFAULT NULL,
  p_details TEXT DEFAULT NULL,
  p_target_name TEXT DEFAULT NULL,
  p_actor_id INTEGER DEFAULT NULL,
  p_actor_name TEXT DEFAULT NULL,
  p_actor_role TEXT DEFAULT NULL,
  p_meta JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();
  IF (cid IS NULL OR cid <= 0) AND auth_is_super_admin() THEN
    cid := NULLIF((p_meta->>'company_id')::INTEGER, 0);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta
  ) VALUES (
    cid,
    p_actor_id,
    NULLIF(trim(p_actor_name), ''),
    NULLIF(trim(p_actor_role), ''),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    COALESCE(p_meta, '{}'::jsonb)
  );

  RETURN jsonb_build_object('ok', true);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ----------------------------------------------------------
-- 1) Internal helpers
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_assert_tenant(p_row_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
BEGIN
  IF auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', true, 'super_admin', true);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  IF p_row_company_id IS NULL OR p_row_company_id <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
  END IF;
  RETURN jsonb_build_object('ok', true, 'company_id', cid);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_company_setting(p_company_id INTEGER, p_key TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.value
  FROM app_settings s
  WHERE s.key = ('company:' || p_company_id::text || ':' || p_key)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION saas_v3_write_audit(
  p_action TEXT,
  p_category TEXT,
  p_details TEXT,
  p_target_name TEXT,
  p_company_id INTEGER,
  p_before JSONB DEFAULT NULL,
  p_after JSONB DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta JSONB;
BEGIN
  meta := jsonb_build_object(
    'company_id', p_company_id,
    'timestamp', to_jsonb(NOW()),
    'before', COALESCE(p_before, 'null'::jsonb),
    'after', COALESCE(p_after, 'null'::jsonb)
  );
  PERFORM saas_insert_audit_log(
    p_action,
    p_category,
    p_details,
    p_target_name,
    NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER,
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'display_name', auth.jwt() ->> 'email', ''),
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth_app_role()),
    meta
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_parse_late_minutes(p_late TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s TEXT := trim(COALESCE(p_late, ''));
  n INTEGER;
BEGIN
  IF s = '' OR s = '—' THEN RETURN 0; END IF;
  n := NULLIF(regexp_replace(s, '[^0-9]', '', 'g'), '')::INTEGER;
  RETURN COALESCE(n, 0);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_parse_ot_minutes(p_ot TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s TEXT := trim(COALESCE(p_ot, ''));
  h INTEGER := 0;
  m INTEGER := 0;
  hm TEXT[];
BEGIN
  IF s = '' OR s = '—' THEN RETURN 0; END IF;
  IF s ~ '(\d+)\s*س' THEN
    h := (regexp_match(s, '(\d+)\s*س'))[1]::INTEGER;
  END IF;
  IF s ~ '(\d+)\s*د' THEN
    m := (regexp_match(s, '(\d+)\s*د'))[1]::INTEGER;
  END IF;
  IF h = 0 AND m = 0 THEN
    m := NULLIF(regexp_replace(s, '[^0-9]', '', 'g'), '')::INTEGER;
    m := COALESCE(m, 0);
  END IF;
  RETURN h * 60 + m;
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_period_bounds(
  p_month TEXT,
  p_salary_type TEXT DEFAULT 'monthly'
)
RETURNS TABLE(
  period_start DATE,
  period_end DATE,
  elapsed_days INTEGER,
  total_days INTEGER,
  month_iso TEXT,
  month_label TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  y INTEGER;
  mo INTEGER;
  half TEXT;
  today DATE := basma_date_iso_baghdad();
  ms TEXT[] := ARRAY['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
  mkey TEXT := COALESCE(NULLIF(trim(p_month), ''), to_char(today, 'YYYY-MM'));
  stype TEXT := COALESCE(NULLIF(trim(p_salary_type), ''), 'monthly');
BEGIN
  IF mkey ~ '-H[12]$' THEN
    y := split_part(split_part(mkey, '-H', 1), '-', 1)::INTEGER;
    mo := split_part(split_part(mkey, '-H', 1), '-', 2)::INTEGER;
    half := substring(mkey from '-H([12])$');
    IF half = '1' THEN
      period_start := make_date(y, mo, 1);
      period_end := make_date(y, mo, 15);
      total_days := 15;
    ELSE
      period_start := make_date(y, mo, 16);
      period_end := (date_trunc('month', make_date(y, mo, 1)) + INTERVAL '1 month - 1 day')::DATE;
      total_days := EXTRACT(DAY FROM period_end)::INTEGER - 15;
    END IF;
    month_iso := mkey;
    month_label := ms[mo] || ' ' || y::TEXT || ' (' || CASE WHEN half = '1' THEN 'النصف الأول' ELSE 'النصف الثاني' END || ')';
  ELSE
    y := split_part(mkey, '-', 1)::INTEGER;
    mo := split_part(mkey, '-', 2)::INTEGER;
    period_start := make_date(y, mo, 1);
    period_end := (date_trunc('month', period_start) + INTERVAL '1 month - 1 day')::DATE;
    total_days := EXTRACT(DAY FROM period_end)::INTEGER;
    month_iso := to_char(period_start, 'YYYY-MM');
    month_label := ms[mo] || ' ' || y::TEXT;
  END IF;

  IF today < period_start THEN
    elapsed_days := 0;
  ELSIF today > period_end THEN
    elapsed_days := total_days;
  ELSE
    elapsed_days := GREATEST(1, (today - period_start)::INTEGER + 1);
    IF stype = 'biweekly' AND mkey ~ '-H[12]$' THEN
      IF substring(mkey from '-H([12])$') = '1' THEN
        elapsed_days := LEAST(elapsed_days, 15);
      ELSE
        elapsed_days := LEAST(GREATEST(1, EXTRACT(DAY FROM today)::INTEGER - 15), total_days);
      END IF;
    END IF;
  END IF;

  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_finance_totals(
  p_company_id INTEGER,
  p_employee_id INTEGER,
  p_period_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  raw TEXT;
  arr JSONB;
  item JSONB;
  deductions INTEGER := 0;
  bonuses INTEGER := 0;
  loans INTEGER := 0;
  amt INTEGER;
  status TEXT;
  iperiod TEXT;
BEGIN
  raw := saas_v3_company_setting(p_company_id, 'finance_items');
  IF raw IS NULL OR trim(raw) = '' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0);
  END IF;
  BEGIN
    arr := raw::JSONB;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0);
  END;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0);
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(arr)
  LOOP
    IF COALESCE((item->>'empId')::INTEGER, (item->>'emp_id')::INTEGER, 0) <> p_employee_id THEN
      CONTINUE;
    END IF;
    status := COALESCE(item->>'status', '');
    IF status IN ('ملغي', 'مسدد') THEN CONTINUE; END IF;
    iperiod := COALESCE(item->>'period', '');
    amt := GREATEST(0, COALESCE((item->>'amount')::INTEGER, 0));
    IF COALESCE(item->>'type', '') = 'bonus' THEN
      IF iperiod = '' OR iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7) THEN
        bonuses := bonuses + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'deduction' THEN
      IF iperiod = '' OR iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7) THEN
        deductions := deductions + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'loan' THEN
      IF COALESCE(item->>'loanMode', item->>'loan_mode', '') = 'installments' THEN
        loans := loans + GREATEST(0, amt / GREATEST(1, COALESCE((item->>'installmentCount')::INTEGER, (item->>'installment_count')::INTEGER, 1)));
      ELSE
        loans := loans + amt;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('deductions', deductions, 'bonuses', bonuses, 'loans', loans);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_compute_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  bounds RECORD;
  att RECORD;
  attend_days INTEGER := 0;
  recorded_absent INTEGER := 0;
  total_late_min INTEGER := 0;
  total_ot_min INTEGER := 0;
  expected_absent INTEGER := 0;
  absent_days INTEGER := 0;
  is_comm BOOLEAN;
  is_biw BOOLEAN;
  base_period_salary INTEGER;
  daily_rate INTEGER;
  base_salary INTEGER := 0;
  late_deduct_rate INTEGER;
  ot_hourly INTEGER;
  late_deduct INTEGER := 0;
  absent_deduct INTEGER := 0;
  ot_amount INTEGER := 0;
  bonus INTEGER := 0;
  fin JSONB;
  manual_deduct INTEGER := 0;
  loan_deduct INTEGER := 0;
  total_deduct INTEGER := 0;
  net_salary INTEGER := 0;
  tenant JSONB;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT * INTO bounds FROM saas_v3_period_bounds(
    COALESCE(p_month, CASE WHEN emp.salary_type = 'biweekly' THEN
      to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
      CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= 15 THEN '-H1' ELSE '-H2' END
    ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END),
    COALESCE(emp.salary_type, 'monthly')
  );

  is_comm := COALESCE(emp.salary_type, 'monthly') = 'commission';
  is_biw := COALESCE(emp.salary_type, 'monthly') = 'biweekly';
  base_period_salary := CASE
    WHEN is_comm THEN 0
    WHEN is_biw THEN GREATEST(0, COALESCE(NULLIF(emp.salary_half, 0), emp.salary / 2))
    ELSE GREATEST(0, COALESCE(emp.salary, 0))
  END;
  daily_rate := CASE
    WHEN is_comm THEN 0
    WHEN COALESCE(emp.daily_rate, 0) > 0 THEN emp.daily_rate
    WHEN is_biw THEN GREATEST(0, base_period_salary / 15)
    ELSE GREATEST(0, base_period_salary / 30)
  END;

  FOR att IN
    SELECT a.*
    FROM attendance a
    WHERE a.employee_id = p_employee_id
      AND a.date_iso >= bounds.period_start
      AND a.date_iso <= bounds.period_end
  LOOP
    IF att.check_in IS NOT NULL AND att.check_in <> '—' THEN
      attend_days := attend_days + 1;
      IF NOT is_comm AND emp.open_hours IS NOT TRUE THEN
        total_ot_min := total_ot_min + saas_v3_parse_ot_minutes(att.overtime);
        IF att.late IS NOT NULL AND att.late <> '—' THEN
          total_late_min := total_late_min + saas_v3_parse_late_minutes(att.late);
        END IF;
      END IF;
    ELSIF att.status = 'غياب' THEN
      recorded_absent := recorded_absent + 1;
    END IF;
  END LOOP;

  IF is_comm OR emp.open_hours IS TRUE THEN
    expected_absent := 0;
  ELSE
    expected_absent := GREATEST(0, bounds.elapsed_days - attend_days - recorded_absent);
  END IF;
  absent_days := recorded_absent + expected_absent;

  IF is_comm THEN
    base_salary := 0;
  ELSE
    base_salary := base_period_salary;
  END IF;

  late_deduct_rate := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'late_deduct_rate'), '')::INTEGER, 700));
  ot_hourly := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000));

  IF is_comm OR emp.open_hours IS TRUE THEN
    late_deduct := 0;
    absent_deduct := 0;
    ot_amount := 0;
  ELSE
    late_deduct := ROUND(total_late_min * late_deduct_rate);
    absent_deduct := ROUND(absent_days * daily_rate);
    ot_amount := ROUND((total_ot_min / 60.0) * ot_hourly);
  END IF;

  fin := saas_v3_finance_totals(emp.company_id, p_employee_id, bounds.month_iso);
  manual_deduct := COALESCE((fin->>'deductions')::INTEGER, 0);
  loan_deduct := COALESCE((fin->>'loans')::INTEGER, 0);
  bonus := GREATEST(0, COALESCE(emp.sal_bonus, 0)) + COALESCE((fin->>'bonuses')::INTEGER, 0);
  total_deduct := late_deduct + absent_deduct + manual_deduct + loan_deduct;

  IF is_comm THEN
    net_salary := bonus;
  ELSE
    net_salary := GREATEST(0, base_salary + ot_amount + bonus - total_deduct);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'month_iso', bounds.month_iso,
    'month_label', bounds.month_label,
    'base_salary', base_salary,
    'attend_days', attend_days,
    'absent_days', absent_days,
    'late_minutes', total_late_min,
    'overtime_minutes', total_ot_min,
    'late_deduct', late_deduct,
    'absent_deduct', absent_deduct,
    'manual_deduct', manual_deduct,
    'loan_deduct', loan_deduct,
    'overtime_amount', ot_amount,
    'bonus', bonus,
    'total_deduct', total_deduct,
    'net_salary', net_salary,
    'daily_rate', daily_rate,
    'period_days', bounds.total_days,
    'elapsed_days', bounds.elapsed_days
  );
END;
$$;

-- ----------------------------------------------------------
-- 2) Payroll RPCs
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_preview_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN saas_v3_compute_salary(p_employee_id, p_month);
END;
$$;

CREATE OR REPLACE FUNCTION saas_issue_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  calc JSONB;
  rec salary_records%ROWTYPE;
  att_id INTEGER;
BEGIN
  calc := saas_v3_compute_salary(p_employee_id, p_month);
  IF COALESCE((calc->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN calc;
  END IF;

  INSERT INTO salary_records (
    employee_id, company_id, month_iso, month_label,
    base_salary, attend_days, late_minutes, late_deduct,
    absent_days, overtime_amount, bonus, total_deduct, net_salary,
    status, issued_at
  ) VALUES (
    p_employee_id,
    (calc->>'company_id')::INTEGER,
    calc->>'month_iso',
    calc->>'month_label',
    (calc->>'base_salary')::INTEGER,
    (calc->>'attend_days')::INTEGER,
    (calc->>'late_minutes')::INTEGER,
    (calc->>'late_deduct')::INTEGER,
    (calc->>'absent_days')::INTEGER,
    (calc->>'overtime_amount')::INTEGER,
    (calc->>'bonus')::INTEGER,
    (calc->>'total_deduct')::INTEGER,
    (calc->>'net_salary')::INTEGER,
    'مُصدر',
    NOW()
  )
  ON CONFLICT (employee_id, month_iso) DO UPDATE SET
    month_label = EXCLUDED.month_label,
    base_salary = EXCLUDED.base_salary,
    attend_days = EXCLUDED.attend_days,
    late_minutes = EXCLUDED.late_minutes,
    late_deduct = EXCLUDED.late_deduct,
    absent_days = EXCLUDED.absent_days,
    overtime_amount = EXCLUDED.overtime_amount,
    bonus = EXCLUDED.bonus,
    total_deduct = EXCLUDED.total_deduct,
    net_salary = EXCLUDED.net_salary,
    status = 'مُصدر',
    issued_at = NOW()
  RETURNING * INTO rec;

  UPDATE employees SET
    days = (calc->>'attend_days')::INTEGER,
    late_min = (calc->>'late_minutes')::INTEGER,
    sal_status = 'مُصدر'
  WHERE id = p_employee_id;

  PERFORM saas_v3_write_audit(
    'salary_issued', 'payroll',
    'Issued salary for employee ' || p_employee_id::TEXT || ' period ' || (calc->>'month_iso'),
    (SELECT name FROM employees WHERE id = p_employee_id LIMIT 1),
    (calc->>'company_id')::INTEGER,
    NULL,
    to_jsonb(rec)
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(rec), 'calc', calc);
END;
$$;

CREATE OR REPLACE FUNCTION saas_recalculate_salary(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  month_key TEXT;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  month_key := CASE WHEN COALESCE(emp.salary_type, 'monthly') = 'biweekly' THEN
    to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
    CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= 15 THEN '-H1' ELSE '-H2' END
  ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END;

  IF EXISTS (
    SELECT 1 FROM salary_records sr
    WHERE sr.employee_id = p_employee_id AND sr.month_iso = month_key AND sr.status = 'مُصدر'
  ) THEN
    RETURN saas_issue_salary(p_employee_id, month_key);
  END IF;

  RETURN saas_preview_salary(p_employee_id, month_key);
END;
$$;

-- ----------------------------------------------------------
-- 3) Attendance RPCs
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_attendance_employee(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_punch_type TEXT,
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  punch TEXT := lower(trim(COALESCE(p_punch_type, '')));
BEGIN
  IF punch NOT IN ('check_in', 'check_out') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'punch_type_required');
  END IF;
  RETURN saas_upsert_attendance_by_device(
    p_employee_id,
    p_fingerprint,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    p_emp_name,
    p_dept,
    NULL, NULL,
    punch
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_attendance_admin(
  p_employee_id INTEGER,
  p_date_iso DATE,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  active_chk JSONB;
  before_row JSONB;
  after_row JSONB;
  att_id INTEGER;
  use_ci TEXT;
  use_co TEXT;
  use_late TEXT := '—';
  use_ot TEXT := '—';
  use_hours TEXT := '—';
  use_status TEXT := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  ci_min INTEGER;
  co_min INTEGER;
  official_ci INTEGER;
  official_co INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ot_min INTEGER;
  ot_hourly INTEGER;
  dlabel TEXT;
  existing RECORD;
BEGIN
  IF p_employee_id IS NULL OR p_date_iso IS NULL THEN
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

  active_chk := saas_assert_company_active(emp.company_id);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  SELECT to_jsonb(a.*) INTO before_row
  FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;

  SELECT a.check_in, a.check_out, a.status, a.late INTO existing
  FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;

  use_ci := COALESCE(NULLIF(trim(p_check_in), ''), existing.check_in, '—');
  use_co := COALESCE(NULLIF(trim(p_check_out), ''), existing.check_out, '—');

  IF emp.open_hours IS TRUE THEN
    use_late := '—';
    use_ot := '—';
    use_hours := '—';
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  ELSIF use_ci <> '—' AND use_co <> '—' THEN
    ci_min := basma_time_text_to_minutes(use_ci);
    co_min := basma_time_text_to_minutes(use_co);
    official_ci := basma_db_time_to_minutes(emp.check_in);
    official_co := basma_db_time_to_minutes(emp.check_out);
    late_min := GREATEST(0, ci_min - official_ci);
    IF late_min > late_threshold THEN
      use_status := 'متأخر';
      use_late := late_min || 'د';
    ELSIF late_min > 0 THEN
      use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
      use_late := late_min || 'د';
    END IF;
    IF co_min >= ci_min THEN
      use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ot_min := GREATEST(0, co_min - official_co);
      IF ot_min > 0 THEN
        ot_hourly := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000));
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN use_status := 'إضافي'; END IF;
      END IF;
    END IF;
  END IF;

  dlabel := basma_arabic_date_label(p_date_iso);

  INSERT INTO attendance (
    employee_id, company_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status
  ) VALUES (
    p_employee_id, emp.company_id, emp.name, emp.dept, dlabel, p_date_iso,
    use_ci, use_co, use_hours, use_late, use_ot, use_status
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = EXCLUDED.check_in,
    check_out = EXCLUDED.check_out,
    hours = EXCLUDED.hours,
    late = EXCLUDED.late,
    overtime = EXCLUDED.overtime,
    status = EXCLUDED.status
  RETURNING id INTO att_id;

  SELECT to_jsonb(a.*) INTO after_row FROM attendance a WHERE a.id = att_id;

  PERFORM saas_v3_write_audit(
    'attendance_override', 'attendance',
    COALESCE(NULLIF(trim(p_reason), ''), 'Admin attendance upsert'),
    emp.name,
    emp.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'attendance_id', att_id, 'data', after_row, 'server_authoritative', true);
END;
$$;

CREATE OR REPLACE FUNCTION saas_recalculate_attendance_day(
  p_employee_id INTEGER,
  p_date_iso DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  att RECORD;
BEGIN
  SELECT * INTO att FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attendance_not_found');
  END IF;

  RETURN saas_upsert_attendance_admin(
    p_employee_id,
    p_date_iso,
    att.check_in,
    att.check_out,
    att.status,
    'recalculate_day'
  );
END;
$$;

-- ----------------------------------------------------------
-- 4) Employee RPCs
-- ----------------------------------------------------------
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
      emp_id,
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
    ON CONFLICT (id) DO UPDATE SET
      company_id = EXCLUDED.company_id,
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

CREATE OR REPLACE FUNCTION saas_update_employee_role(
  p_employee_id INTEGER,
  p_role TEXT
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
  new_role TEXT := NULLIF(trim(p_role), '');
BEGIN
  IF new_role IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(emp);
  UPDATE employees SET role = new_role, updated_at = NOW()
  WHERE id = p_employee_id
  RETURNING * INTO emp;

  after_row := to_jsonb(emp);

  PERFORM saas_v3_write_audit(
    'employee_role_changed', 'employees',
    'Role changed to ' || new_role,
    emp.name,
    emp.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row);
END;
$$;

-- ----------------------------------------------------------
-- 5) GRANTs
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_preview_salary(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_preview_salary(INTEGER, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_issue_salary(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_issue_salary(INTEGER, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_recalculate_salary(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_recalculate_salary(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_attendance_employee(INTEGER, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_employee(INTEGER, TEXT, TEXT, TEXT, TEXT) TO authenticated, anon;

REVOKE ALL ON FUNCTION saas_upsert_attendance_admin(INTEGER, DATE, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_admin(INTEGER, DATE, TEXT, TEXT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_recalculate_attendance_day(INTEGER, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_recalculate_attendance_day(INTEGER, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_employee(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_employee(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_employee(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_update_employee_role(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_update_employee_role(INTEGER, TEXT) TO authenticated;
