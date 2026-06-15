-- ============================================================
-- 011 — حل جذري QR: نشر من الإدارة + حلّ ذاتي على الهاتف
-- شغّل مرة واحدة بعد 008/010
-- ============================================================

-- ── 1) الإدارة: نشر QR (موظف + أجهزة + token) في عملية واحدة ──
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
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT id, name, dept, company_id INTO e
  FROM employees WHERE id = p_employee_id LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

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
    fingerprint = '',
    ip = '',
    linked_at = NULL,
    token_used_at = NULL,
    last_login = NULL,
    device_info = '{}'::jsonb;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', e.id,
    'emp_name', e.name,
    'dept', e.dept,
    'company_id', e.company_id,
    'slot', p_slot,
    'token', tok,
    'barcode', 'ATT-' || e.id::text || '-D' || p_slot::text
  );
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ── 2) الهاتف: بحث + إصلاح ذاتي إن وُجد الموظف ولم يُرفع token ──
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
  -- أ) بحث بالـ token
  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, emp.id AS emp_id, emp.name AS emp_name, emp.dept, emp.company_id
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
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text
      );
    END IF;
  END IF;

  -- ب) بحث برقم الموظف + slot
  IF p_employee_id IS NOT NULL AND sl IS NOT NULL THEN
    SELECT id, name, dept, company_id INTO e
    FROM employees WHERE id = p_employee_id LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
    END IF;

    SELECT ed.* INTO d
    FROM employee_devices ed
    WHERE ed.employee_id = p_employee_id AND ed.slot = sl
    LIMIT 1;

    IF FOUND THEN
      -- إصلاح ذاتي: token في الرابط ≠ DB → حدّث token وامسح بصمة قديمة
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
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text
      );
    END IF;

    -- ج) الموظف موجود لكن لا صف جهاز → أنشئه (إصلاح ذاتي)
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
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text
      );
    END IF;

    RETURN jsonb_build_object(
      'ok', true, 'source', 'employee_only',
      'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
      'company_id', e.company_id, 'slot', sl,
      'label', 'الهاتف ' || sl::text,
      'token', tok, 'pin', NULL,
      'fingerprint', '', 'ip', '',
      'barcode', 'ATT-' || e.id::text || '-D' || sl::text
    );
  END IF;

  IF tok IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'token_not_found');
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_qr');
END;
$$;

-- ── 3) تحديث lookup القديم ليستخدم نفس المنطق ──
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
DECLARE r JSONB;
BEGIN
  r := saas_resolve_qr_registration(p_token, p_employee_id, p_slot);
  IF r IS NULL OR (r->>'ok')::boolean IS NOT TRUE THEN
    RETURN NULL;
  END IF;
  RETURN r - 'ok' - 'source' - 'error';
END;
$$;

REVOKE ALL ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;
