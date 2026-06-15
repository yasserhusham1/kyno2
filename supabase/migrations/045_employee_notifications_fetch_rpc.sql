-- ============================================================
-- KYNO 045 — Employee finance notifications fetch (device authorized)
-- Syncs bonus/loan/deduction alerts to employee phone without admin JWT
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_notifications(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
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
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
  filtered JSONB;
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

  settings_key := 'company:' || emp.company_id::TEXT || ':employee_notifications';

  SELECT value INTO raw_val
  FROM app_settings
  WHERE key = settings_key
  LIMIT 1;

  IF raw_val IS NULL OR btrim(raw_val) = '' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'employee_id', p_employee_id,
      'company_id', emp.company_id,
      'notifications', '[]'::jsonb
    );
  END IF;

  BEGIN
    arr := raw_val::jsonb;
    IF jsonb_typeof(arr) = 'string' THEN
      arr := (arr #>> '{}')::jsonb;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    arr := '[]'::jsonb;
  END;

  IF jsonb_typeof(arr) IS DISTINCT FROM 'array' THEN
    arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(
    jsonb_agg(elem ORDER BY (elem->>'ts') DESC NULLS LAST),
    '[]'::jsonb
  )
  INTO filtered
  FROM (
    SELECT elem
    FROM jsonb_array_elements(arr) elem
    WHERE COALESCE((elem->>'empId')::INTEGER, (elem->>'emp_id')::INTEGER, 0) = p_employee_id
      AND (
        elem->>'companyId' IS NULL
        OR (elem->>'companyId')::INTEGER = emp.company_id
      )
    LIMIT lim
  ) sub;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'notifications', COALESCE(filtered, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;
