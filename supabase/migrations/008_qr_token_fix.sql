-- ============================================================
-- 008 — إصلاح QR: fallback بالموظف/slot + رفع token فوري
-- شغّل بعد 005
-- ============================================================

-- 1) lookup: إن فشل token جرّب employee_id + slot (reg=ATT-X-DY في الرابط)
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

-- 2) رفع token من لوحة الإدارة (قبل مسح QR)
CREATE OR REPLACE FUNCTION saas_upsert_device_token(
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
  cid INTEGER;
  tok TEXT := NULLIF(trim(p_token), '');
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  SELECT company_id INTO cid FROM employees WHERE id = p_employee_id;
  IF cid IS NULL THEN cid := 1; END IF;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id
  ) VALUES (
    p_employee_id,
    p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok,
    NOW(),
    cid
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, EXCLUDED.token_created_at),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = COALESCE(employee_devices.company_id, EXCLUDED.company_id);

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'slot', p_slot,
    'token', tok
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_upsert_device_token(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_device_token(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;
