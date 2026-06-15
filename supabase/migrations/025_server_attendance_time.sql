-- ============================================================
-- KYNO 025 — Server-authoritative attendance punch (device portal)
-- Additive — يحافظ على الوضع القديم عند p_punch_type IS NULL
-- ============================================================

CREATE OR REPLACE FUNCTION basma_server_now_baghdad()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
  SELECT timezone('Asia/Baghdad', now());
$$;

CREATE OR REPLACE FUNCTION basma_date_iso_baghdad()
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
  SELECT (timezone('Asia/Baghdad', now()))::date;
$$;

CREATE OR REPLACE FUNCTION basma_format_time_ampm(ts TIMESTAMPTZ)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT to_char(ts AT TIME ZONE 'Asia/Baghdad', 'HH12:MI AM');
$$;

CREATE OR REPLACE FUNCTION basma_time_text_to_minutes(t TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s TEXT := upper(trim(COALESCE(t, '')));
  m INTEGER := 0;
  h INTEGER := 0;
  ap TEXT;
BEGIN
  IF s = '' OR s = '—' THEN RETURN 0; END IF;
  IF s ~ '^\d{1,2}:\d{2}\s*(AM|PM)$' THEN
    h := substring(s from '^(\d{1,2})')::integer;
    m := substring(s from ':(\d{2})')::integer;
    ap := substring(s from '(AM|PM)$');
    IF ap = 'PM' AND h <> 12 THEN h := h + 12; END IF;
    IF ap = 'AM' AND h = 12 THEN h := 0; END IF;
    RETURN h * 60 + m;
  END IF;
  IF s ~ '^\d{1,2}:\d{2}$' THEN
    h := split_part(s, ':', 1)::integer;
    m := split_part(s, ':', 2)::integer;
    RETURN h * 60 + m;
  END IF;
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION basma_db_time_to_minutes(t TIME)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN t IS NULL THEN 0 ELSE (EXTRACT(HOUR FROM t)::integer * 60 + EXTRACT(MINUTE FROM t)::integer) END;
$$;

CREATE OR REPLACE FUNCTION basma_minutes_to_hours_str(total_min INTEGER)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN total_min IS NULL OR total_min <= 0 THEN '0س 0د'
    ELSE ((total_min / 60)::text || 'س ' || (total_min % 60)::text || 'د')
  END;
$$;

CREATE OR REPLACE FUNCTION basma_arabic_date_label(d DATE)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  days TEXT[] := ARRAY['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'];
  months TEXT[] := ARRAY['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
BEGIN
  IF d IS NULL THEN RETURN ''; END IF;
  RETURN days[EXTRACT(DOW FROM d)::integer + 1] || ' ' || EXTRACT(DAY FROM d)::integer || ' ' || months[EXTRACT(MONTH FROM d)::integer];
END;
$$;

DROP FUNCTION IF EXISTS saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER
);

CREATE OR REPLACE FUNCTION saas_upsert_attendance_by_device(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_date_iso TEXT,
  p_date_label TEXT DEFAULT NULL,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_hours TEXT DEFAULT NULL,
  p_late TEXT DEFAULT NULL,
  p_overtime TEXT DEFAULT NULL,
  p_status TEXT DEFAULT 'طبيعي',
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
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  dev_ok BOOLEAN := FALSE;
  att_id INTEGER;
  co_id INTEGER;
  active_chk JSONB;
  punch TEXT := lower(NULLIF(trim(p_punch_type), ''));
  srv_ts TIMESTAMPTZ;
  srv_date DATE;
  srv_ci TEXT;
  srv_co TEXT;
  srv_late TEXT := '—';
  srv_status TEXT := 'طبيعي';
  srv_hours TEXT;
  use_ci TEXT;
  use_co TEXT;
  use_date_iso DATE;
  use_date_label TEXT;
  use_late TEXT;
  use_ot TEXT;
  use_status TEXT;
  use_hours TEXT;
  actual_min INTEGER;
  official_min INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ci_min INTEGER;
  co_min INTEGER;
  existing RECORD;
  att_row attendance%ROWTYPE;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
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

  IF emp.remote_attend IS TRUE THEN
    dev_ok := TRUE;
  ELSIF fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id
        AND ed.fingerprint = fp
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

  srv_ts := basma_server_now_baghdad();
  srv_date := basma_date_iso_baghdad();
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
      late_threshold := 15;
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

    SELECT a.check_in, a.date_iso INTO existing
    FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = srv_date
    LIMIT 1;

    IF existing.check_in IS NOT NULL AND existing.check_in <> '—' THEN
      use_ci := existing.check_in;
    ELSE
      use_ci := srv_ci;
    END IF;

    IF emp.open_hours IS TRUE THEN
      use_hours := '—';
      use_late := '—';
      use_ot := '—';
      use_status := 'طبيعي';
    ELSE
      ci_min := basma_time_text_to_minutes(use_ci);
      co_min := basma_time_text_to_minutes(use_co);
      IF co_min >= ci_min THEN
        use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ELSE
        use_hours := '0س 0د';
      END IF;
      use_late := COALESCE(NULLIF(trim(p_late), ''), '—');
      use_ot := COALESCE(NULLIF(trim(p_overtime), ''), '—');
      use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
    END IF;

  ELSE
    -- Legacy: accept client-supplied values (admin sync / backward compat)
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
