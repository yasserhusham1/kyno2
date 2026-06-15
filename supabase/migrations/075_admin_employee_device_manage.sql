-- 075: Admin — edit/clear employee device fingerprint (cloud, not browser-only)

CREATE OR REPLACE FUNCTION saas_admin_manage_employee_device(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_fingerprint TEXT DEFAULT NULL,
  p_clear_link BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
  after_row JSONB;
  dev_id INTEGER;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 OR p_slot IS NULL OR p_slot NOT IN (1, 2) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT to_jsonb(d.*) INTO before_row
  FROM employee_devices d
  WHERE d.employee_id = p_employee_id AND d.slot = p_slot
  LIMIT 1;

  IF before_row IS NULL THEN
    INSERT INTO employee_devices (
      employee_id, company_id, slot, label, ip, fingerprint, pin, device_info
    ) VALUES (
      p_employee_id,
      emp.company_id,
      p_slot,
      'الهاتف ' || p_slot::text,
      '',
      CASE WHEN COALESCE(p_clear_link, false) THEN '' ELSE COALESCE(fp, '') END,
      '',
      '{}'::jsonb
    )
    RETURNING id INTO dev_id;

    SELECT to_jsonb(d.*) INTO after_row FROM employee_devices d WHERE d.id = dev_id;

    RETURN jsonb_build_object('ok', true, 'data', after_row, 'created', true);
  END IF;

  IF COALESCE(p_clear_link, false) THEN
    UPDATE employee_devices SET
      fingerprint = '',
      ip = '',
      linked_at = NULL,
      token_used_at = NULL,
      last_login = NULL,
      device_info = '{}'::jsonb
    WHERE employee_id = p_employee_id AND slot = p_slot
    RETURNING id INTO dev_id;
  ELSIF fp IS NOT NULL THEN
    UPDATE employee_devices SET
      fingerprint = fp
    WHERE employee_id = p_employee_id AND slot = p_slot
    RETURNING id INTO dev_id;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'nothing_to_update');
  END IF;

  SELECT to_jsonb(d.*) INTO after_row FROM employee_devices d WHERE d.id = dev_id;

  BEGIN
    PERFORM saas_v3_write_audit(
      CASE WHEN COALESCE(p_clear_link, false) THEN 'employee_device_cleared' ELSE 'employee_device_updated' END,
      'devices',
      CASE WHEN COALESCE(p_clear_link, false)
        THEN 'Cleared device slot ' || p_slot::text || ' for employee ' || p_employee_id::text
        ELSE 'Updated fingerprint slot ' || p_slot::text || ' for employee ' || p_employee_id::text
      END,
      emp.name,
      emp.company_id,
      before_row,
      after_row,
      'employee_devices', dev_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'data', after_row);
END;
$$;

REVOKE ALL ON FUNCTION saas_admin_manage_employee_device(INTEGER, SMALLINT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_admin_manage_employee_device(INTEGER, SMALLINT, TEXT, BOOLEAN) TO authenticated, service_role;

COMMENT ON FUNCTION saas_admin_manage_employee_device(INTEGER, SMALLINT, TEXT, BOOLEAN) IS
  'Company admin — update or clear employee device fingerprint (keeps QR token for re-scan)';
