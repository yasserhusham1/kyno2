-- 111 — تاريخ المباشرة (hire_date) للموظف
-- المسار الآمن: لا يُحتسب أي غياب قبل تاريخ المباشرة، بدون إدراج/حذف سجلات غياب فعلية.
--
-- 1) عمود hire_date DATE (nullable) — إضافي وآمن، لا يمس أي بيانات قائمة.
-- 2) تحديث saas_upsert_employee لقبول hire_date (INSERT/UPDATE) مع الحفاظ على القيمة عند عدم الإرسال.
-- 3) تحديث saas_v3_compute_salary بحيث تبدأ نافذة احتساب الغياب/الإجازات من
--    effective_start = GREATEST(period_start, hire_date). عند عدم ضبط hire_date
--    يبقى السلوك مطابقاً تماماً للنسخة الحالية (backward compatible).

-- ============================================================
-- 1) العمود
-- ============================================================
ALTER TABLE employees ADD COLUMN IF NOT EXISTS hire_date DATE;

-- ============================================================
-- 2) upsert — مبني على النسخة 088 مع إضافة hire_date فقط
-- ============================================================
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
  include_ot BOOLEAN := FALSE;
  existing_cid INTEGER;
  hire DATE;
  has_hire BOOLEAN := FALSE;
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
  include_ot := COALESCE(
    (p_payload->>'include_overtime_in_salary')::BOOLEAN,
    (p_payload->>'includeOvertimeInSalary')::BOOLEAN,
    false
  );

  -- hire_date: يُميَّز بين "غير مرسل" (لا نلمس القيمة) و"مرسل فارغ" (تفريغ) و"مرسل بقيمة".
  has_hire := (p_payload ? 'hire_date') OR (p_payload ? 'hireDate');
  IF has_hire THEN
    hire := NULLIF(COALESCE(p_payload->>'hire_date', p_payload->>'hireDate'), '')::DATE;
  END IF;

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      existing_cid := (before_row->>'company_id')::INTEGER;
      IF existing_cid IS DISTINCT FROM cid THEN
        IF auth_is_super_admin() THEN
          RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
        END IF;
        emp_id := saas_next_employee_id();
        before_row := NULL;
        is_new := true;
      ELSE
        tenant := saas_v3_assert_tenant(existing_cid);
        IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
          RETURN tenant;
        END IF;
      END IF;
    END IF;
  ELSE
    is_new := true;
    emp_id := saas_next_employee_id();
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
    IF sal_half = 0 AND sal > 0 THEN sal_half := sal / 2; END IF;
    IF sal = 0 AND sal_half > 0 THEN sal := sal_half * 2; END IF;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal_half > 0 THEN dr := GREATEST(0, sal_half / biw_days); END IF;
  ELSIF st = 'commission' THEN
    sal := 0; sal_half := 0; dr := 0;
  ELSE
    st := 'monthly'; sal_half := 0;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal > 0 THEN dr := GREATEST(0, sal / month_days_val); END IF;
  END IF;

  IF is_new THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url, include_overtime_in_salary,
      hire_date
    ) VALUES (
      emp_id, cid,
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
      NULLIF(p_payload->>'avatar_url', ''),
      include_ot,
      CASE WHEN has_hire THEN hire ELSE NULL END
    )
    RETURNING * INTO row;
  ELSE
    UPDATE employees SET
      name = COALESCE(p_payload->>'name', name),
      dept = COALESCE(p_payload->>'dept', dept),
      role = COALESCE(p_payload->>'role', role),
      phone = COALESCE(p_payload->>'phone', phone),
      salary = sal,
      salary_type = st,
      salary_half = sal_half,
      daily_rate = dr,
      days = COALESCE((p_payload->>'days')::INTEGER, days),
      late_min = COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, late_min),
      check_in = COALESCE(p_payload->>'check_in', p_payload->>'checkIn', check_in::TEXT)::TIME,
      check_out = COALESCE(p_payload->>'check_out', p_payload->>'checkOut', check_out::TEXT)::TIME,
      open_hours = COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, open_hours),
      remote_attend = COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, remote_attend),
      sal_status = COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', sal_status),
      sal_bonus = COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, sal_bonus),
      sal_deleted_period = COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', sal_deleted_period),
      avatar_url = COALESCE(NULLIF(p_payload->>'avatar_url', ''), avatar_url),
      include_overtime_in_salary = include_ot,
      hire_date = CASE WHEN has_hire THEN hire ELSE hire_date END,
      updated_at = NOW()
    WHERE id = emp_id AND company_id = cid
    RETURNING * INTO row;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
    END IF;
  END IF;

  after_row := to_jsonb(row);
  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,
    'employees',
    CASE WHEN is_new THEN 'Created employee ' || emp_id::TEXT ELSE 'Updated employee ' || emp_id::TEXT END,
    row.name,
    cid,
    before_row,
    after_row,
    'employees',
    emp_id::TEXT,
    p_payload->>'ip_address',
    p_payload->>'user_agent'
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_employee(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee(JSONB) TO authenticated;

-- ============================================================
-- 3) محرك الراتب — مبني على النسخة 109 مع احترام hire_date
-- ============================================================
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
  recorded_absent_completed INTEGER := 0;
  recorded_absent_future INTEGER := 0;
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
  effective_start DATE;
  seen_attend_dates TEXT[] := ARRAY[]::TEXT[];
  seen_absent_completed_dates TEXT[] := ARRAY[]::TEXT[];
  seen_absent_future_dates TEXT[] := ARRAY[]::TEXT[];
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

  -- تاريخ المباشرة: لا يُحتسب أي غياب/إجازة قبله.
  -- عند عدم ضبطه يبقى effective_start = period_start (سلوك مطابق للسابق).
  IF emp.hire_date IS NOT NULL AND emp.hire_date > bounds.period_start THEN
    effective_start := emp.hire_date;
  ELSE
    effective_start := bounds.period_start;
  END IF;

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
    saas_v3_work_days_between(effective_start, period_elapsed_end)
  );

  IF period_elapsed_end >= effective_start THEN
    leave_covered_days := saas_v3_leave_covered_days(
      p_employee_id, emp.company_id, effective_start, period_elapsed_end
    );
    paid_leave_days := saas_v3_paid_leave_days(
      p_employee_id, emp.company_id, effective_start, period_elapsed_end
    );
    official_paid_closure_days := saas_v3_official_closure_days(emp.company_id, effective_start, period_elapsed_end, 'paid');
    official_unpaid_closure_days := saas_v3_official_closure_days(emp.company_id, effective_start, period_elapsed_end, 'unpaid');
    IF NOT is_comm THEN
      leave_covered_days := leave_covered_days + official_paid_closure_days + official_unpaid_closure_days;
      paid_leave_days := paid_leave_days + official_paid_closure_days;
    END IF;
  END IF;

  IF period_elapsed_end >= effective_start THEN
    FOR att IN
      SELECT a.*
      FROM attendance a
      WHERE a.employee_id = p_employee_id
        AND a.date_iso >= effective_start
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
        IF NOT day_key = ANY(seen_absent_completed_dates) THEN
          recorded_absent_completed := recorded_absent_completed + 1;
          seen_absent_completed_dates := array_append(seen_absent_completed_dates, day_key);
        END IF;
      END IF;
    END LOOP;
  END IF;

  -- غياب صريح مُدخل للأيام المتبقية داخل الفترة (دفعة إدارية) — لا يُحتسب قبل المباشرة
  IF bounds.period_end > period_elapsed_end THEN
    FOR att IN
      SELECT a.*
      FROM attendance a
      WHERE a.employee_id = p_employee_id
        AND a.date_iso > period_elapsed_end
        AND a.date_iso <= bounds.period_end
        AND a.date_iso >= effective_start
        AND a.status = 'غياب'
        AND NOT saas_v3_leave_covers_date(p_employee_id, emp.company_id, att.date_iso)
        AND NOT saas_v3_official_closure_covers_date(emp.company_id, att.date_iso)
      ORDER BY a.date_iso ASC, a.id ASC
    LOOP
      day_key := COALESCE(att.date_iso::TEXT, '');
      IF day_key = '' OR day_key = ANY(seen_absent_future_dates) THEN
        CONTINUE;
      END IF;
      seen_absent_future_dates := array_append(seen_absent_future_dates, day_key);
      recorded_absent_future := recorded_absent_future + 1;
    END LOOP;
  END IF;

  recorded_absent := recorded_absent_completed + recorded_absent_future;

  IF is_comm THEN
    expected_absent := 0;
  ELSE
    expected_absent := GREATEST(
      0,
      elapsed_work_days - attend_days - recorded_absent_completed - leave_covered_days
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

  IF period_elapsed_end >= effective_start THEN
    leave_info := saas_v3_compute_leave_deductions(
      p_employee_id, emp.company_id, effective_start, period_elapsed_end, daily_rate
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
    net_salary := base_salary + bonus - total_deduct + CASE WHEN include_ot THEN ot_amount ELSE 0 END;
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
    'recorded_absent_completed_days', recorded_absent_completed,
    'recorded_absent_future_days', recorded_absent_future,
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
    'hire_date', emp.hire_date,
    'effective_start', effective_start,
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

REVOKE ALL ON FUNCTION saas_v3_compute_salary(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_compute_salary(INTEGER, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
