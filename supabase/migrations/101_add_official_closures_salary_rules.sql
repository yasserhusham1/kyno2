-- 101 — عطل/تعطيل رسمي للشركة
-- official_closures_json تحفظ في app_settings بصيغة:
-- [{ "title":"تعطيل رسمي", "startDate":"2026-07-10", "endDate":"2026-07-12", "days":3, "payType":"paid|unpaid" }]

CREATE OR REPLACE FUNCTION saas_v3_official_closure_days(
  p_company_id INTEGER,
  p_start DATE,
  p_end DATE,
  p_pay_type TEXT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  raw TEXT;
  item JSONB;
  c_start DATE;
  c_end DATE;
  c_pay TEXT;
  d DATE;
  seen TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF p_company_id IS NULL OR p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN
    RETURN 0;
  END IF;

  raw := COALESCE(NULLIF(saas_v3_company_setting(p_company_id, 'official_closures_json'), ''), '[]');

  FOR item IN SELECT * FROM jsonb_array_elements(raw::jsonb) LOOP
    c_start := COALESCE(NULLIF(item->>'startDate', '')::DATE, NULLIF(item->>'start', '')::DATE, NULLIF(item->>'from', '')::DATE);
    c_end := COALESCE(NULLIF(item->>'endDate', '')::DATE, NULLIF(item->>'end', '')::DATE, NULLIF(item->>'to', '')::DATE);
    IF c_start IS NULL THEN
      CONTINUE;
    END IF;
    IF c_end IS NULL THEN
      c_end := c_start + GREATEST(1, COALESCE(NULLIF(item->>'days', '')::INTEGER, 1)) - 1;
    END IF;
    IF c_end < c_start THEN
      d := c_start; c_start := c_end; c_end := d;
    END IF;

    c_pay := CASE WHEN lower(COALESCE(item->>'payType', item->>'type', 'paid')) = 'unpaid' THEN 'unpaid' ELSE 'paid' END;
    IF p_pay_type IS NOT NULL AND c_pay <> lower(p_pay_type) THEN
      CONTINUE;
    END IF;

    d := GREATEST(c_start, p_start);
    WHILE d <= LEAST(c_end, p_end) LOOP
      IF NOT d::TEXT = ANY(seen) THEN
        seen := array_append(seen, d::TEXT);
      END IF;
      d := d + 1;
    END LOOP;
  END LOOP;

  RETURN COALESCE(array_length(seen, 1), 0);
EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_official_closure_covers_date(
  p_company_id INTEGER,
  p_date DATE
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT saas_v3_official_closure_days($1, $2, $2, NULL) > 0;
$$;

CREATE OR REPLACE FUNCTION public.saas_link_device_by_token(
  p_token TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_ip TEXT DEFAULT NULL,
  p_device_info JSONB DEFAULT '{}'::jsonb,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  other_dev RECORD;
  now_ts TIMESTAMPTZ := NOW();
  tok TEXT := NULLIF(trim(p_token), '');
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  v_ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  rate_chk JSONB;
  active_chk JSONB;
  co_id INTEGER;
BEGIN
  IF fp IS NULL OR length(fp) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  rate_chk := saas_check_api_rate_limit('device_link', fp, v_ip, 10, 900);
  IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'rate_limited',
      'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 900)
    );
  END IF;
  PERFORM saas_record_api_attempt('device_link', fp, v_ip);

  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;
  ELSIF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.employee_id = p_employee_id AND ed.slot = p_slot
    LIMIT 1;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  co_id := d.emp_company_id;
  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF saas_v3_official_closure_covers_date(co_id, basma_date_iso_baghdad()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'official_closure_active');
  END IF;

  SELECT ed.employee_id, ed.slot
  INTO other_dev
  FROM employee_devices ed
  WHERE ed.fingerprint = fp
    AND NOT (ed.employee_id = d.employee_id AND ed.slot = d.slot)
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'fingerprint_already_used',
      'employee_id', other_dev.employee_id,
      'slot', other_dev.slot
    );
  END IF;

  IF tok IS NULL AND d.fingerprint IS NOT NULL AND d.fingerprint <> '' AND d.fingerprint <> fp THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_already_linked');
  END IF;

  UPDATE employee_devices
  SET
    fingerprint = fp,
    ip = COALESCE(v_ip, employee_devices.ip),
    device_info = COALESCE(p_device_info, employee_devices.device_info, '{}'::jsonb),
    linked_at = COALESCE(employee_devices.linked_at, now_ts),
    token_used_at = now_ts,
    last_login = now_ts
  WHERE id = d.id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name,
    'fingerprint', fp,
    'ip', COALESCE(v_ip, d.ip, '')
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_compute_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
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
  leave_covered_days INTEGER := 0;
  paid_leave_days INTEGER := 0;
  official_paid_closure_days INTEGER := 0;
  official_unpaid_closure_days INTEGER := 0;
  is_comm BOOLEAN;
  is_biw BOOLEAN;
  base_period_salary INTEGER;
  daily_rate INTEGER;
  base_salary INTEGER := 0;
  ot_hourly INTEGER;
  late_deduct INTEGER := 0;
  absent_deduct INTEGER := 0;
  ot_amount INTEGER := 0;
  bonus INTEGER := 0;
  fin JSONB;
  leave_info JSONB;
  manual_deduct INTEGER := 0;
  loan_deduct INTEGER := 0;
  leave_deduct INTEGER := 0;
  leave_days INTEGER := 0;
  total_deduct INTEGER := 0;
  net_salary INTEGER := 0;
  tenant JSONB;
  month_days_val INTEGER;
  biw_days INTEGER;
  include_ot BOOLEAN := FALSE;
  day_short_min INTEGER := 0;
  official_work_minutes INTEGER := 0;
  late_minute_rate NUMERIC := 0;
  elapsed_work_days INTEGER := 0;
  period_elapsed_end DATE;
  seen_attend_dates TEXT[] := ARRAY[]::TEXT[];
  seen_absent_dates TEXT[] := ARRAY[]::TEXT[];
  day_key TEXT;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  include_ot := COALESCE(emp.include_overtime_in_salary, false);
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

  official_work_minutes := saas_v3_employee_work_minutes(emp.check_in, emp.check_out, emp.company_id);
  IF daily_rate > 0 AND official_work_minutes > 0 THEN
    late_minute_rate := daily_rate::NUMERIC / official_work_minutes;
  END IF;

  period_elapsed_end := LEAST(basma_date_iso_baghdad() - 1, bounds.period_end);
  elapsed_work_days := LEAST(
    bounds.total_days,
    saas_v3_work_days_between(bounds.period_start, period_elapsed_end)
  );

  IF period_elapsed_end >= bounds.period_start THEN
    leave_covered_days := saas_v3_leave_covered_days(
      p_employee_id, emp.company_id, bounds.period_start, period_elapsed_end
    );
    paid_leave_days := saas_v3_paid_leave_days(
      p_employee_id, emp.company_id, bounds.period_start, period_elapsed_end
    );
    official_paid_closure_days := saas_v3_official_closure_days(emp.company_id, bounds.period_start, period_elapsed_end, 'paid');
    official_unpaid_closure_days := saas_v3_official_closure_days(emp.company_id, bounds.period_start, period_elapsed_end, 'unpaid');
    IF NOT is_comm THEN
      leave_covered_days := leave_covered_days + official_paid_closure_days + official_unpaid_closure_days;
      paid_leave_days := paid_leave_days + official_paid_closure_days;
    END IF;
  END IF;

  FOR att IN
    SELECT a.*
    FROM attendance a
    WHERE a.employee_id = p_employee_id
      AND a.date_iso >= bounds.period_start
      AND a.date_iso <= period_elapsed_end
    ORDER BY a.date_iso ASC, a.id ASC
  LOOP
    day_key := COALESCE(att.date_iso::TEXT, '');
    IF day_key = '' THEN
      CONTINUE;
    END IF;

    IF att.check_in IS NOT NULL
       AND att.check_in <> '—'
       AND att.check_out IS NOT NULL
       AND att.check_out <> '—' THEN
      IF NOT day_key = ANY(seen_attend_dates) THEN
        attend_days := attend_days + 1;
        seen_attend_dates := array_append(seen_attend_dates, day_key);
      END IF;

      IF NOT is_comm AND emp.open_hours IS NOT TRUE THEN
        total_ot_min := total_ot_min + saas_v3_parse_ot_minutes(att.overtime);
        day_short_min := saas_v3_attendance_short_minutes(
          emp.company_id,
          emp.check_in,
          emp.check_out,
          att.check_in,
          att.check_out
        );
        total_late_min := total_late_min + day_short_min;
      END IF;
    ELSIF att.status = 'غياب'
      AND NOT saas_v3_leave_covers_date(p_employee_id, emp.company_id, att.date_iso)
      AND NOT saas_v3_official_closure_covers_date(emp.company_id, att.date_iso) THEN
      IF NOT day_key = ANY(seen_absent_dates) THEN
        recorded_absent := recorded_absent + 1;
        seen_absent_dates := array_append(seen_absent_dates, day_key);
      END IF;
    END IF;
  END LOOP;

  IF is_comm THEN
    expected_absent := 0;
  ELSE
    expected_absent := GREATEST(
      0,
      elapsed_work_days - attend_days - recorded_absent - leave_covered_days
    );
  END IF;
  absent_days := recorded_absent + expected_absent;

  IF is_comm THEN
    base_salary := 0;
  ELSE
    base_salary := base_period_salary;
  END IF;

  ot_hourly := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000));

  IF is_comm THEN
    late_deduct := 0;
    absent_deduct := 0;
    ot_amount := 0;
  ELSE
    late_deduct := CASE
      WHEN emp.open_hours IS TRUE OR total_late_min <= 0 OR late_minute_rate <= 0 THEN 0
      ELSE ROUND(total_late_min * late_minute_rate)
    END;
    absent_deduct := ROUND(absent_days * daily_rate);
    ot_amount := CASE WHEN emp.open_hours IS TRUE THEN 0 ELSE ROUND((total_ot_min / 60.0) * ot_hourly) END;
  END IF;

  IF period_elapsed_end >= bounds.period_start THEN
    leave_info := saas_v3_compute_leave_deductions(
      p_employee_id, emp.company_id, bounds.period_start, period_elapsed_end, daily_rate
    );
  ELSE
    leave_info := jsonb_build_object('leave_deduct', 0, 'leave_days', 0, 'leave_items', '[]'::jsonb);
  END IF;
  leave_deduct := COALESCE((leave_info->>'leave_deduct')::INTEGER, 0);
  leave_days := COALESCE((leave_info->>'leave_days')::INTEGER, 0);
  IF NOT is_comm AND official_unpaid_closure_days > 0 THEN
    leave_deduct := leave_deduct + ROUND(official_unpaid_closure_days * daily_rate);
    leave_days := leave_days + official_unpaid_closure_days;
  END IF;

  fin := saas_v3_finance_totals(emp.company_id, p_employee_id, bounds.month_iso);
  manual_deduct := COALESCE((fin->>'deductions')::INTEGER, 0);
  loan_deduct := COALESCE((fin->>'loans')::INTEGER, 0);
  bonus := GREATEST(0, COALESCE(emp.sal_bonus, 0)) + COALESCE((fin->>'bonuses')::INTEGER, 0);
  total_deduct := late_deduct + absent_deduct + leave_deduct + manual_deduct + loan_deduct;

  IF is_comm THEN
    net_salary := bonus + CASE WHEN include_ot THEN ot_amount ELSE 0 END;
  ELSE
    net_salary := GREATEST(0, base_salary + bonus - total_deduct + CASE WHEN include_ot THEN ot_amount ELSE 0 END);
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
    'recorded_absent_days', recorded_absent,
    'expected_absent_days', expected_absent,
    'leave_covered_days', leave_covered_days,
    'paid_leave_days', paid_leave_days,
    'official_paid_closure_days', official_paid_closure_days,
    'official_unpaid_closure_days', official_unpaid_closure_days,
    'late_minutes', total_late_min,
    'attendance_short_minutes', total_late_min,
    'overtime_minutes', total_ot_min,
    'late_deduct', late_deduct,
    'late_minute_rate', ROUND(late_minute_rate, 4),
    'official_work_minutes', official_work_minutes,
    'elapsed_work_days', elapsed_work_days,
    'completed_until', period_elapsed_end,
    'absent_deduct', absent_deduct,
    'leave_deduct', leave_deduct,
    'leave_days', leave_days,
    'leave_items', COALESCE(leave_info->'leave_items', '[]'::jsonb),
    'manual_deduct', manual_deduct,
    'loan_deduct', loan_deduct,
    'loan_items', COALESCE(fin->'loan_items', '[]'::jsonb),
    'overtime_amount', ot_amount,
    'overtime_in_net', include_ot,
    'include_overtime_in_salary', include_ot,
    'bonus', bonus,
    'total_deduct', total_deduct,
    'net_salary', net_salary,
    'daily_rate', daily_rate,
    'period_days', bounds.total_days,
    'elapsed_days', bounds.elapsed_days
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_official_closure_days(INTEGER, DATE, DATE, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_official_closure_days(INTEGER, DATE, DATE, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_official_closure_covers_date(INTEGER, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_official_closure_covers_date(INTEGER, DATE) TO authenticated;

REVOKE ALL ON FUNCTION public.saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_v3_compute_salary(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_compute_salary(INTEGER, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
