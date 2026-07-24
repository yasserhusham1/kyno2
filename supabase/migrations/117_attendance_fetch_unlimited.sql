-- 117 — جلب سجلات الحضور بدون فقد (offset + حد أعلى للصفحة)
-- لا يحذف أي سجل؛ يوسّع RPC فقط لدعم التصفح الكامل.

-- saas_fetch_employee_attendance — offset + total
DROP FUNCTION IF EXISTS saas_fetch_employee_attendance(INTEGER, TEXT, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION saas_fetch_employee_attendance(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 500,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 5000);
  off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  rows JSONB;
  total_count INTEGER;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT COUNT(*) INTO total_count
  FROM attendance att
  WHERE att.employee_id = p_employee_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id, 'employee_id', a.employee_id, 'emp_name', a.emp_name,
        'dept', a.dept, 'date_label', a.date_label, 'date_iso', a.date_iso,
        'check_in', a.check_in, 'check_out', a.check_out, 'hours', a.hours,
        'late', a.late, 'overtime', a.overtime, 'status', a.status, 'company_id', a.company_id
      ) ORDER BY a.date_iso DESC
    ), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM attendance att
    WHERE att.employee_id = p_employee_id
    ORDER BY att.date_iso DESC
    LIMIT lim OFFSET off
  ) a;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'records', rows,
    'total', total_count,
    'limit', lim,
    'offset', off
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_attendance(INTEGER, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_attendance(INTEGER, TEXT, TEXT, INTEGER, INTEGER) TO anon, authenticated, service_role;

-- saas_list_attendance — رفع حد الصفحة للمسؤول
CREATE OR REPLACE FUNCTION saas_list_attendance(
  p_limit INTEGER DEFAULT 500,
  p_offset INTEGER DEFAULT 0,
  p_employee_id INTEGER DEFAULT NULL,
  p_date_from DATE DEFAULT NULL,
  p_date_to DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 2000);
  off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  rows JSONB;
  total INTEGER;
BEGIN
  IF auth_is_super_admin() THEN
    SELECT COUNT(*) INTO total FROM attendance a
    WHERE (p_employee_id IS NULL OR a.employee_id = p_employee_id)
      AND (p_date_from IS NULL OR a.date_iso >= p_date_from)
      AND (p_date_to IS NULL OR a.date_iso <= p_date_to);
    SELECT COALESCE(jsonb_agg(to_jsonb(a.*) ORDER BY a.date_iso DESC), '[]'::jsonb) INTO rows
    FROM (
      SELECT * FROM attendance a
      WHERE (p_employee_id IS NULL OR a.employee_id = p_employee_id)
        AND (p_date_from IS NULL OR a.date_iso >= p_date_from)
        AND (p_date_to IS NULL OR a.date_iso <= p_date_to)
      ORDER BY a.date_iso DESC
      LIMIT lim OFFSET off
    ) a;
    RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
  END IF;

  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT COUNT(*) INTO total FROM attendance a
  WHERE a.company_id = cid
    AND (p_employee_id IS NULL OR a.employee_id = p_employee_id)
    AND (p_date_from IS NULL OR a.date_iso >= p_date_from)
    AND (p_date_to IS NULL OR a.date_iso <= p_date_to);

  SELECT COALESCE(jsonb_agg(to_jsonb(a.*) ORDER BY a.date_iso DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT * FROM attendance a
    WHERE a.company_id = cid
      AND (p_employee_id IS NULL OR a.employee_id = p_employee_id)
      AND (p_date_from IS NULL OR a.date_iso >= p_date_from)
      AND (p_date_to IS NULL OR a.date_iso <= p_date_to)
    ORDER BY a.date_iso DESC
    LIMIT lim OFFSET off
  ) a;

  RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
END;
$$;
