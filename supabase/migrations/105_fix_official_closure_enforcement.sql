-- 105 — إصلاح تعطيل الرابط الرسمي: قراءة الإعدادات للموظف + منع كل مسارات الحضور

-- 1) قراءة قائمة التعطيلات للموظف (بدون JWT — للواجهة)
CREATE OR REPLACE FUNCTION public.saas_get_official_closures_json_for_employee(
  p_employee_id INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  raw TEXT;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT e.id, e.company_id INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND OR emp.company_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  raw := COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'official_closures_json'), ''), '[]');

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', emp.company_id,
    'closures_json', raw
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'official_closure_read_failed');
END;
$$;

REVOKE ALL ON FUNCTION public.saas_get_official_closures_json_for_employee(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saas_get_official_closures_json_for_employee(INTEGER) TO anon, authenticated;

-- 2) فحص العطلة النشطة اليوم — بدون اشتراط الجهاز (القراءة فقط)
CREATE OR REPLACE FUNCTION public.saas_get_active_official_closure_for_employee(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  raw TEXT;
  item JSONB;
  c_start DATE;
  c_end DATE;
  c_pay TEXT;
  today DATE := basma_date_iso_baghdad();
  tmp_date DATE;
  days_count INTEGER;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  raw := COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'official_closures_json'), ''), '[]');

  FOR item IN SELECT * FROM jsonb_array_elements(raw::jsonb) LOOP
    c_start := COALESCE(NULLIF(item->>'startDate', '')::DATE, NULLIF(item->>'start', '')::DATE, NULLIF(item->>'from', '')::DATE);
    c_end := COALESCE(NULLIF(item->>'endDate', '')::DATE, NULLIF(item->>'end', '')::DATE, NULLIF(item->>'to', '')::DATE);
    IF c_start IS NULL THEN
      CONTINUE;
    END IF;
    IF c_end IS NULL THEN
      c_end := c_start + GREATEST(1, COALESCE(NULLIF(item->>'days', '')::INTEGER, 1)) - 1;
    END IF;
    IF c_end < c_start THEN
      tmp_date := c_start; c_start := c_end; c_end := tmp_date;
    END IF;

    IF today >= c_start AND today <= c_end THEN
      c_pay := CASE WHEN lower(COALESCE(item->>'payType', item->>'type', 'paid')) = 'unpaid' THEN 'unpaid' ELSE 'paid' END;
      days_count := GREATEST(1, (c_end - c_start) + 1);
      RETURN jsonb_build_object(
        'ok', true,
        'active', true,
        'closure', jsonb_build_object(
          'id', COALESCE(item->>'id', 'active_official_closure'),
          'title', COALESCE(NULLIF(item->>'title', ''), NULLIF(item->>'name', ''), 'تعطيل رسمي'),
          'startDate', to_char(c_start, 'YYYY-MM-DD'),
          'endDate', to_char(c_end, 'YYYY-MM-DD'),
          'days', days_count,
          'payType', c_pay
        )
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'active', false);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'official_closure_check_failed');
END;
$$;

