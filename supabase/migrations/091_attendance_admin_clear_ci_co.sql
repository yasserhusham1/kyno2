-- 091 — Admin attendance edit: allow explicit clear check-in/check-out

CREATE OR REPLACE FUNCTION saas_upsert_attendance_admin(
  p_employee_id INTEGER,
  p_date_iso DATE,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_clear_check_in BOOLEAN DEFAULT FALSE,
  p_clear_check_out BOOLEAN DEFAULT FALSE,
  p_status TEXT DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  active_chk JSONB;
  before_row JSONB;
  after_row JSONB;
  att_id INTEGER;
  use_ci TEXT;
  use_co TEXT;
  use_late TEXT := '—';
  use_ot TEXT := '—';
  use_hours TEXT := '—';
  use_status TEXT := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  ci_min INTEGER;
  co_min INTEGER;
  official_ci INTEGER;
  official_co INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ot_min INTEGER;
  ot_hourly INTEGER;
  dlabel TEXT;
  existing RECORD;
BEGIN
  IF p_employee_id IS NULL OR p_date_iso IS NULL THEN
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

  active_chk := saas_assert_company_active(emp.company_id);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  SELECT to_jsonb(a.*) INTO before_row
  FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;

  SELECT a.check_in, a.check_out, a.status, a.late INTO existing
  FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;

  use_ci := CASE
    WHEN p_clear_check_in IS TRUE THEN '—'
    ELSE COALESCE(NULLIF(trim(p_check_in), ''), existing.check_in, '—')
  END;
  use_co := CASE
    WHEN p_clear_check_out IS TRUE THEN '—'
    ELSE COALESCE(NULLIF(trim(p_check_out), ''), existing.check_out, '—')
  END;

  IF use_ci = '—' AND use_co = '—' THEN
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'غياب');
  ELSIF emp.open_hours IS TRUE THEN
    use_late := '—';
    use_ot := '—';
    use_hours := '—';
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  ELSIF use_ci <> '—' AND use_co <> '—' THEN
    ci_min := basma_time_text_to_minutes(use_ci);
    co_min := basma_time_text_to_minutes(use_co);
    official_ci := basma_db_time_to_minutes(emp.check_in);
    official_co := basma_db_time_to_minutes(emp.check_out);
    late_min := GREATEST(0, ci_min - official_ci);
    IF late_min > late_threshold THEN
      use_status := 'متأخر';
      use_late := late_min || 'د';
    ELSIF late_min > 0 THEN
      use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
      use_late := late_min || 'د';
    END IF;
    IF co_min >= ci_min THEN
      use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ot_min := GREATEST(0, co_min - official_co);
      IF ot_min > 0 THEN
        ot_hourly := GREATEST(
          0,
          COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000)
        );
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN use_status := 'إضافي'; END IF;
      END IF;
    END IF;
  ELSE
    use_late := '—';
    use_ot := '—';
    use_hours := '—';
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  END IF;

  dlabel := basma_arabic_date_label(p_date_iso);

  INSERT INTO attendance (
    employee_id, company_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status
  ) VALUES (
    p_employee_id, emp.company_id, emp.name, emp.dept, dlabel, p_date_iso,
    use_ci, use_co, use_hours, use_late, use_ot, use_status
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = EXCLUDED.check_in,
    check_out = EXCLUDED.check_out,
    hours = EXCLUDED.hours,
    late = EXCLUDED.late,
    overtime = EXCLUDED.overtime,
    status = EXCLUDED.status
  RETURNING id INTO att_id;

  SELECT to_jsonb(a.*) INTO after_row FROM attendance a WHERE a.id = att_id;

  PERFORM saas_v3_write_audit(
    'attendance_override', 'attendance',
    COALESCE(NULLIF(trim(p_reason), ''), 'Admin attendance upsert'),
    emp.name,
    emp.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'attendance_id', att_id, 'data', after_row, 'server_authoritative', true);
END;
$$;

CREATE OR REPLACE FUNCTION saas_recalculate_attendance_day(
  p_employee_id INTEGER,
  p_date_iso DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  att RECORD;
BEGIN
  SELECT * INTO att FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attendance_not_found');
  END IF;

  RETURN saas_upsert_attendance_admin(
    p_employee_id,
    p_date_iso,
    att.check_in,
    att.check_out,
    FALSE,
    FALSE,
    att.status,
    'recalculate_day'
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_attendance_admin(INTEGER, DATE, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_admin(INTEGER, DATE, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT) TO authenticated;
