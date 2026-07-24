-- 098 — تثبيت بصمة جهاز الموظف والسماح بإعادة ربط نفس الخانة بالرابط السري
-- يعالج الأجهزة التي ارتبطت ببصمة مؤقتة بسبب عدم حفظ basma_device_fp في المتصفح.

CREATE OR REPLACE FUNCTION public.saas_link_device_by_token(
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
  other_dev RECORD;
  now_ts TIMESTAMPTZ := NOW();
  tok TEXT := NULLIF(trim(p_token), '');
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  v_ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  rate_chk JSONB;
  active_chk JSONB;
  co_id INTEGER;
BEGIN
  IF fp IS NULL OR length(fp) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  rate_chk := saas_check_api_rate_limit('device_link', fp, v_ip, 10, 900);
  IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'rate_limited',
      'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 900)
    );
  END IF;
  PERFORM saas_record_api_attempt('device_link', fp, v_ip);

  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;
  ELSIF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
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

  co_id := d.emp_company_id;
  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  SELECT ed.employee_id, ed.slot
  INTO other_dev
  FROM employee_devices ed
  WHERE ed.fingerprint = fp
    AND NOT (ed.employee_id = d.employee_id AND ed.slot = d.slot)
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'fingerprint_already_used',
      'employee_id', other_dev.employee_id,
      'slot', other_dev.slot
    );
  END IF;

  -- إذا كان الربط بالرابط السري token نسمح بتحديث بصمة نفس الخانة،
  -- لأن بعض الأجهزة القديمة ارتبطت ببصمة مؤقتة لم تُحفظ في المتصفح.
  IF tok IS NULL AND d.fingerprint IS NOT NULL AND d.fingerprint <> '' AND d.fingerprint <> fp THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_already_linked');
  END IF;

  UPDATE employee_devices
  SET
    fingerprint = fp,
    ip = COALESCE(v_ip, employee_devices.ip),
    device_info = COALESCE(p_device_info, employee_devices.device_info, '{}'::jsonb),
    linked_at = COALESCE(employee_devices.linked_at, now_ts),
    token_used_at = now_ts,
    last_login = now_ts
  WHERE id = d.id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name,
    'fingerprint', fp,
    'ip', COALESCE(v_ip, d.ip, '')
  );
END;
$$;

REVOKE ALL ON FUNCTION public.saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
