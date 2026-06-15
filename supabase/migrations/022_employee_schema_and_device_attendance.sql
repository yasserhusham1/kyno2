-- ============================================================
-- KYNO 022 — أعمدة الموظف + حضور من الهاتف بدون JWT
-- ============================================================

ALTER TABLE employees ADD COLUMN IF NOT EXISTS open_hours BOOLEAN DEFAULT FALSE;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS remote_attend BOOLEAN DEFAULT FALSE;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS sal_deleted_period TEXT DEFAULT '';

UPDATE employees SET open_hours = FALSE WHERE open_hours IS NULL;
UPDATE employees SET remote_attend = FALSE WHERE remote_attend IS NULL;
UPDATE employees SET sal_deleted_period = '' WHERE sal_deleted_period IS NULL;

-- حفظ حضور/تحديث إحصائيات الموظف من بوابة الهاتف (anon — بدون JWT)
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
  p_late_min INTEGER DEFAULT NULL
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
BEGIN
  IF p_employee_id IS NULL OR p_date_iso IS NULL OR length(trim(p_date_iso)) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  co_id := emp.company_id;

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

  IF NULLIF(trim(p_check_in), '') IS NULL
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
    COALESCE(NULLIF(trim(p_date_label), ''), p_date_iso),
    p_date_iso,
    NULLIF(trim(p_check_in), ''),
    NULLIF(trim(p_check_out), ''),
    NULLIF(trim(p_hours), ''),
    NULLIF(trim(p_late), ''),
    NULLIF(trim(p_overtime), ''),
    COALESCE(NULLIF(trim(p_status), ''), 'طبيعي'),
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
    company_id = EXCLUDED.company_id
  RETURNING id INTO att_id;

  RETURN jsonb_build_object('ok', true, 'attendance_id', att_id, 'employee_id', p_employee_id);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER
) TO anon, authenticated;
