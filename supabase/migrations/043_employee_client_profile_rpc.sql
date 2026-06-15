-- ============================================================
-- KYNO 043 — Employee client profile (remote_attend / open_hours)
-- Allows employee phones (anon) to fetch authoritative flags from DB
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

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) TO anon, authenticated;

-- Include flags in QR resolve (phone registration path)
CREATE OR REPLACE FUNCTION saas_resolve_qr_registration(
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
  e RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
  sl SMALLINT := p_slot;
BEGIN
  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, emp.id AS emp_id, emp.name AS emp_name, emp.dept, emp.company_id,
           emp.open_hours, emp.remote_attend, emp.check_in, emp.check_out
    INTO d
    FROM employee_devices ed
    JOIN employees emp ON emp.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'ok', true, 'source', 'token',
        'employee_id', d.emp_id, 'emp_name', d.emp_name, 'dept', d.dept,
        'company_id', d.company_id, 'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', d.token, 'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text,
        'open_hours', d.open_hours IS TRUE,
        'remote_attend', d.remote_attend IS TRUE,
        'check_in', d.check_in,
        'check_out', d.check_out
      );
    END IF;
  END IF;

  IF p_employee_id IS NOT NULL AND sl IS NOT NULL THEN
    SELECT id, name, dept, company_id, open_hours, remote_attend, check_in, check_out INTO e
    FROM employees WHERE id = p_employee_id LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
    END IF;

    SELECT ed.* INTO d
    FROM employee_devices ed
    WHERE ed.employee_id = p_employee_id AND ed.slot = sl
    LIMIT 1;

    IF FOUND THEN
      IF tok IS NOT NULL AND length(tok) >= 10 AND (d.token IS NULL OR d.token <> tok) THEN
        UPDATE employee_devices SET
          token = tok,
          token_created_at = COALESCE(token_created_at, NOW()),
          fingerprint = '', ip = '',
          linked_at = NULL, token_used_at = NULL, last_login = NULL
        WHERE id = d.id;
        d.token := tok;
        d.fingerprint := '';
      END IF;

      RETURN jsonb_build_object(
        'ok', true, 'source', 'employee_slot',
        'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
        'company_id', e.company_id, 'slot', sl,
        'label', COALESCE(d.label, 'الهاتف ' || sl::text),
        'token', COALESCE(d.token, tok), 'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text,
        'open_hours', e.open_hours IS TRUE,
        'remote_attend', e.remote_attend IS TRUE,
        'check_in', e.check_in,
        'check_out', e.check_out
      );
    END IF;

    IF tok IS NOT NULL AND length(tok) >= 10 THEN
      INSERT INTO employee_devices (
        employee_id, slot, label, token, token_created_at, company_id,
        fingerprint, ip, device_info
      ) VALUES (
        p_employee_id, sl, 'الهاتف ' || sl::text, tok, NOW(), COALESCE(e.company_id, 1),
        '', '', '{}'::jsonb
      )
      ON CONFLICT (employee_id, slot) DO UPDATE SET
        token = EXCLUDED.token,
        fingerprint = '', ip = '';

      RETURN jsonb_build_object(
        'ok', true, 'source', 'auto_created',
        'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
        'company_id', e.company_id, 'slot', sl,
        'label', 'الهاتف ' || sl::text,
        'token', tok, 'pin', NULL,
        'fingerprint', '', 'ip', '',
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text,
        'open_hours', e.open_hours IS TRUE,
        'remote_attend', e.remote_attend IS TRUE,
        'check_in', e.check_in,
        'check_out', e.check_out
      );
    END IF;

    RETURN jsonb_build_object(
      'ok', true, 'source', 'employee_only',
      'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
      'company_id', e.company_id, 'slot', sl,
      'label', 'الهاتف ' || sl::text,
      'token', tok, 'pin', NULL,
      'fingerprint', '', 'ip', '',
      'barcode', 'ATT-' || e.id::text || '-D' || sl::text,
      'open_hours', e.open_hours IS TRUE,
      'remote_attend', e.remote_attend IS TRUE,
      'check_in', e.check_in,
      'check_out', e.check_out
    );
  END IF;

  IF tok IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'token_not_found');
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_qr');
END;
$$;

REVOKE ALL ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;
