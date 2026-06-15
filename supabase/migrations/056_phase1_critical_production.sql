-- ============================================================
-- KYNO 056 — Phase 1 Critical Production Fixes
-- Payroll (leaves + loans + OT flag), Audit, RLS, Subscription, Export
-- ============================================================

-- 1) Employee overtime inclusion flag
ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS include_overtime_in_salary BOOLEAN NOT NULL DEFAULT FALSE;

-- ----------------------------------------------------------
-- 2) Leave deductions (matches client leave types)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_leave_days_in_period(
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
  eff_from DATE;
  eff_to DATE;
BEGIN
  IF p_from IS NULL THEN RETURN 1; END IF;
  eff_from := GREATEST(p_from, p_period_start);
  eff_to := LEAST(COALESCE(p_to, p_from), p_period_end);
  IF eff_to < eff_from THEN RETURN 0; END IF;
  RETURN GREATEST(1, (eff_to - eff_from) + 1);
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
    days_count := saas_v3_leave_days_in_period(lv.from_date, lv.to_date, p_period_start, p_period_end);
    deduct_amt := 0;
    lbl := COALESCE(lv.leave_type, 'paid_single');

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
      -- paid_open, paid_single — annual/sick paid: no deduction
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

-- ----------------------------------------------------------
-- 3) Loan installment (matches client currentLoanInstallmentAmount)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_loan_current_installment(p_item JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  amt INTEGER;
  cnt INTEGER;
  paid INTEGER;
  normal INTEGER;
  paid_amount INTEGER;
  remaining INTEGER;
  mode TEXT;
BEGIN
  IF p_item IS NULL OR COALESCE(p_item->>'type', '') <> 'loan' THEN RETURN 0; END IF;
  amt := GREATEST(0, COALESCE((p_item->>'amount')::INTEGER, 0));
  mode := COALESCE(p_item->>'loanMode', p_item->>'loan_mode', '');
  IF mode <> 'installments' THEN RETURN amt; END IF;

  cnt := GREATEST(1, COALESCE((p_item->>'installmentCount')::INTEGER, (p_item->>'installment_count')::INTEGER, 1));
  paid := GREATEST(0, COALESCE((p_item->>'paidInstallments')::INTEGER, (p_item->>'paid_installments')::INTEGER, 0));
  IF paid >= cnt THEN RETURN 0; END IF;

  normal := GREATEST(0, COALESCE((p_item->>'installmentAmount')::INTEGER, (p_item->>'installment_amount')::INTEGER, 0));
  IF normal = 0 THEN normal := GREATEST(0, amt / cnt); END IF;

  paid_amount := normal * paid;
  remaining := GREATEST(0, amt - paid_amount);
  IF paid = cnt - 1 THEN RETURN remaining; END IF;
  RETURN LEAST(normal, remaining);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_loan_remaining_balance(p_item JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  amt INTEGER;
  cnt INTEGER;
  paid INTEGER;
  normal INTEGER;
BEGIN
  IF p_item IS NULL OR COALESCE(p_item->>'type', '') <> 'loan' THEN RETURN 0; END IF;
  amt := GREATEST(0, COALESCE((p_item->>'amount')::INTEGER, 0));
  IF COALESCE(p_item->>'loanMode', p_item->>'loan_mode', '') <> 'installments' THEN
    IF COALESCE(p_item->>'status', '') IN ('مسدد', 'ملغي') THEN RETURN 0; END IF;
    RETURN amt;
  END IF;
  cnt := GREATEST(1, COALESCE((p_item->>'installmentCount')::INTEGER, (p_item->>'installment_count')::INTEGER, 1));
  paid := GREATEST(0, COALESCE((p_item->>'paidInstallments')::INTEGER, (p_item->>'paid_installments')::INTEGER, 0));
  normal := GREATEST(0, COALESCE((p_item->>'installmentAmount')::INTEGER, (p_item->>'installment_amount')::INTEGER, 0));
  IF normal = 0 THEN normal := GREATEST(0, amt / cnt); END IF;
  RETURN GREATEST(0, amt - (normal * paid));
END;
$$;

-- ----------------------------------------------------------
-- 4) Finance totals — unified loan logic + detail payload
-- ----------------------------------------------------------
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
  inst INTEGER;
  loan_items JSONB := '[]'::jsonb;
BEGIN
  raw := saas_v3_company_setting(p_company_id, 'finance_items');
  IF raw IS NULL OR trim(raw) = '' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END IF;
  BEGIN
    arr := raw::JSONB;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
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
      inst := saas_v3_loan_current_installment(item);
      IF inst > 0 THEN
        loans := loans + inst;
        loan_items := loan_items || jsonb_build_array(jsonb_build_object(
          'id', item->>'id',
          'amount', amt,
          'installment_count', COALESCE((item->>'installmentCount')::INTEGER, (item->>'installment_count')::INTEGER, 1),
          'paid_installments', COALESCE((item->>'paidInstallments')::INTEGER, (item->>'paid_installments')::INTEGER, 0),
          'current_installment', inst,
          'remaining_balance', saas_v3_loan_remaining_balance(item),
          'loan_mode', COALESCE(item->>'loanMode', item->>'loan_mode', 'lump'),
          'status', status
        ));
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'deductions', deductions,
    'bonuses', bonuses,
    'loans', loans,
    'loan_items', loan_items
  );
