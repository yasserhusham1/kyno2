-- ============================================================
-- KYNO 048 — Employee client profile includes company GPS + login fix
-- Allows employee phones (device-authorized) to fetch GPS settings for check-in
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_client_profile(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
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
  gps_prefix TEXT;
  v_lat TEXT;
  v_lng TEXT;
  v_range TEXT;
  v_name TEXT;
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

  IF emp.company_id IS NOT NULL THEN
    gps_prefix := 'company:' || emp.company_id::text || ':';
    SELECT value INTO v_lat FROM app_settings WHERE key = gps_prefix || 'gps_lat' LIMIT 1;
    SELECT value INTO v_lng FROM app_settings WHERE key = gps_prefix || 'gps_lng' LIMIT 1;
    SELECT value INTO v_range FROM app_settings WHERE key = gps_prefix || 'gps_range' LIMIT 1;
    SELECT value INTO v_name FROM app_settings WHERE key = gps_prefix || 'gps_name' LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE,
    'avatar_url', emp.avatar_url,
    'gps_lat', NULLIF(trim(v_lat), ''),
    'gps_lng', NULLIF(trim(v_lng), ''),
    'gps_range', NULLIF(trim(v_range), ''),
    'gps_name', NULLIF(trim(v_name), '')
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) TO anon, authenticated;
