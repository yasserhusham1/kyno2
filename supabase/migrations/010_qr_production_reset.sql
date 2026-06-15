-- ============================================================
-- 010 — QR إنتاجي: إعادة ضبط الجهاز عند إصدار token جديد
-- (مهم بعد حذف موظف وإضافة آخر على نفس الهاتف)
-- شغّل بعد 008
-- ============================================================

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
    employee_id, slot, label, token, token_created_at, company_id,
    fingerprint, ip, linked_at, token_used_at, last_login
  ) VALUES (
    p_employee_id,
    p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok,
    NOW(),
    cid,
    '', '', NULL, NULL, NULL
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
    'employee_id', p_employee_id,
    'slot', p_slot,
    'token', tok
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_device_token(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_device_token(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;
