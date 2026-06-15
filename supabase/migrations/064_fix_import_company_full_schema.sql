-- ============================================================
-- KYNO 064 — Fix saas_import_company_full column mismatches
-- departments: no created_at/updated_at
-- attendance: no updated_at
-- salary_records / leaves: align with live schema + export JSON
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

CREATE OR REPLACE FUNCTION saas_import_company_full(p_payload JSONB)
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
  cnt_settings INTEGER := 0;
  cnt_emp INTEGER := 0;
  cnt_att INTEGER := 0;
  cnt_sal INTEGER := 0;
  cnt_lev INTEGER := 0;
  cnt_dept INTEGER := 0;
  emp JSONB;
  att JSONB;
  sal JSONB;
  lev JSONB;
  dept JSONB;
  eid INTEGER;
  dept_name TEXT;
  is_super BOOLEAN := false;
  audit_action TEXT := 'company_import_full';
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  is_super := auth_is_super_admin();

  IF cid IS NULL OR cid <= 0 THEN
    IF is_super THEN
      IF NOT saas_super_admin_can('companies_view') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
      END IF;
      cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
      IF cid IS NULL OR cid <= 0 THEN
        RETURN jsonb_build_object(
          'ok', false,
          'error', 'invalid_company',
          'detail', 'company_id required in backup JSON for super admin import'
        );
      END IF;
      IF NOT EXISTS (SELECT 1 FROM companies c WHERE c.id = cid) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
      END IF;
      audit_action := 'super_company_import';
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
    END IF;
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  file_cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  IF file_cid IS NOT NULL AND file_cid <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_id_mismatch', 'expected', cid, 'got', file_cid);
  END IF;

  settings := p_payload->'settings';
  IF settings IS NOT NULL AND jsonb_typeof(settings) = 'object' THEN
    FOR k, v IN SELECT key, value FROM jsonb_each_text(settings)
    LOOP
      IF k IS NULL OR k = '' OR k LIKE 'global:%' THEN CONTINUE; END IF;
      INSERT INTO app_settings (key, value, updated_at)
      VALUES ('company:' || cid::text || ':' || k, v, NOW())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
      cnt_settings := cnt_settings + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'finance_items' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('company:' || cid::text || ':finance_items', (p_payload->'finance_items')::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt_settings := cnt_settings + 1;
  END IF;

  IF p_payload ? 'departments' AND jsonb_typeof(p_payload->'departments') = 'array' THEN
    FOR dept IN SELECT * FROM jsonb_array_elements(p_payload->'departments')
    LOOP
      dept_name := NULLIF(trim(COALESCE(dept->>'name', dept->>'dept', '')), '');
      IF dept_name IS NULL THEN CONTINUE; END IF;
      INSERT INTO departments (company_id, name)
      VALUES (cid, dept_name)
      ON CONFLICT DO NOTHING;
      cnt_dept := cnt_dept + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'employees' AND jsonb_typeof(p_payload->'employees') = 'array' THEN
    FOR emp IN SELECT * FROM jsonb_array_elements(p_payload->'employees')
    LOOP
      eid := NULLIF((emp->>'id')::INTEGER, 0);
      IF eid IS NULL THEN CONTINUE; END IF;
      INSERT INTO employees (
        id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
        daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
        sal_status, sal_bonus, sal_deleted_period, avatar_url, include_overtime_in_salary
      ) VALUES (
        eid, cid,
        COALESCE(emp->>'name', ''),
        COALESCE(emp->>'dept', ''),
        COALESCE(emp->>'role', ''),
        COALESCE(emp->>'phone', '—'),
        COALESCE((emp->>'salary')::INTEGER, 0),
        COALESCE(emp->>'salary_type', emp->>'salaryType', 'monthly'),
        COALESCE((emp->>'salary_half')::INTEGER, (emp->>'salaryHalf')::INTEGER, 0),
        COALESCE((emp->>'daily_rate')::INTEGER, (emp->>'dailyRate')::INTEGER, 0),
        COALESCE((emp->>'days')::INTEGER, 0),
        COALESCE((emp->>'late_min')::INTEGER, (emp->>'lateMin')::INTEGER, 0),
        COALESCE(emp->>'check_in', emp->>'checkIn', '08:00')::TIME,
        COALESCE(emp->>'check_out', emp->>'checkOut', '17:00')::TIME,
        COALESCE((emp->>'open_hours')::BOOLEAN, (emp->>'openHours')::BOOLEAN, false),
        COALESCE((emp->>'remote_attend')::BOOLEAN, (emp->>'remoteAttend')::BOOLEAN, false),
        COALESCE(emp->>'sal_status', emp->>'salStatus', 'معلق'),
        COALESCE((emp->>'sal_bonus')::INTEGER, (emp->>'salBonus')::INTEGER, 0),
        COALESCE(emp->>'sal_deleted_period', emp->>'salDeletedPeriod', ''),
        NULLIF(emp->>'avatar_url', ''),
        COALESCE((emp->>'include_overtime_in_salary')::BOOLEAN, (emp->>'includeOvertimeInSalary')::BOOLEAN, false)
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
      WHERE employees.company_id = cid;
      cnt_emp := cnt_emp + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'attendance' AND jsonb_typeof(p_payload->'attendance') = 'array' THEN
    FOR att IN SELECT * FROM jsonb_array_elements(p_payload->'attendance')
    LOOP
      IF (att->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO attendance (
        employee_id, company_id, emp_name, dept, date_label, date_iso,
        check_in, check_out, hours, late, overtime, status
      ) VALUES (
        (att->>'employee_id')::INTEGER, cid,
        COALESCE(att->>'emp_name', att->>'emp', ''),
        COALESCE(att->>'dept', ''),
        COALESCE(att->>'date_label', att->>'date', ''),
        COALESCE(
          NULLIF(trim(COALESCE(att->>'date_iso', att->>'dateIso', '')), '')::DATE,
          CURRENT_DATE
        ),
        COALESCE(att->>'check_in', att->>'ci', '—'),
        COALESCE(att->>'check_out', att->>'co', '—'),
        COALESCE(att->>'hours', att->>'hrs', '—'),
        COALESCE(att->>'late', '—'),
        COALESCE(att->>'overtime', att->>'ot', '—'),
        COALESCE(att->>'status', 'طبيعي')
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
        status = EXCLUDED.status,
        company_id = cid;
      cnt_att := cnt_att + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'salary_records' AND jsonb_typeof(p_payload->'salary_records') = 'array' THEN
    FOR sal IN SELECT * FROM jsonb_array_elements(p_payload->'salary_records')
    LOOP
      IF (sal->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO salary_records (
        employee_id, company_id, month_iso, month_label,
        base_salary, attend_days, late_minutes, late_deduct,
        absent_days, overtime_amount, bonus, total_deduct, net_salary,
        status, issued_at
      ) VALUES (
        (sal->>'employee_id')::INTEGER, cid,
        COALESCE(sal->>'month_iso', sal->>'monthIso', ''),
        COALESCE(sal->>'month_label', sal->>'month', ''),
        COALESCE((sal->>'base_salary')::INTEGER, (sal->>'base')::INTEGER, 0),
        COALESCE((sal->>'attend_days')::INTEGER, 0),
        COALESCE((sal->>'late_minutes')::INTEGER, 0),
        COALESCE((sal->>'late_deduct')::INTEGER, 0),
        COALESCE((sal->>'absent_days')::INTEGER, 0),
        COALESCE((sal->>'overtime_amount')::INTEGER, (sal->>'overtime')::INTEGER, (sal->>'ot')::INTEGER, 0),
        COALESCE((sal->>'bonus')::INTEGER, 0),
        COALESCE((sal->>'total_deduct')::INTEGER, (sal->>'deductions')::INTEGER, (sal->>'deduct')::INTEGER, 0),
        COALESCE((sal->>'net_salary')::INTEGER, (sal->>'net')::INTEGER, 0),
        COALESCE(sal->>'status', 'معلق'),
        COALESCE((sal->>'issued_at')::TIMESTAMPTZ, NOW())
      )
      ON CONFLICT (employee_id, month_iso) DO UPDATE SET
        month_label = EXCLUDED.month_label,
        base_salary = EXCLUDED.base_salary,
        attend_days = EXCLUDED.attend_days,
        late_minutes = EXCLUDED.late_minutes,
        late_deduct = EXCLUDED.late_deduct,
        absent_days = EXCLUDED.absent_days,
        overtime_amount = EXCLUDED.overtime_amount,
        bonus = EXCLUDED.bonus,
        total_deduct = EXCLUDED.total_deduct,
        net_salary = EXCLUDED.net_salary,
        status = EXCLUDED.status,
        issued_at = COALESCE(EXCLUDED.issued_at, salary_records.issued_at),
        company_id = cid;
      cnt_sal := cnt_sal + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'leaves' AND jsonb_typeof(p_payload->'leaves') = 'array' THEN
    FOR lev IN SELECT * FROM jsonb_array_elements(p_payload->'leaves')
    LOOP
      IF COALESCE((lev->>'employee_id')::INTEGER, (lev->>'emp_id')::INTEGER) IS NULL THEN CONTINUE; END IF;
      INSERT INTO leaves (
        leave_ref, employee_id, company_id, leave_type, from_date, to_date, multiplier, note
      ) VALUES (
        NULLIF(trim(lev->>'leave_ref'), ''),
        COALESCE((lev->>'employee_id')::INTEGER, (lev->>'emp_id')::INTEGER),
        cid,
        COALESCE(NULLIF(trim(lev->>'leave_type'), ''), NULLIF(trim(lev->>'type'), ''), 'paid_single'),
        COALESCE((lev->>'from_date')::DATE, (lev->>'fromDate')::DATE, CURRENT_DATE),
        NULLIF(trim(COALESCE(lev->>'to_date', lev->>'toDate', '')), '')::DATE,
        GREATEST(1, COALESCE((lev->>'multiplier')::INTEGER, 1)),
        COALESCE(lev->>'note', lev->>'reason', '')
      )
      ON CONFLICT (leave_ref) DO UPDATE SET
        employee_id = EXCLUDED.employee_id,
        company_id = cid,
        leave_type = EXCLUDED.leave_type,
        from_date = EXCLUDED.from_date,
        to_date = EXCLUDED.to_date,
        multiplier = EXCLUDED.multiplier,
        note = EXCLUDED.note,
        updated_at = NOW()
      WHERE leaves.leave_ref IS NOT NULL;
      cnt_lev := cnt_lev + 1;
    END LOOP;
  END IF;

  PERFORM saas_v3_write_audit(
    audit_action, 'backup',
    'Full import: settings=' || cnt_settings::text || ' emp=' || cnt_emp::text,
    'company:' || cid::TEXT, cid,
    NULL,
    jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept,
      'super_admin', is_super AND audit_action = 'super_company_import'
    ),
    'company', cid::TEXT, NULL, NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'imported', jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept
    )
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_import_company_full(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_import_company_full(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_import_company_full(JSONB) IS
  'Full company import — schema-aligned with export (064); super admin uses payload.company_id';
