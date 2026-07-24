-- 089 — تثبيت تعديل بصمة الجهاز + فتح قيد المحاولات + أيام الدوام المفتوح

CREATE OR REPLACE FUNCTION saas_admin_manage_employee_device(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_fingerprint TEXT DEFAULT NULL,
  p_clear_link BOOLEAN DEFAULT FALSE
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
  fp TEXT := NULLIF(trim(p_fingerprint), '');
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 OR p_slot IS NULL OR p_slot NOT IN (1, 2) THEN
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

  IF before_row IS NULL THEN
    INSERT INTO employee_devices (
      employee_id, company_id, slot, label, ip, fingerprint, pin, device_info
    ) VALUES (
      p_employee_id,
      emp.company_id,
      p_slot,
      'الهاتف ' || p_slot::text,
      '',
      CASE WHEN COALESCE(p_clear_link, false) THEN '' ELSE COALESCE(fp, '') END,
      '',
      '{}'::jsonb
    )
    RETURNING id INTO dev_id;

    SELECT to_jsonb(d.*) INTO after_row FROM employee_devices d WHERE d.id = dev_id;
    RETURN jsonb_build_object('ok', true, 'data', after_row, 'created', true);
  END IF;

  IF COALESCE(p_clear_link, false) THEN
    UPDATE employee_devices SET
      fingerprint = '',
      ip = '',
      linked_at = NULL,
      token_used_at = NULL,
      last_login = NULL,
      device_info = '{}'::jsonb
    WHERE employee_id = p_employee_id AND slot = p_slot
    RETURNING id INTO dev_id;
  ELSIF fp IS NOT NULL THEN
    UPDATE employee_devices SET
      fingerprint = fp,
      ip = '',
      linked_at = NULL,
      token_used_at = NULL,
      last_login = NULL,
      device_info = '{}'::jsonb
    WHERE employee_id = p_employee_id AND slot = p_slot
    RETURNING id INTO dev_id;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'nothing_to_update');
  END IF;

  SELECT to_jsonb(d.*) INTO after_row FROM employee_devices d WHERE d.id = dev_id;

  BEGIN
    PERFORM saas_v3_write_audit(
      CASE WHEN COALESCE(p_clear_link, false) THEN 'employee_device_cleared' ELSE 'employee_device_updated' END,
      'devices',
      CASE WHEN COALESCE(p_clear_link, false)
        THEN 'Cleared device slot ' || p_slot::text || ' for employee ' || p_employee_id::text
        ELSE 'Updated fingerprint slot ' || p_slot::text || ' for employee ' || p_employee_id::text
      END,
      emp.name,
      emp.company_id,
      before_row,
      after_row,
      'employee_devices', dev_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'data', after_row);
END;
$$;

REVOKE ALL ON FUNCTION saas_admin_manage_employee_device(INTEGER, SMALLINT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_admin_manage_employee_device(INTEGER, SMALLINT, TEXT, BOOLEAN) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION saas_admin_reset_employee_device_rate_limit(
  p_employee_id INTEGER,
  p_slot INTEGER DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  fps TEXT[] := ARRAY[]::TEXT[];
  punch_keys TEXT[] := ARRAY[]::TEXT[];
  deleted_count INTEGER := 0;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
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

  IF fp IS NOT NULL THEN
    fps := array_append(fps, fp);
  END IF;

  SELECT COALESCE(array_agg(DISTINCT fingerprint), ARRAY[]::TEXT[]) INTO fps
  FROM (
    SELECT unnest(fps) AS fingerprint
    UNION ALL
    SELECT NULLIF(trim(ed.fingerprint), '')
    FROM employee_devices ed
    WHERE ed.employee_id = p_employee_id
      AND (p_slot IS NULL OR ed.slot = p_slot)
  ) x
  WHERE fingerprint IS NOT NULL AND fingerprint <> '';

  punch_keys := ARRAY[
    p_employee_id::TEXT || ':nodevice',
    p_employee_id::TEXT || ':remote'
  ];

  IF array_length(fps, 1) IS NOT NULL THEN
    SELECT punch_keys || COALESCE(array_agg(p_employee_id::TEXT || ':' || f), ARRAY[]::TEXT[])
    INTO punch_keys
    FROM unnest(fps) AS f;
  END IF;

  DELETE FROM api_rate_attempts
  WHERE (scope = 'device_link' AND array_length(fps, 1) IS NOT NULL AND rate_key = ANY(fps))
     OR (scope = 'attendance_punch' AND rate_key = ANY(punch_keys));

  GET DIAGNOSTICS deleted_count = ROW_COUNT;

  BEGIN
    PERFORM saas_v3_write_audit(
      'employee_device_rate_limit_reset',
      'devices',
      'Reset device/API rate limit for employee ' || p_employee_id::TEXT || COALESCE(' slot ' || p_slot::TEXT, ''),
      emp.name,
      emp.company_id,
      NULL,
      jsonb_build_object('employee_id', p_employee_id, 'slot', p_slot, 'deleted_attempts', deleted_count),
      'employee_devices',
      p_employee_id::TEXT,
      NULL,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'deleted_attempts', deleted_count);
END;
$$;

REVOKE ALL ON FUNCTION saas_admin_reset_employee_device_rate_limit(INTEGER, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_admin_reset_employee_device_rate_limit(INTEGER, INTEGER, TEXT) TO authenticated, service_role;

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
  leave_info JSONB;
  manual_deduct INTEGER := 0;
  loan_deduct INTEGER := 0;
  leave_deduct INTEGER := 0;
  total_deduct INTEGER := 0;
  net_salary INTEGER := 0;
  tenant JSONB;
  month_days_val INTEGER;
  biw_days INTEGER;
  include_ot BOOLEAN := FALSE;
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

  FOR att IN
    SELECT a.*
    FROM attendance a
    WHERE a.employee_id = p_employee_id
      AND a.date_iso >= bounds.period_start
      AND a.date_iso <= bounds.period_end
  LOOP
    IF att.check_in IS NOT NULL
       AND att.check_in <> '—'
       AND (emp.open_hours IS NOT TRUE OR (att.check_out IS NOT NULL AND att.check_out <> '—')) THEN
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

  leave_info := saas_v3_compute_leave_deductions(
    p_employee_id, emp.company_id, bounds.period_start, bounds.period_end, daily_rate
  );
  leave_deduct := COALESCE((leave_info->>'leave_deduct')::INTEGER, 0);

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
    'late_minutes', total_late_min,
    'overtime_minutes', total_ot_min,
    'late_deduct', late_deduct,
    'absent_deduct', absent_deduct,
    'leave_deduct', leave_deduct,
    'leave_days', COALESCE((leave_info->>'leave_days')::INTEGER, 0),
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
