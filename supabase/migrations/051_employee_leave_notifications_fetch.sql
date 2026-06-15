-- ============================================================
-- KYNO 051 — Include leave notifications in device-auth fetch
-- Merges employee_notifications table into saas_fetch_employee_notifications
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_notifications(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
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
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
  filtered JSONB;
  merged JSONB;
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

  settings_key := 'company:' || emp.company_id::TEXT || ':employee_notifications';

  SELECT value INTO raw_val
  FROM app_settings
  WHERE key = settings_key
  LIMIT 1;

  arr := '[]'::jsonb;
  IF raw_val IS NOT NULL AND btrim(raw_val) <> '' THEN
    BEGIN
      arr := raw_val::jsonb;
      IF jsonb_typeof(arr) = 'string' THEN
        arr := (arr #>> '{}')::jsonb;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      arr := '[]'::jsonb;
    END;
  END IF;

  IF jsonb_typeof(arr) IS DISTINCT FROM 'array' THEN
    arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(
    jsonb_agg(elem ORDER BY COALESCE((elem->>'ts')::BIGINT, 0) DESC NULLS LAST),
    '[]'::jsonb
  )
  INTO filtered
  FROM (
    SELECT elem
    FROM jsonb_array_elements(arr) elem
    WHERE COALESCE((elem->>'empId')::INTEGER, (elem->>'emp_id')::INTEGER, 0) = p_employee_id
      AND (
        elem->>'companyId' IS NULL
        OR (elem->>'companyId')::INTEGER = emp.company_id
      )
  ) sub;

  SELECT COALESCE(
    jsonb_agg(elem ORDER BY COALESCE((elem->>'ts')::BIGINT, 0) DESC NULLS LAST),
    '[]'::jsonb
  )
  INTO merged
  FROM (
    SELECT elem
    FROM (
      SELECT elem
      FROM jsonb_array_elements(COALESCE(filtered, '[]'::jsonb)) elem
      UNION ALL
      SELECT jsonb_build_object(
        'id', COALESCE(n.notif_ref, 'sbn_' || n.id::TEXT),
        'empId', n.employee_id,
        'type', n.notif_type,
        'title', n.title,
        'body', COALESCE(n.body, ''),
        'unread', CASE WHEN n.is_read THEN FALSE ELSE TRUE END,
        'read', n.is_read,
        'ts', (EXTRACT(EPOCH FROM n.created_at) * 1000)::BIGINT,
        '_remoteId', n.id,
        'companyId', n.company_id
      ) AS elem
      FROM employee_notifications n
      WHERE n.employee_id = p_employee_id
        AND n.company_id = emp.company_id
    ) combined
    ORDER BY COALESCE((elem->>'ts')::BIGINT, 0) DESC NULLS LAST
    LIMIT lim
  ) limited_rows;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'notifications', COALESCE(merged, '[]'::jsonb)
  );
END;
$$;

-- Allow marking read by table id OR notif_ref
DROP FUNCTION IF EXISTS saas_mark_emp_notification_read(BIGINT);

CREATE OR REPLACE FUNCTION saas_mark_emp_notification_read(
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id
      AND (cid IS NULL OR cid <= 0 OR company_id = cid);
    RETURN jsonb_build_object('ok', true);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref)
      AND (cid IS NULL OR cid <= 0 OR company_id = cid);
    RETURN jsonb_build_object('ok', true);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) TO authenticated, anon;
