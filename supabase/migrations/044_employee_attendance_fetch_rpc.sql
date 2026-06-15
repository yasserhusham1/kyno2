-- ============================================================
-- KYNO 044 — Employee attendance fetch (anon/device authorized)
-- Keeps employee phone in sync after admin deletes attendance rows
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_attendance(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'employee_id', a.employee_id,
        'emp_name', a.emp_name,
        'dept', a.dept,
        'date_label', a.date_label,
        'date_iso', a.date_iso,
        'check_in', a.check_in,
        'check_out', a.check_out,
        'hours', a.hours,
        'late', a.late,
        'overtime', a.overtime,
        'status', a.status,
        'company_id', a.company_id
      )
      ORDER BY a.date_iso DESC
    ),
    '[]'::jsonb
  )
  INTO rows
  FROM (
    SELECT *
    FROM attendance att
    WHERE att.employee_id = p_employee_id
    ORDER BY att.date_iso DESC
    LIMIT lim
  ) a;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'records', rows
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_attendance(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_attendance(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;