REVOKE ALL ON FUNCTION public.saas_get_active_official_closure_for_employee(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saas_get_active_official_closure_for_employee(INTEGER, TEXT) TO anon, authenticated;

-- 3) منع الحضور في كل المسارات (punch + legacy row)
DROP FUNCTION IF EXISTS saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER
);
DROP FUNCTION IF EXISTS saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT
);

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
  tenant JSONB;
  active_chk JSONB;
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
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  co_id := emp.company_id;
  tenant := saas_v3_assert_tenant(co_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
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
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'official_closure_active',
      'date_iso', srv_date
    );
  END IF;

  IF emp.remote_attend IS TRUE THEN
    dev_ok := TRUE;
  ELSIF fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO dev_ok;
  END IF;

  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF p_days IS NOT NULL OR p_late_min IS NOT NULL THEN
    UPDATE employees SET
      days = COALESCE(p_days, days),
      late_min = COALESCE(p_late_min, late_min),
      updated_at = NOW()
    WHERE id = p_employee_id;
  END IF;

  srv_ci := basma_format_time_ampm(srv_ts);

  IF punch = 'check_in' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_ci := srv_ci;
    use_co := NULL;
    use_hours := NULL;
    use_ot := '—';

    IF emp.open_hours IS TRUE THEN
      use_late := '—';
      use_status := 'طبيعي';
    ELSE
      actual_min := basma_time_text_to_minutes(srv_ci);
      official_min := basma_db_time_to_minutes(emp.check_in);
      late_min := GREATEST(0, actual_min - official_min);
      IF late_min > late_threshold THEN
        use_status := 'متأخر';
        use_late := late_min || 'د';
      ELSIF late_min > 0 THEN
        use_status := 'طبيعي';
        use_late := late_min || 'د';
      ELSE
        use_status := 'طبيعي';
        use_late := '—';
      END IF;
    END IF;

  ELSIF punch = 'check_out' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_co := basma_format_time_ampm(srv_ts);

    SELECT a.check_in, a.late, a.status INTO existing
    FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = srv_date
    LIMIT 1;

    IF existing.check_in IS NOT NULL AND existing.check_in <> '—' THEN
      use_ci := existing.check_in;
      use_late := COALESCE(NULLIF(trim(existing.late), ''), '—');
      use_status := COALESCE(NULLIF(trim(existing.status), ''), 'طبيعي');
    ELSE
      use_ci := srv_ci;
      use_late := '—';
      use_status := 'طبيعي';
    END IF;

    IF emp.open_hours IS TRUE THEN
      use_hours := '—';
      use_late := '—';
      use_ot := '—';
      use_status := 'طبيعي';
    ELSE
      ci_min := basma_time_text_to_minutes(use_ci);
      co_min := basma_time_text_to_minutes(use_co);
      official_co_min := basma_db_time_to_minutes(emp.check_out);
      IF co_min >= ci_min THEN
        use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ELSE
        use_hours := '0س 0د';
      END IF;
      ot_min := GREATEST(0, co_min - official_co_min);
      IF ot_min > 0 THEN
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN
          use_status := 'إضافي';
        END IF;
      ELSE
        use_ot := '—';
      END IF;
    END IF;

  ELSE
    IF p_date_iso IS NULL OR length(trim(p_date_iso)) < 8 THEN
      IF NULLIF(trim(p_check_in), '') IS NULL
         AND NULLIF(trim(p_check_out), '') IS NULL
         AND NULLIF(trim(p_hours), '') IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    use_date_iso := p_date_iso::date;
    use_date_label := COALESCE(NULLIF(trim(p_date_label), ''), p_date_iso);
    use_ci := NULLIF(trim(p_check_in), '');
    use_co := NULLIF(trim(p_check_out), '');
    use_hours := NULLIF(trim(p_hours), '');
    use_late := NULLIF(trim(p_late), '');
    use_ot := NULLIF(trim(p_overtime), '');
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  END IF;

  IF punch IS NULL
     AND NULLIF(trim(p_check_in), '') IS NULL
     AND NULLIF(trim(p_check_out), '') IS NULL
     AND NULLIF(trim(p_hours), '') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
  END IF;

  IF saas_v3_official_closure_covers_date(co_id, use_date_iso)
     AND (
       punch IN ('check_in', 'check_out')
       OR (NULLIF(trim(COALESCE(use_ci, '')), '') IS NOT NULL AND COALESCE(use_ci, '') <> '—')
       OR (NULLIF(trim(COALESCE(use_co, '')), '') IS NOT NULL AND COALESCE(use_co, '') <> '—')
     ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'official_closure_active',
      'date_iso', use_date_iso
    );
  END IF;

  INSERT INTO attendance (
    employee_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status, company_id
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
    co_id
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
