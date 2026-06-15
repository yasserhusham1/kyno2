-- ============================================================
-- KYNO 042 — Reset stale salary fields on employee upsert
-- Fixes 500000 -> 499999 when re-adding employee (old biweekly half)
-- Run after 041
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
  IF st = 'biweekly' THEN
    sal_half := GREATEST(0, COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0));
    IF sal_half = 0 AND sal > 0 THEN
      sal_half := sal / 2;
    END IF;
    IF sal_half > 0 THEN
      sal := sal_half * 2;
    END IF;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal_half > 0 THEN
      dr := GREATEST(0, sal_half / 15);
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
      dr := GREATEST(0, sal / 30);
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

REVOKE ALL ON FUNCTION saas_upsert_employee(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee(JSONB) TO authenticated;
