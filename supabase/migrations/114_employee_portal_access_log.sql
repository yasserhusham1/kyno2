-- 114 — سجل دخول ونشاط بوابة الموظف (تتبع الأجهزة)

CREATE TABLE IF NOT EXISTS employee_portal_access_log (
  id BIGSERIAL PRIMARY KEY,
  company_id INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  employee_id INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  success BOOLEAN NOT NULL DEFAULT TRUE,
  ip TEXT,
  fingerprint TEXT,
  user_agent TEXT,
  geo_lat NUMERIC(10, 7),
  geo_lng NUMERIC(10, 7),
  geo_accuracy NUMERIC(10, 2),
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT employee_portal_access_log_event_chk CHECK (
    event_type IN (
      'portal_visit', 'portal_login', 'check_in', 'check_out',
      'qr_link', 'device_verify', 'qr_scan_attempt'
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_emp_portal_log_company_created
  ON employee_portal_access_log (company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_emp_portal_log_employee_created
  ON employee_portal_access_log (employee_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_emp_portal_log_event
  ON employee_portal_access_log (event_type);

ALTER TABLE employee_portal_access_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS emp_portal_log_deny_all ON employee_portal_access_log;
CREATE POLICY emp_portal_log_deny_all ON employee_portal_access_log
  FOR ALL USING (false) WITH CHECK (false);

CREATE OR REPLACE FUNCTION saas_log_employee_portal_event(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_event_type TEXT DEFAULT 'portal_visit',
  p_success BOOLEAN DEFAULT TRUE,
  p_ip TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL,
  p_geo_lat NUMERIC DEFAULT NULL,
  p_geo_lng NUMERIC DEFAULT NULL,
  p_geo_accuracy NUMERIC DEFAULT NULL,
  p_meta JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  ev TEXT := NULLIF(trim(p_event_type), '');
  authorized BOOLEAN := FALSE;
  sub_chk JSONB;
  rate_chk JSONB;
  new_id BIGINT;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 OR ev IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF ev NOT IN (
    'portal_visit', 'portal_login', 'check_in', 'check_out',
    'qr_link', 'device_verify', 'qr_scan_attempt'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_event');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  IF emp.remote_attend IS TRUE THEN authorized := TRUE; END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND ev IN ('portal_visit', 'portal_login', 'device_verify') THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  rate_chk := saas_check_api_rate_limit(
    'portal_access_log',
    COALESCE(fp, 'emp:' || p_employee_id::text),
    NULLIF(trim(p_ip), ''),
    120,
    3600
  );
  IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'rate_limited',
      'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 3600)
    );
  END IF;
  PERFORM saas_record_api_attempt(
    'portal_access_log',
    COALESCE(fp, 'emp:' || p_employee_id::text),
    NULLIF(trim(p_ip), '')
  );

  INSERT INTO employee_portal_access_log (
    company_id, employee_id, event_type, success,
    ip, fingerprint, user_agent,
    geo_lat, geo_lng, geo_accuracy, meta
  ) VALUES (
    emp.company_id,
    p_employee_id,
    ev,
    COALESCE(p_success, true),
    NULLIF(trim(p_ip), ''),
    fp,
    NULLIF(trim(p_user_agent), ''),
    p_geo_lat,
    p_geo_lng,
    p_geo_accuracy,
    COALESCE(p_meta, '{}'::jsonb)
  )
  RETURNING id INTO new_id;

  RETURN jsonb_build_object('ok', true, 'id', new_id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_list_employee_portal_access_log(
  p_employee_id INTEGER DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_event_type TEXT DEFAULT NULL,
  p_date_from DATE DEFAULT NULL,
  p_date_to DATE DEFAULT NULL,
  p_success BOOLEAN DEFAULT NULL,
  p_limit INTEGER DEFAULT 200,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tenant JSONB;
  cid INTEGER;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
  off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  q TEXT := NULLIF(trim(p_search), '');
  ev TEXT := NULLIF(trim(p_event_type), '');
  rows JSONB;
  total_count BIGINT;
  summary JSONB;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT COUNT(*) INTO total_count
  FROM employee_portal_access_log l
  JOIN employees e ON e.id = l.employee_id
  WHERE l.company_id = cid
    AND (p_employee_id IS NULL OR l.employee_id = p_employee_id)
    AND (ev IS NULL OR l.event_type = ev)
    AND (p_success IS NULL OR l.success = p_success)
    AND (p_date_from IS NULL OR l.created_at::date >= p_date_from)
    AND (p_date_to IS NULL OR l.created_at::date <= p_date_to)
    AND (
      q IS NULL OR
      e.name ILIKE '%' || q || '%' OR
      COALESCE(l.ip, '') ILIKE '%' || q || '%' OR
      COALESCE(l.fingerprint, '') ILIKE '%' || q || '%'
    );

  SELECT COALESCE(jsonb_agg(row_data ORDER BY created_at DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT jsonb_build_object(
      'id', l.id,
      'employee_id', l.employee_id,
      'employee_name', e.name,
      'dept', e.dept,
      'event_type', l.event_type,
      'success', l.success,
      'ip', l.ip,
      'fingerprint', l.fingerprint,
      'user_agent', l.user_agent,
      'geo_lat', l.geo_lat,
      'geo_lng', l.geo_lng,
      'geo_accuracy', l.geo_accuracy,
      'meta', l.meta,
      'created_at', l.created_at
    ) AS row_data,
    l.created_at
    FROM employee_portal_access_log l
    JOIN employees e ON e.id = l.employee_id
    WHERE l.company_id = cid
      AND (p_employee_id IS NULL OR l.employee_id = p_employee_id)
      AND (ev IS NULL OR l.event_type = ev)
      AND (p_success IS NULL OR l.success = p_success)
      AND (p_date_from IS NULL OR l.created_at::date >= p_date_from)
      AND (p_date_to IS NULL OR l.created_at::date <= p_date_to)
      AND (
        q IS NULL OR
        e.name ILIKE '%' || q || '%' OR
        COALESCE(l.ip, '') ILIKE '%' || q || '%' OR
        COALESCE(l.fingerprint, '') ILIKE '%' || q || '%'
      )
    ORDER BY l.created_at DESC
    LIMIT lim OFFSET off
  ) sub;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'employee_id', s.employee_id,
    'employee_name', s.employee_name,
    'visit_count', s.visit_count,
    'login_count', s.login_count,
    'punch_count', s.punch_count,
    'last_seen', s.last_seen,
    'last_ip', s.last_ip,
    'last_fingerprint', s.last_fingerprint
  )), '[]'::jsonb) INTO summary
  FROM (
    SELECT
      l.employee_id,
      MAX(e.name) AS employee_name,
      COUNT(*) FILTER (WHERE l.event_type = 'portal_visit') AS visit_count,
      COUNT(*) FILTER (WHERE l.event_type = 'portal_login') AS login_count,
      COUNT(*) FILTER (WHERE l.event_type IN ('check_in', 'check_out')) AS punch_count,
      MAX(l.created_at) AS last_seen,
      (ARRAY_AGG(l.ip ORDER BY l.created_at DESC))[1] AS last_ip,
      (ARRAY_AGG(l.fingerprint ORDER BY l.created_at DESC))[1] AS last_fingerprint
    FROM employee_portal_access_log l
    JOIN employees e ON e.id = l.employee_id
    WHERE l.company_id = cid
      AND (p_employee_id IS NULL OR l.employee_id = p_employee_id)
      AND (ev IS NULL OR l.event_type = ev)
      AND (p_success IS NULL OR l.success = p_success)
      AND (p_date_from IS NULL OR l.created_at::date >= p_date_from)
      AND (p_date_to IS NULL OR l.created_at::date <= p_date_to)
      AND (
        q IS NULL OR
        e.name ILIKE '%' || q || '%' OR
        COALESCE(l.ip, '') ILIKE '%' || q || '%' OR
        COALESCE(l.fingerprint, '') ILIKE '%' || q || '%'
      )
    GROUP BY l.employee_id
    ORDER BY MAX(l.created_at) DESC
    LIMIT 50
  ) s;

  RETURN jsonb_build_object(
    'ok', true,
    'total', total_count,
    'records', rows,
    'summary', summary
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_log_employee_portal_event(
  INTEGER, TEXT, TEXT, BOOLEAN, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, JSONB
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_log_employee_portal_event(
  INTEGER, TEXT, TEXT, BOOLEAN, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, JSONB
) TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION saas_list_employee_portal_access_log(
  INTEGER, TEXT, TEXT, DATE, DATE, BOOLEAN, INTEGER, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_employee_portal_access_log(
  INTEGER, TEXT, TEXT, DATE, DATE, BOOLEAN, INTEGER, INTEGER
) TO authenticated, service_role;

COMMENT ON TABLE employee_portal_access_log IS 'Audit log for employee portal visits, logins, and attendance punches';
