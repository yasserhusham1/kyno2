-- 095 — تطبيق شروط الإجازات في الرواتب حسب النوع (مدفوعة / غير مدفوعة / غياب)
-- - الإجازة المدفوعة: لا خصم
-- - الإجازة غير المدفوعة / الغياب المضاعف: خصم حسب النوع فقط
-- - يوم الإجازة لا يُحسب غياباً حتى لو سُجّل «غياب» في الحضور
-- - الإجازة اليومية (paid_single / unpaid_single / absence_mult) = يوم واحد فقط

CREATE OR REPLACE FUNCTION saas_v3_normalize_leave_type(p_leave_type TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE COALESCE(NULLIF(trim(p_leave_type), ''), 'paid_single')
    WHEN 'annual' THEN 'paid_single'
    WHEN 'sick' THEN 'paid_single'
    WHEN 'paid' THEN 'paid_single'
    WHEN 'unpaid' THEN 'unpaid_single'
    ELSE COALESCE(NULLIF(trim(p_leave_type), ''), 'paid_single')
  END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_leave_effective_days_in_period(
  p_leave_type TEXT,
  p_from DATE,
  p_to DATE,
  p_period_start DATE,
  p_period_end DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  lbl TEXT;
BEGIN
  lbl := saas_v3_normalize_leave_type(p_leave_type);
  IF lbl IN ('paid_open', 'unpaid_open') THEN
    RETURN saas_v3_leave_days_in_period(p_from, p_to, p_period_start, p_period_end);
  END IF;
  IF p_from IS NULL THEN RETURN 0; END IF;
  IF p_from >= p_period_start AND p_from <= p_period_end THEN
    RETURN 1;
  END IF;
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_leave_covers_date(
  p_employee_id INTEGER,
  p_company_id INTEGER,
  p_date DATE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lv RECORD;
  lbl TEXT;
  eff_to DATE;
BEGIN
  IF p_date IS NULL THEN RETURN FALSE; END IF;

  FOR lv IN
    SELECT l.*
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = p_company_id
      AND l.from_date <= p_date
      AND COALESCE(l.to_date, l.from_date) >= p_date
  LOOP
    lbl := saas_v3_normalize_leave_type(lv.leave_type);
    IF lbl IN ('paid_open', 'unpaid_open') THEN
      eff_to := COALESCE(lv.to_date, lv.from_date);
      IF p_date >= lv.from_date AND p_date <= eff_to THEN
        RETURN TRUE;
      END IF;
    ELSIF p_date = lv.from_date THEN
      RETURN TRUE;
    END IF;
  END LOOP;

  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_leave_covered_days(
  p_employee_id INTEGER,
  p_company_id INTEGER,
  p_period_start DATE,
  p_period_end DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lv RECORD;
  covered INTEGER := 0;
BEGIN
  FOR lv IN
    SELECT l.*
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = p_company_id
      AND l.from_date <= p_period_end
      AND COALESCE(l.to_date, l.from_date) >= p_period_start
  LOOP
    covered := covered + saas_v3_leave_effective_days_in_period(
      lv.leave_type,
      lv.from_date,
      lv.to_date,
      p_period_start,
      p_period_end
    );
  END LOOP;
  RETURN GREATEST(0, covered);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_paid_leave_days(
  p_employee_id INTEGER,
  p_company_id INTEGER,
  p_period_start DATE,
  p_period_end DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lv RECORD;
  paid_days INTEGER := 0;
  lbl TEXT;
BEGIN
  FOR lv IN
    SELECT l.*
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = p_company_id
      AND l.from_date <= p_period_end
      AND COALESCE(l.to_date, l.from_date) >= p_period_start
  LOOP
    lbl := saas_v3_normalize_leave_type(lv.leave_type);
    IF lbl IN ('paid_single', 'paid_open') THEN
      paid_days := paid_days + saas_v3_leave_effective_days_in_period(
        lv.leave_type,
        lv.from_date,
        lv.to_date,
        p_period_start,
        p_period_end
      );
    END IF;
  END LOOP;
  RETURN GREATEST(0, paid_days);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_compute_leave_deductions(
  p_employee_id INTEGER,
  p_company_id INTEGER,
  p_period_start DATE,
  p_period_end DATE,
  p_daily_rate INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lv RECORD;
  leave_deduct INTEGER := 0;
  leave_days INTEGER := 0;
  items JSONB := '[]'::JSONB;
  days_count INTEGER;
  deduct_amt INTEGER;
  mult INTEGER;
  lbl TEXT;
BEGIN
  IF p_daily_rate IS NULL OR p_daily_rate <= 0 THEN
    RETURN jsonb_build_object('leave_deduct', 0, 'leave_days', 0, 'leave_items', '[]'::jsonb);
  END IF;

  FOR lv IN
    SELECT l.*
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = p_company_id
      AND l.from_date <= p_period_end
      AND COALESCE(l.to_date, l.from_date) >= p_period_start
  LOOP
    days_count := saas_v3_leave_effective_days_in_period(
      lv.leave_type,
      lv.from_date,
      lv.to_date,
      p_period_start,
      p_period_end
    );
    IF days_count <= 0 THEN
      CONTINUE;
    END IF;

    deduct_amt := 0;
    lbl := saas_v3_normalize_leave_type(lv.leave_type);

    IF lbl = 'unpaid_open' THEN
      deduct_amt := ROUND(days_count * p_daily_rate);
      leave_days := leave_days + days_count;
    ELSIF lbl = 'unpaid_single' THEN
      deduct_amt := p_daily_rate;
      leave_days := leave_days + 1;
    ELSIF lbl = 'absence_mult' THEN
      mult := GREATEST(1, COALESCE(lv.multiplier, 1));
      deduct_amt := ROUND(mult * p_daily_rate);
      leave_days := leave_days + 1;
      lbl := lbl || ' (×' || mult::TEXT || ')';
    ELSE
      -- paid_open, paid_single — لا خصم
      CONTINUE;
    END IF;

    IF deduct_amt > 0 THEN
      leave_deduct := leave_deduct + deduct_amt;
      items := items || jsonb_build_array(jsonb_build_object(
        'label', lbl,
        'days', days_count,
        'deduct', deduct_amt,
        'leave_type', lv.leave_type
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'leave_deduct', leave_deduct,
    'leave_days', leave_days,
    'leave_items', items
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
  computed_late_min INTEGER := 0;
  ci_min INTEGER := 0;
  official_ci_min INTEGER := 0;
  official_work_minutes INTEGER := 0;
  late_minute_rate NUMERIC := 0;
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

  leave_covered_days := saas_v3_leave_covered_days(
    p_employee_id, emp.company_id, bounds.period_start, bounds.period_end
  );
  paid_leave_days := saas_v3_paid_leave_days(
    p_employee_id, emp.company_id, bounds.period_start, bounds.period_end
  );

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
      IF NOT is_comm
         AND emp.open_hours IS NOT TRUE
         AND att.check_out IS NOT NULL
         AND att.check_out <> '—' THEN
        total_ot_min := total_ot_min + saas_v3_parse_ot_minutes(att.overtime);
        computed_late_min := 0;
        IF att.late IS NOT NULL AND att.late <> '—' THEN
          computed_late_min := saas_v3_parse_late_minutes(att.late);
        END IF;
        IF computed_late_min <= 0 THEN
          ci_min := basma_time_text_to_minutes(att.check_in);
          official_ci_min := basma_db_time_to_minutes(emp.check_in);
          computed_late_min := GREATEST(0, ci_min - official_ci_min);
        END IF;
        total_late_min := total_late_min + GREATEST(0, computed_late_min);
      END IF;
    ELSIF att.status = 'غياب'
      AND NOT saas_v3_leave_covers_date(p_employee_id, emp.company_id, att.date_iso) THEN
      recorded_absent := recorded_absent + 1;
    END IF;
  END LOOP;

  IF is_comm THEN
    expected_absent := 0;
  ELSE
    expected_absent := GREATEST(
      0,
      bounds.elapsed_days - attend_days - recorded_absent - leave_covered_days
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
    'recorded_absent_days', recorded_absent,
    'expected_absent_days', expected_absent,
    'leave_covered_days', leave_covered_days,
    'paid_leave_days', paid_leave_days,
    'late_minutes', total_late_min,
    'overtime_minutes', total_ot_min,
    'late_deduct', late_deduct,
    'late_minute_rate', ROUND(late_minute_rate, 4),
    'official_work_minutes', official_work_minutes,
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

REVOKE ALL ON FUNCTION saas_v3_normalize_leave_type(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_normalize_leave_type(TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_leave_effective_days_in_period(TEXT, DATE, DATE, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_leave_effective_days_in_period(TEXT, DATE, DATE, DATE, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_leave_covers_date(INTEGER, INTEGER, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_leave_covers_date(INTEGER, INTEGER, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_leave_covered_days(INTEGER, INTEGER, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_leave_covered_days(INTEGER, INTEGER, DATE, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_paid_leave_days(INTEGER, INTEGER, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_paid_leave_days(INTEGER, INTEGER, DATE, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_compute_leave_deductions(INTEGER, INTEGER, DATE, DATE, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_compute_leave_deductions(INTEGER, INTEGER, DATE, DATE, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_compute_salary(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_compute_salary(INTEGER, TEXT) TO authenticated;
