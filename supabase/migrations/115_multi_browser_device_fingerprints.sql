-- 115 — دعم عدة متصفحات (Safari / Chrome) لنفس جهاز الموظف

ALTER TABLE employee_devices
  ADD COLUMN IF NOT EXISTS alt_fingerprints TEXT[] NOT NULL DEFAULT '{}';

CREATE OR REPLACE FUNCTION saas_device_fingerprint_matches(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM employee_devices ed
    WHERE ed.employee_id = p_employee_id
      AND (p_slot IS NULL OR ed.slot = p_slot)
      AND NULLIF(trim(p_fingerprint), '') IS NOT NULL
      AND (
        ed.fingerprint = NULLIF(trim(p_fingerprint), '')
        OR NULLIF(trim(p_fingerprint), '') = ANY(COALESCE(ed.alt_fingerprints, '{}'))
      )
  );
$$;

CREATE OR REPLACE FUNCTION saas_find_employee_device_by_fingerprint(p_fingerprint TEXT)
RETURNS TABLE (
  employee_id INTEGER,
  slot SMALLINT,
  label TEXT,
  emp_name TEXT,
  dept TEXT,
  company_id INTEGER,
  remote_attend BOOLEAN
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    ed.employee_id,
    ed.slot,
    ed.label,
    e.name AS emp_name,
    e.dept,
    e.company_id,
    COALESCE(e.remote_attend, false) AS remote_attend
  FROM employee_devices ed
  JOIN employees e ON e.id = ed.employee_id
  WHERE NULLIF(trim(p_fingerprint), '') IS NOT NULL
    AND (
      ed.fingerprint = NULLIF(trim(p_fingerprint), '')
      OR NULLIF(trim(p_fingerprint), '') = ANY(COALESCE(ed.alt_fingerprints, '{}'))
    )
  ORDER BY ed.last_login DESC NULLS LAST, ed.linked_at DESC NULLS LAST, ed.id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION saas_v3_employee_portal_authorize(
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
  sub_chk JSONB;
  cid INTEGER;
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

  cid := auth_company_id();
  IF cid IS NOT NULL AND cid > 0 THEN
    IF emp.company_id IS DISTINCT FROM cid THEN
      RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
    END IF;
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 8 THEN
    authorized := saas_device_fingerprint_matches(p_employee_id, fp, NULL);
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

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'company_id', emp.company_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_resolve_employee_by_fingerprint(p_fingerprint TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  d RECORD;
  sub_chk JSONB;
  match_count INTEGER := 0;
BEGIN
  IF fp IS NULL OR length(fp) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  SELECT COUNT(*) INTO match_count
  FROM employee_devices ed
  WHERE ed.fingerprint = fp
     OR fp = ANY(COALESCE(ed.alt_fingerprints, '{}'));

  IF match_count > 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fingerprint_ambiguous');
  END IF;

  SELECT * INTO d FROM saas_find_employee_device_by_fingerprint(fp) LIMIT 1;
  IF d.employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(d.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'company_id', d.company_id,
      'detail', sub_chk
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name,
    'dept', d.dept,
    'company_id', d.company_id,
    'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
    'remote_attend', COALESCE(d.remote_attend, false)
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_adopt_browser_fingerprint(
  p_fingerprint TEXT DEFAULT NULL,
  p_ip TEXT DEFAULT NULL,
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
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  v_ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  tok TEXT := NULLIF(trim(p_token), '');
  d RECORD;
  alt_count INTEGER;
  rate_chk JSONB;
BEGIN
  IF fp IS NULL OR length(fp) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  rate_chk := saas_check_api_rate_limit('browser_adopt', fp, v_ip, 20, 3600);
  IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  PERFORM saas_record_api_attempt('browser_adopt', fp, v_ip);

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
  ELSIF v_ip IS NOT NULL THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.ip = v_ip
      AND ed.fingerprint IS NOT NULL AND ed.fingerprint <> ''
      AND ed.last_login >= NOW() - INTERVAL '30 days'
    ORDER BY ed.last_login DESC NULLS LAST
    LIMIT 1;

    IF FOUND THEN
      SELECT COUNT(*) INTO alt_count
      FROM employee_devices ed2
      WHERE ed2.ip = v_ip
        AND ed2.fingerprint IS NOT NULL AND ed2.fingerprint <> ''
        AND ed2.last_login >= NOW() - INTERVAL '30 days';
      IF alt_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ip_ambiguous');
      END IF;
    END IF;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF NOT FOUND OR d.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_found');
  END IF;

  IF saas_device_fingerprint_matches(d.employee_id, fp, d.slot) THEN
    UPDATE employee_devices SET last_login = NOW(), ip = COALESCE(v_ip, ip) WHERE id = d.id;
    RETURN jsonb_build_object(
      'ok', true,
      'employee_id', d.employee_id,
      'slot', d.slot,
      'emp_name', d.emp_name,
      'company_id', d.emp_company_id,
      'already_registered', true
    );
  END IF;

  IF d.fingerprint IS NULL OR d.fingerprint = '' THEN
    UPDATE employee_devices
    SET fingerprint = fp, ip = COALESCE(v_ip, ip), linked_at = COALESCE(linked_at, NOW()), last_login = NOW()
    WHERE id = d.id;
    RETURN jsonb_build_object(
      'ok', true,
      'employee_id', d.employee_id,
      'slot', d.slot,
      'emp_name', d.emp_name,
      'company_id', d.emp_company_id,
      'primary', true
    );
  END IF;

  alt_count := COALESCE(array_length(d.alt_fingerprints, 1), 0);
  IF alt_count >= 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_browsers');
  END IF;

  IF EXISTS (
    SELECT 1 FROM employee_devices ed
    WHERE (ed.fingerprint = fp OR fp = ANY(COALESCE(ed.alt_fingerprints, '{}')))
      AND NOT (ed.employee_id = d.employee_id AND ed.slot = d.slot)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fingerprint_already_used');
  END IF;

  UPDATE employee_devices
  SET
    alt_fingerprints = array_append(COALESCE(alt_fingerprints, '{}'), fp),
    ip = COALESCE(v_ip, ip),
    last_login = NOW()
  WHERE id = d.id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name,
    'company_id', d.emp_company_id,
    'multi_browser', true
  );
END;
$$;

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
  adopt JSONB;
BEGIN
  adopt := saas_adopt_browser_fingerprint(p_fingerprint, p_ip, p_token, p_employee_id, p_slot);
  IF COALESCE((adopt->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN adopt;
  END IF;

  UPDATE employee_devices ed
  SET
    device_info = COALESCE(p_device_info, ed.device_info, '{}'::jsonb),
    token_used_at = NOW(),
    linked_at = COALESCE(ed.linked_at, NOW())
  WHERE ed.employee_id = (adopt->>'employee_id')::integer
    AND ed.slot = (adopt->>'slot')::smallint;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', adopt->>'employee_id',
    'slot', adopt->>'slot',
    'emp_name', adopt->>'emp_name',
    'fingerprint', NULLIF(trim(p_fingerprint), ''),
    'ip', NULLIF(trim(COALESCE(p_ip, '')), ''),
    'multi_browser', COALESCE((adopt->>'multi_browser')::boolean, false)
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_device_fingerprint_matches(INTEGER, TEXT, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_device_fingerprint_matches(INTEGER, TEXT, SMALLINT) TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION saas_adopt_browser_fingerprint(TEXT, TEXT, TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_adopt_browser_fingerprint(TEXT, TEXT, TEXT, INTEGER, SMALLINT) TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
