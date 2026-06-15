-- ============================================================
-- KYNO 055 — إعداد «أيام الشهر المعتمدة» (month_days)
-- يُستخدم في المعدل اليومي، الغياب، فترات الراتب، ونصف الشهر
-- ============================================================

CREATE OR REPLACE FUNCTION saas_v3_standard_month_days(p_company_id INTEGER)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
  SELECT LEAST(31, GREATEST(20, COALESCE(
    NULLIF(saas_v3_company_setting(p_company_id, 'month_days'), '')::INTEGER,
    30
  )));
$$;

CREATE OR REPLACE FUNCTION saas_v3_biweekly_split_days(p_company_id INTEGER)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(1, saas_v3_standard_month_days(p_company_id) / 2);
$$;

CREATE OR REPLACE FUNCTION saas_v3_period_bounds(
  p_month TEXT,
  p_salary_type TEXT DEFAULT 'monthly',
  p_company_id INTEGER DEFAULT NULL
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
  month_days_val INTEGER := saas_v3_standard_month_days(p_company_id);
  biw_split INTEGER := saas_v3_biweekly_split_days(p_company_id);
  cal_end DATE;
  cal_end_day INTEGER;
BEGIN
  IF mkey ~ '-H[12]$' THEN
    y := split_part(split_part(mkey, '-H', 1), '-', 1)::INTEGER;
    mo := split_part(split_part(mkey, '-H', 1), '-', 2)::INTEGER;
    half := substring(mkey from '-H([12])$');
    cal_end := (date_trunc('month', make_date(y, mo, 1)) + INTERVAL '1 month - 1 day')::DATE;
    cal_end_day := EXTRACT(DAY FROM cal_end)::INTEGER;
    IF half = '1' THEN
      period_start := make_date(y, mo, 1);
      period_end := make_date(y, mo, LEAST(biw_split, cal_end_day));
      total_days := biw_split;
    ELSE
      period_start := make_date(y, mo, LEAST(biw_split + 1, cal_end_day));
      period_end := cal_end;
      total_days := GREATEST(1, month_days_val - biw_split);
    END IF;
    month_iso := mkey;
    month_label := ms[mo] || ' ' || y::TEXT || ' (' || CASE WHEN half = '1' THEN 'النصف الأول' ELSE 'النصف الثاني' END || ')';
  ELSE
    y := split_part(mkey, '-', 1)::INTEGER;
    mo := split_part(mkey, '-', 2)::INTEGER;
    period_start := make_date(y, mo, 1);
    period_end := (date_trunc('month', period_start) + INTERVAL '1 month - 1 day')::DATE;
    total_days := month_days_val;
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
        elapsed_days := LEAST(elapsed_days, biw_split);
      ELSE
        elapsed_days := LEAST(GREATEST(1, EXTRACT(DAY FROM today)::INTEGER - biw_split), total_days);
      END IF;
    ELSIF stype = 'monthly' THEN
      elapsed_days := LEAST(elapsed_days, month_days_val);
    END IF;
  END IF;

  RETURN NEXT;
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
  month_days_val INTEGER;
  biw_days INTEGER;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  month_days_val := saas_v3_standard_month_days(emp.company_id);
  biw_days := saas_v3_biweekly_split_days(emp.company_id);

  SELECT * INTO bounds FROM saas_v3_period_bounds(
    COALESCE(p_month, CASE WHEN emp.salary_type = 'biweekly' THEN
      to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
      CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= biw_days THEN '-H1' ELSE '-H2' END
    ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END),
    COALESCE(emp.salary_type, 'monthly'),
    emp.company_id
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
    WHEN is_biw THEN GREATEST(0, base_period_salary / biw_days)
    ELSE GREATEST(0, base_period_salary / month_days_val)
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
    net_salary := GREATEST(0, base_salary + bonus - total_deduct);
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
  st TEXT;
  sal INTEGER;
  sal_half INTEGER;
  dr INTEGER;
  payload_half INTEGER;
  month_days_val INTEGER;
  biw_days INTEGER;
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

  month_days_val := saas_v3_standard_month_days(cid);
  biw_days := saas_v3_biweekly_split_days(cid);

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

  st := COALESCE(NULLIF(trim(p_payload->>'salary_type'), ''), NULLIF(trim(p_payload->>'salaryType'), ''), 'monthly');
  sal := GREATEST(0, COALESCE((p_payload->>'salary')::INTEGER, 0));
  payload_half := GREATEST(0, COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0));

  IF st = 'biweekly' THEN
    sal_half := payload_half;
    IF sal_half = 0 AND sal > 0 THEN
      sal_half := sal / 2;
    END IF;
    IF sal = 0 AND sal_half > 0 THEN
      sal := sal_half * 2;
    END IF;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal_half > 0 THEN
      dr := GREATEST(0, sal_half / biw_days);
    END IF;
  ELSIF st = 'commission' THEN
    sal := 0;
    sal_half := 0;
    dr := 0;
  ELSE
    st := 'monthly';
    sal_half := 0;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal > 0 THEN
      dr := GREATEST(0, sal / month_days_val);
    END IF;
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
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, (p_payload->>'days')::INTEGER, 0),
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
      sal, st, sal_half, dr,
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

    emp_id := row.id;

  END IF;



  after_row := to_jsonb(row);

  PERFORM saas_v3_write_audit(

    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,

    'employees',

    CASE WHEN is_new THEN 'Created employee ' || emp_id::TEXT ELSE 'Updated employee ' || emp_id::TEXT END,

    row.name,

    cid,

    before_row,

    after_row

  );



  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);

END;

$$;