END;
$$;

-- ----------------------------------------------------------
-- 5) Subscription enforcement inside tenant assert
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
  active_chk JSONB;
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

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', COALESCE(active_chk->>'error', 'subscription_inactive'),
      'detail', active_chk
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'company_id', cid);
END;
$$;

-- ----------------------------------------------------------
-- 6) Enhanced audit writer
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_write_audit(
  p_action TEXT,
  p_category TEXT,
  p_details TEXT,
  p_target_name TEXT,
  p_company_id INTEGER,
  p_before JSONB DEFAULT NULL,
  p_after JSONB DEFAULT NULL,
  p_entity_type TEXT DEFAULT NULL,
  p_entity_id TEXT DEFAULT NULL,
  p_ip_address TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta JSONB;
  cid INTEGER;
BEGIN
  cid := p_company_id;
  IF (cid IS NULL OR cid <= 0) THEN
    cid := auth_company_id();
  END IF;

  meta := jsonb_build_object(
    'company_id', cid,
    'timestamp', to_jsonb(NOW()),
    'entity_type', NULLIF(trim(p_entity_type), ''),
    'entity_id', NULLIF(trim(p_entity_id), ''),
    'old_value', COALESCE(p_before, 'null'::jsonb),
    'new_value', COALESCE(p_after, 'null'::jsonb),
    'before', COALESCE(p_before, 'null'::jsonb),
    'after', COALESCE(p_after, 'null'::jsonb)
  );

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta,
    ip_address, user_agent
  ) VALUES (
    cid,
    NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER,
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'display_name', auth.jwt() ->> 'email', ''),
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth_app_role()),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    meta,
    NULLIF(trim(p_ip_address), ''),
    NULLIF(trim(p_user_agent), '')
  );
EXCEPTION
  WHEN others THEN
    NULL;
END;
$$;

CREATE OR REPLACE FUNCTION saas_record_client_audit(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  action TEXT;
  active_chk JSONB;
BEGIN
  cid := auth_company_id();
  IF (cid IS NULL OR cid <= 0) AND auth_is_super_admin() THEN
    cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF NOT auth_is_super_admin() THEN
    active_chk := saas_assert_company_active(cid);
    IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(active_chk->>'error', 'subscription_inactive'));
    END IF;
  END IF;

  action := COALESCE(NULLIF(trim(p_payload->>'action'), ''), 'client_event');
  PERFORM saas_v3_write_audit(
    action,
    COALESCE(NULLIF(trim(p_payload->>'category'), ''), 'client'),
    COALESCE(p_payload->>'details', action),
    COALESCE(p_payload->>'target_name', ''),
    cid,
    p_payload->'old_value',
    p_payload->'new_value',
    p_payload->>'entity_type',
    p_payload->>'entity_id',
    p_payload->>'ip_address',
    p_payload->>'user_agent'
  );
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ----------------------------------------------------------
-- 7) Authoritative payroll compute
-- ----------------------------------------------------------
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

-- ----------------------------------------------------------
-- 8) Employee upsert — include_overtime_in_salary
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
  st TEXT;
  sal INTEGER;
  sal_half INTEGER;
  dr INTEGER;
  payload_half INTEGER;
  month_days_val INTEGER;
  biw_days INTEGER;
  include_ot BOOLEAN := FALSE;
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

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url, include_overtime_in_salary
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
      include_ot
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
      include_overtime_in_salary = EXCLUDED.include_overtime_in_salary,
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url, include_overtime_in_salary
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
      NULLIF(p_payload->>'avatar_url', ''),
      include_ot
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
    after_row,
    'employees',
    emp_id::TEXT,
    p_payload->>'ip_address',
    p_payload->>'user_agent'
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

