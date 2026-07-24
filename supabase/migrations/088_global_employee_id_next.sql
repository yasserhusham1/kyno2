-- 088 — معرّف موظف عالمي (multi-tenant)
-- المشكلة: company_admin يرى موظفي شركته فقط → MAX(id)=NULL → id=1 يتصادم مع شركة أخرى → tenant_mismatch

CREATE OR REPLACE FUNCTION saas_next_employee_id()
RETURNS INTEGER
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(MAX(id), 0) + 1 FROM employees;
$$;

REVOKE ALL ON FUNCTION saas_next_employee_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_next_employee_id() TO authenticated;

-- إعادة تخصيص المعرّف عند تصادم عبر الشركات (إضافة موظف جديد وليس تعديلاً عابراً للمستأجر)
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
      existing_cid := (before_row->>'company_id')::INTEGER;
      IF existing_cid IS DISTINCT FROM cid THEN
        IF auth_is_super_admin() THEN
          RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
        END IF;
        -- إضافة لشركة جديدة: المعرّف محجوز لشركة أخرى — خصّص معرّفاً عالمياً جديداً
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
