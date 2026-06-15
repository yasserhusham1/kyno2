-- ============================================================
-- KYNO 053 — الإضافي يُعرض منفصلاً ولا يُضاف إلى الراتب الصافي
-- ============================================================

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
    -- overtime_amount يُحفظ للعرض فقط — لا يُضاف إلى net_salary
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
