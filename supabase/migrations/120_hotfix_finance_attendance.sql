-- 120 — إصلاح جذري: finance_items + حضور/انصراف (updated_at, admin_reason, RPC)

ALTER TABLE attendance ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE attendance ADD COLUMN IF NOT EXISTS admin_reason TEXT;

-- جلب الخصومات بدون فشل assert_tenant (قراءة فقط)
CREATE OR REPLACE FUNCTION saas_get_tenant_finance_items()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  raw TEXT;
  items JSONB := '[]'::jsonb;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = ('company:' || cid::text || ':finance_items')
  LIMIT 1;

  IF raw IS NOT NULL AND trim(raw) <> '' THEN
    BEGIN
      items := raw::jsonb;
    EXCEPTION WHEN others THEN
      items := '[]'::jsonb;
    END;
  END IF;

  IF jsonb_typeof(items) <> 'array' THEN
    items := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'count', jsonb_array_length(items),
    'items', items
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_tenant_finance_items() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_tenant_finance_items() TO authenticated;

-- إصلاح saas_upsert_attendance_by_device — updated_at + alt fingerprint (116)
CREATE OR REPLACE FUNCTION saas_upsert_attendance_by_device(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_date_iso TEXT DEFAULT NULL,
  p_date_label TEXT DEFAULT NULL,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_hours TEXT DEFAULT NULL,
  p_late TEXT DEFAULT NULL,
  p_overtime TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL,
  p_days INTEGER DEFAULT NULL,
  p_late_min INTEGER DEFAULT NULL,
  p_punch_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  co_id INTEGER;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  punch TEXT := lower(trim(COALESCE(p_punch_type, '')));
  dev_ok BOOLEAN := FALSE;
  active_chk JSONB;
  rate_chk JSONB;
  srv_ts TIMESTAMPTZ;
  srv_date DATE;
  srv_ci TEXT;
  use_date_iso DATE;
  use_date_label TEXT;
  use_ci TEXT;
  use_co TEXT;
  use_hours TEXT;
  use_late TEXT;
  use_ot TEXT;
  use_status TEXT;
  existing RECORD;
  actual_min INTEGER;
  official_min INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ci_min INTEGER;
  co_min INTEGER;
  official_co_min INTEGER;
  ot_min INTEGER;
  att_row attendance%ROWTYPE;
  att_id INTEGER;
  overnight_open BOOLEAN := FALSE;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF punch IN ('check_in', 'check_out') THEN
    rate_chk := saas_check_api_rate_limit(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'nodevice'),
      NULL,
      120,
      3600
    );
    IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'rate_limited',
        'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 3600)
      );
    END IF;
    PERFORM saas_record_api_attempt(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'nodevice'),
      NULL
    );
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.active IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'employee_suspended',
      'message', 'تم إيقاف حسابك، يرجى مراجعة الإدارة.'
    );
  END IF;

  co_id := emp.company_id;

  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  srv_ts := basma_server_now_baghdad();
  srv_date := basma_date_iso_baghdad();

  IF punch IN ('check_in', 'check_out')
     AND saas_v3_official_closure_covers_date(co_id, srv_date) THEN
    overnight_open := FALSE;
    IF punch = 'check_out'
       AND saas_v3_is_overnight_shift(emp.check_in, emp.check_out)
       AND basma_time_text_to_minutes(basma_format_time_ampm(srv_ts))
           <= basma_db_time_to_minutes(emp.check_in) THEN
      SELECT EXISTS (
        SELECT 1 FROM attendance a
        WHERE a.employee_id = p_employee_id
          AND a.date_iso = srv_date
          AND a.check_in IS NOT NULL AND a.check_in <> '—'
          AND (a.check_out IS NULL OR a.check_out = '—')
      ) INTO overnight_open;
    END IF;
    IF NOT overnight_open THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'official_closure_active',
        'date_iso', srv_date
      );
    END IF;
  END IF;

  IF fp IS NOT NULL THEN
    dev_ok := saas_v3_employee_device_authorized(p_employee_id, fp);
  END IF;
  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF punch = 'check_in' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(use_date_iso);
    srv_ci := basma_format_time_ampm(srv_ts);
    use_ci := srv_ci;
    use_co := '—';
    use_hours := '—';
    use_late := '—';
    use_ot := '—';
    use_status := 'طبيعي';
    actual_min := basma_time_text_to_minutes(srv_ci);
    official_min := basma_db_time_to_minutes(emp.check_in);
    late_min := GREATEST(0, actual_min - official_min);
    IF late_min > late_threshold THEN
      use_status := 'متأخر';
      use_late := late_min || 'د';
    ELSIF late_min > 0 THEN
      use_late := late_min || 'د';
    END IF;
  ELSIF punch = 'check_out' THEN
    IF saas_v3_is_overnight_shift(emp.check_in, emp.check_out)
       AND basma_time_text_to_minutes(basma_format_time_ampm(srv_ts))
           <= basma_db_time_to_minutes(emp.check_in) THEN
      use_date_iso := srv_date - 1;
    ELSE
      use_date_iso := srv_date;
    END IF;
    use_date_label := basma_arabic_date_label(use_date_iso);
    SELECT a.check_in, a.check_out, a.status, a.late INTO existing
    FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = use_date_iso
    LIMIT 1;
    use_ci := COALESCE(existing.check_in, '—');
    use_co := basma_format_time_ampm(srv_ts);
    ci_min := basma_time_text_to_minutes(use_ci);
    co_min := basma_time_text_to_minutes(use_co);
    official_co_min := basma_db_time_to_minutes(emp.check_out);
    use_hours := '—';
    use_late := COALESCE(existing.late, '—');
    use_ot := '—';
    use_status := COALESCE(existing.status, 'طبيعي');
    IF use_ci <> '—' AND use_co <> '—' AND co_min >= ci_min THEN
      use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ot_min := GREATEST(0, co_min - official_co_min);
      IF ot_min > 0 THEN
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN use_status := 'إضافي'; END IF;
      END IF;
    END IF;
  ELSE
    use_date_iso := COALESCE(NULLIF(trim(p_date_iso), '')::date, srv_date);
    use_date_label := COALESCE(NULLIF(trim(p_date_label), ''), basma_arabic_date_label(use_date_iso));
    use_ci := COALESCE(NULLIF(trim(p_check_in), ''), '—');
    use_co := COALESCE(NULLIF(trim(p_check_out), ''), '—');
    use_hours := COALESCE(NULLIF(trim(p_hours), ''), '—');
    use_late := COALESCE(NULLIF(trim(p_late), ''), '—');
    use_ot := COALESCE(NULLIF(trim(p_overtime), ''), '—');
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  END IF;

  IF punch IN ('check_in', 'check_out')
     AND saas_v3_official_closure_covers_date(co_id, use_date_iso) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'official_closure_active',
      'date_iso', use_date_iso
    );
  END IF;

  INSERT INTO attendance (
    employee_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status, company_id, updated_at
  ) VALUES (
    p_employee_id,
    COALESCE(NULLIF(trim(p_emp_name), ''), emp.name),
    COALESCE(NULLIF(trim(p_dept), ''), emp.dept),
    use_date_label,
    use_date_iso,
    use_ci,
    use_co,
    use_hours,
    use_late,
    use_ot,
    use_status,
    co_id,
    NOW()
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = COALESCE(EXCLUDED.check_in, attendance.check_in),
    check_out = COALESCE(EXCLUDED.check_out, attendance.check_out),
    hours = COALESCE(EXCLUDED.hours, attendance.hours),
    late = COALESCE(EXCLUDED.late, attendance.late),
    overtime = COALESCE(EXCLUDED.overtime, attendance.overtime),
    status = COALESCE(EXCLUDED.status, attendance.status),
    company_id = EXCLUDED.company_id,
    updated_at = NOW()
  RETURNING * INTO att_row;

  att_id := att_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'id', att_id,
    'attendance_id', att_id,
    'employee_id', p_employee_id,
    'check_in', COALESCE(att_row.check_in, '—'),
    'check_out', COALESCE(att_row.check_out, '—'),
    'date_iso', att_row.date_iso,
    'date_label', att_row.date_label,
    'hours', COALESCE(att_row.hours, '—'),
    'late', COALESCE(att_row.late, '—'),
    'overtime', COALESCE(att_row.overtime, '—'),
    'status', COALESCE(att_row.status, 'طبيعي'),
    'server_authoritative', punch IN ('check_in', 'check_out')
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT
) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
