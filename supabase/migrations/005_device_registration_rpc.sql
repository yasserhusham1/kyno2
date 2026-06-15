-- ============================================================
-- 005 — تسجيل جهاز الموظف عبر QR بدون JWT (anon-safe RPC)
-- شغّل بعد 004 — يُحدَّث بالكامل في 008_qr_token_fix.sql
-- ============================================================

CREATE OR REPLACE FUNCTION saas_lookup_device_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
BEGIN
  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', d.token,
        'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''),
        'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text
      );
    END IF;
  END IF;

  IF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.employee_id = p_employee_id AND ed.slot = p_slot
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', COALESCE(d.token, tok),
        'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''),
        'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text
      );
    END IF;

    SELECT e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employees e
    WHERE e.id = p_employee_id
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', p_slot,
        'label', 'الهاتف ' || p_slot::text,
        'token', tok,
        'pin', NULL,
        'fingerprint', '',
        'ip', '',
        'barcode', 'ATT-' || d.emp_id::text || '-D' || p_slot::text
      );
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION saas_link_device_by_token(
  p_token TEXT,
  p_fingerprint TEXT,
  p_ip TEXT DEFAULT NULL,
  p_device_info JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  now_ts TIMESTAMPTZ := NOW();
BEGIN
  IF p_token IS NULL OR length(trim(p_token)) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;
  IF p_fingerprint IS NULL OR length(trim(p_fingerprint)) < 4 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  SELECT ed.*, e.name AS emp_name
  INTO d
  FROM employee_devices ed
  JOIN employees e ON e.id = ed.employee_id
  WHERE ed.token = trim(p_token)
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF d.fingerprint IS NOT NULL AND d.fingerprint <> '' AND d.fingerprint <> trim(p_fingerprint) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_already_linked');
  END IF;

  UPDATE employee_devices
  SET
    fingerprint = trim(p_fingerprint),
    ip = COALESCE(NULLIF(trim(p_ip), ''), ip),
    device_info = COALESCE(p_device_info, device_info, '{}'::jsonb),
    linked_at = COALESCE(linked_at, now_ts),
    token_used_at = now_ts,
    last_login = now_ts
  WHERE id = d.id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
