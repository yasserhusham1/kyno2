-- ============================================================
-- KYNO 062 — Super Admin Backup Center import fix
-- saas_import_company_full used auth_company_id() only → no_company_context for super_admin
-- Super admin: company_id from backup payload (export from saas_super_export_company)
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
      INSERT INTO departments (company_id, name, created_at, updated_at)
      VALUES (cid, COALESCE(dept->>'name', dept->>'dept', 'قسم'), NOW(), NOW())
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
        id, company_id, name, dept, role, phone, salary, salary_type,
        daily_rate, check_in, check_out, remote_attend, open_hours,
        include_overtime_in_salary, updated_at
      ) VALUES (
        eid, cid,
        COALESCE(emp->>'name', ''),
        COALESCE(emp->>'dept', ''),
        COALESCE(emp->>'role', ''),
        COALESCE(emp->>'phone', '—'),
        COALESCE((emp->>'salary')::INTEGER, 0),
        COALESCE(emp->>'salary_type', emp->>'salaryType', 'monthly'),
        COALESCE((emp->>'daily_rate')::INTEGER, (emp->>'dailyRate')::INTEGER, 0),
        COALESCE(emp->>'check_in', emp->>'checkIn', '08:00'),
        COALESCE(emp->>'check_out', emp->>'checkOut', '17:00'),
        COALESCE((emp->>'remote_attend')::BOOLEAN, (emp->>'remoteAttend')::BOOLEAN, false),
        COALESCE((emp->>'open_hours')::BOOLEAN, (emp->>'openHours')::BOOLEAN, false),
        COALESCE((emp->>'include_overtime_in_salary')::BOOLEAN, (emp->>'includeOvertimeInSalary')::BOOLEAN, false),
        NOW()
      )
      ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, dept = EXCLUDED.dept, role = EXCLUDED.role,
        phone = EXCLUDED.phone, salary = EXCLUDED.salary, salary_type = EXCLUDED.salary_type,
        daily_rate = EXCLUDED.daily_rate, check_in = EXCLUDED.check_in, check_out = EXCLUDED.check_out,
        remote_attend = EXCLUDED.remote_attend, open_hours = EXCLUDED.open_hours,
        include_overtime_in_salary = EXCLUDED.include_overtime_in_salary,
        company_id = cid,
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
        check_in, check_out, hours, late, overtime, status, updated_at
      ) VALUES (
        (att->>'employee_id')::INTEGER, cid,
        COALESCE(att->>'emp_name', att->>'emp', ''),
        COALESCE(att->>'dept', ''),
        COALESCE(att->>'date_label', att->>'date', ''),
        COALESCE(att->>'date_iso', att->>'dateIso', CURRENT_DATE::text),
        COALESCE(att->>'check_in', att->>'ci', '—'),
        COALESCE(att->>'check_out', att->>'co', '—'),
        COALESCE(att->>'hours', att->>'hrs', '—'),
        COALESCE(att->>'late', '—'),
        COALESCE(att->>'overtime', att->>'ot', '—'),
        COALESCE(att->>'status', 'طبيعي'),
        NOW()
      )
      ON CONFLICT DO NOTHING;
      cnt_att := cnt_att + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'salary_records' AND jsonb_typeof(p_payload->'salary_records') = 'array' THEN
    FOR sal IN SELECT * FROM jsonb_array_elements(p_payload->'salary_records')
    LOOP
      IF (sal->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO salary_records (
        employee_id, company_id, month_iso, month_label, base_salary,
        overtime, deductions, net_salary, status, updated_at
      ) VALUES (
        (sal->>'employee_id')::INTEGER, cid,
        COALESCE(sal->>'month_iso', sal->>'monthIso', ''),
        COALESCE(sal->>'month_label', sal->>'month', ''),
        COALESCE((sal->>'base_salary')::INTEGER, (sal->>'base')::INTEGER, 0),
        COALESCE((sal->>'overtime')::INTEGER, (sal->>'ot')::INTEGER, 0),
        COALESCE((sal->>'deductions')::INTEGER, (sal->>'deduct')::INTEGER, 0),
        COALESCE((sal->>'net_salary')::INTEGER, (sal->>'net')::INTEGER, 0),
        COALESCE(sal->>'status', 'معلق'),
        NOW()
      )
      ON CONFLICT DO NOTHING;
      cnt_sal := cnt_sal + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'leaves' AND jsonb_typeof(p_payload->'leaves') = 'array' THEN
    FOR lev IN SELECT * FROM jsonb_array_elements(p_payload->'leaves')
    LOOP
      IF (lev->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO leaves (
        employee_id, company_id, leave_type, from_date, to_date,
        days, status, reason, updated_at
      ) VALUES (
        (lev->>'employee_id')::INTEGER, cid,
        COALESCE(lev->>'leave_type', lev->>'type', 'annual'),
        COALESCE((lev->>'from_date')::DATE, (lev->>'fromDate')::DATE, CURRENT_DATE),
        COALESCE((lev->>'to_date')::DATE, (lev->>'toDate')::DATE, CURRENT_DATE),
        COALESCE((lev->>'days')::INTEGER, 1),
        COALESCE(lev->>'status', 'pending'),
        COALESCE(lev->>'reason', ''),
        NOW()
      )
      ON CONFLICT DO NOTHING;
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
END;
$$;

REVOKE ALL ON FUNCTION saas_import_company_full(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_import_company_full(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_import_company_full(JSONB) IS
  'Full company import — tenant admin uses JWT company_id; super admin uses payload.company_id';