-- ----------------------------------------------------------
-- 9) Company export / import (JSON via RPC — no Storage bucket)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_export_company_data()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  payload JSONB;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  payload := jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'exported_at', NOW(),
    'version', '056',
    'employees', COALESCE((SELECT jsonb_agg(to_jsonb(e.*) ORDER BY e.id) FROM employees e WHERE e.company_id = cid), '[]'::jsonb),
    'attendance', COALESCE((SELECT jsonb_agg(to_jsonb(a.*) ORDER BY a.date_iso) FROM attendance a WHERE a.company_id = cid), '[]'::jsonb),
    'salary_records', COALESCE((SELECT jsonb_agg(to_jsonb(s.*) ORDER BY s.month_iso) FROM salary_records s WHERE s.company_id = cid), '[]'::jsonb),
    'leaves', COALESCE((SELECT jsonb_agg(to_jsonb(l.*) ORDER BY l.from_date) FROM leaves l WHERE l.company_id = cid), '[]'::jsonb),
    'departments', COALESCE((SELECT jsonb_agg(to_jsonb(d.*) ORDER BY d.name) FROM departments d WHERE d.company_id = cid), '[]'::jsonb),
    'settings', COALESCE((
      SELECT jsonb_object_agg(
        replace(s.key, 'company:' || cid::text || ':', ''),
        s.value
      )
      FROM app_settings s
      WHERE s.key LIKE ('company:' || cid::text || ':%')
    ), '{}'::jsonb)
  );

  PERFORM saas_v3_write_audit('company_export', 'backup', 'Exported company data', 'company:' || cid::TEXT, cid, NULL, jsonb_build_object('exported_at', NOW()), 'company', cid::TEXT, NULL, NULL);
  RETURN payload;
END;
$$;

-- Import merges settings + finance only; employees/attendance require existing RPCs (safety)
CREATE OR REPLACE FUNCTION saas_import_company_settings(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  file_cid INTEGER;
  settings JSONB;
  k TEXT;
  v TEXT;
  cnt INTEGER := 0;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  file_cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  IF file_cid IS NOT NULL AND file_cid <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_id_mismatch');
  END IF;

  settings := p_payload->'settings';
  IF settings IS NULL OR jsonb_typeof(settings) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_settings');
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(settings)
  LOOP
    IF k IS NULL OR k = '' OR k LIKE 'global:%' THEN CONTINUE; END IF;
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('company:' || cid::text || ':' || k, v, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END LOOP;

  PERFORM saas_v3_write_audit('company_import', 'backup', 'Imported company settings (' || cnt::TEXT || ' keys)', 'company:' || cid::TEXT, cid, NULL, settings, 'company', cid::TEXT, NULL, NULL);
  RETURN jsonb_build_object('ok', true, 'imported_keys', cnt);
END;
$$;

-- ----------------------------------------------------------
-- 10) RLS alignment — leaves + notifications (030 model)
-- ----------------------------------------------------------
ALTER TABLE leaves ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leaves_company_policy ON leaves;
DROP POLICY IF EXISTS emp_notif_company_policy ON employee_notifications;
DROP POLICY IF EXISTS admin_notif_company_policy ON admin_notifications;

DROP POLICY IF EXISTS deny_anon_leaves ON leaves;
DROP POLICY IF EXISTS leaves_tenant_only ON leaves;
DROP POLICY IF EXISTS leaves_super_admin ON leaves;

CREATE POLICY deny_anon_leaves ON leaves
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY leaves_tenant_only ON leaves
  FOR ALL TO authenticated
  USING (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id())
  WITH CHECK (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id());

CREATE POLICY leaves_super_admin ON leaves
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

DROP POLICY IF EXISTS deny_anon_employee_notifications ON employee_notifications;
DROP POLICY IF EXISTS emp_notif_tenant_only ON employee_notifications;
DROP POLICY IF EXISTS emp_notif_super_admin ON employee_notifications;

CREATE POLICY deny_anon_employee_notifications ON employee_notifications
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY emp_notif_tenant_only ON employee_notifications
  FOR ALL TO authenticated
  USING (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id())
  WITH CHECK (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id());

CREATE POLICY emp_notif_super_admin ON employee_notifications
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

DROP POLICY IF EXISTS deny_anon_admin_notifications ON admin_notifications;
DROP POLICY IF EXISTS admin_notif_tenant_only ON admin_notifications;
DROP POLICY IF EXISTS admin_notif_super_admin ON admin_notifications;

CREATE POLICY deny_anon_admin_notifications ON admin_notifications
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY admin_notif_tenant_only ON admin_notifications
  FOR ALL TO authenticated
  USING (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id())
  WITH CHECK (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id());

CREATE POLICY admin_notif_super_admin ON admin_notifications
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 11) Grants
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_record_client_audit(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_record_client_audit(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_export_company_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_export_company_data() TO authenticated;

REVOKE ALL ON FUNCTION saas_import_company_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_import_company_settings(JSONB) TO authenticated;
