-- ============================================================
-- 012 — عدم مسح بصمة/IP عند إعادة نشر QR بنفس token
-- شغّل بعد 011
-- ============================================================

DROP FUNCTION IF EXISTS saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB);

CREATE OR REPLACE FUNCTION saas_publish_employee_qr(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_token TEXT,
  p_label TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  e RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
  prev RECORD;
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT id, name, dept, company_id INTO e
  FROM employees WHERE id = p_employee_id LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  SELECT token, fingerprint, ip, linked_at, token_used_at, last_login
  INTO prev
  FROM employee_devices
  WHERE employee_id = p_employee_id AND slot = p_slot
  LIMIT 1;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id,
    fingerprint, ip, linked_at, token_used_at, last_login, device_info
  ) VALUES (
    p_employee_id, p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok, NOW(), COALESCE(e.company_id, 1),
    '', '', NULL, NULL, NULL, '{}'::jsonb
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, NOW()),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = COALESCE(employee_devices.company_id, EXCLUDED.company_id),
    fingerprint = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN ''
      ELSE COALESCE(employee_devices.fingerprint, '')
    END,
    ip = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN ''
      ELSE COALESCE(employee_devices.ip, '')
    END,
    linked_at = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.linked_at
    END,
    token_used_at = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.token_used_at
    END,
    last_login = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.last_login
    END,
    device_info = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN '{}'::jsonb
      ELSE COALESCE(employee_devices.device_info, '{}'::jsonb)
    END;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', e.id,
    'emp_name', e.name,
    'dept', e.dept,
    'company_id', e.company_id,
    'slot', p_slot,
    'token', tok,
    'barcode', 'ATT-' || e.id::text || '-D' || p_slot::text,
    'preserved_link', prev IS NOT NULL AND prev.token IS NOT NULL AND prev.token = tok
      AND COALESCE(prev.fingerprint, '') <> ''
  );
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ربط الجهاز بالـ token أو برقم الموظف + slot
CREATE OR REPLACE FUNCTION saas_link_device_by_token(
  p_token TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_ip TEXT DEFAULT NULL,
  p_device_info JSONB DEFAULT '{}'::jsonb,
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
  now_ts TIMESTAMPTZ := NOW();
  tok TEXT := NULLIF(trim(p_token), '');
  fp TEXT := NULLIF(trim(p_fingerprint), '');
BEGIN
  IF fp IS NULL OR length(fp) < 4 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.name AS emp_name
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;
  ELSIF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.name AS emp_name
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.employee_id = p_employee_id AND ed.slot = p_slot
    LIMIT 1;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF d.fingerprint IS NOT NULL AND d.fingerprint <> '' AND d.fingerprint <> fp THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_already_linked');
  END IF;

  UPDATE employee_devices
  SET
    fingerprint = fp,
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
    'emp_name', d.emp_name,
    'fingerprint', fp,
    'ip', COALESCE(NULLIF(trim(p_ip), ''), d.ip, '')
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;
