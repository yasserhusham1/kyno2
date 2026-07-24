-- 100 — الغياب التلقائي حسب كل يوم مكتمل، وليس أيام العمل فقط
-- إذا اليوم 2026-07-09، يتم احتساب 2026-07-08 كغياب إذا لا يوجد حضور + انصراف.

CREATE OR REPLACE FUNCTION saas_v3_work_days_between(
  p_start DATE,
  p_end DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  d DATE := p_start;
  n INTEGER := 0;
BEGIN
  IF p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN
    RETURN 0;
  END IF;

  WHILE d <= p_end LOOP
    n := n + 1;
    d := d + 1;
  END LOOP;

  RETURN GREATEST(0, n);
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
      AND NOT saas_v3_leave_covers_date(p_employee_id, emp.company_id, att.date_iso) THEN
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

REVOKE ALL ON FUNCTION saas_v3_work_days_between(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_work_days_between(DATE, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_compute_salary(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_compute_salary(INTEGER, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
