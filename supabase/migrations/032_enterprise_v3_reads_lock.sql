-- ============================================================
-- KYNO 032 — Enterprise v3 Read Layer + Write Lock (manual activate)
-- Additive — لا تغيير RLS 029/030
-- Run saas_v3_enable_write_lock() ONLY after KYNO_RPC_MODE fully enabled
-- ============================================================

-- ----------------------------------------------------------
-- 1) Tenant-scoped read RPCs (pagination)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_list_employees(
  p_limit INTEGER DEFAULT 100,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  rows JSONB;
  total INTEGER;
BEGIN
  IF auth_is_super_admin() THEN
    SELECT COUNT(*) INTO total FROM employees;
    SELECT COALESCE(jsonb_agg(to_jsonb(e.*) ORDER BY e.id), '[]'::jsonb) INTO rows
    FROM (
      SELECT * FROM employees e ORDER BY e.id LIMIT lim OFFSET off
    ) e;
    RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
  END IF;

  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT COUNT(*) INTO total FROM employees e WHERE e.company_id = cid;
  SELECT COALESCE(jsonb_agg(to_jsonb(e.*) ORDER BY e.id), '[]'::jsonb) INTO rows
  FROM (
    SELECT * FROM employees e WHERE e.company_id = cid ORDER BY e.id LIMIT lim OFFSET off
  ) e;

  RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
END;
$$;

CREATE OR REPLACE FUNCTION saas_list_attendance(
  p_limit INTEGER DEFAULT 100,
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
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
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

CREATE OR REPLACE FUNCTION saas_list_salary_records(
  p_limit INTEGER DEFAULT 100,
  p_offset INTEGER DEFAULT 0,
  p_employee_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  rows JSONB;
  total INTEGER;
BEGIN
  IF auth_is_super_admin() THEN
    SELECT COUNT(*) INTO total FROM salary_records sr
    WHERE (p_employee_id IS NULL OR sr.employee_id = p_employee_id);
    SELECT COALESCE(jsonb_agg(to_jsonb(sr.*) ORDER BY sr.month_iso DESC), '[]'::jsonb) INTO rows
    FROM (
      SELECT * FROM salary_records sr
      WHERE (p_employee_id IS NULL OR sr.employee_id = p_employee_id)
      ORDER BY sr.month_iso DESC
      LIMIT lim OFFSET off
    ) sr;
    RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
  END IF;

  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT COUNT(*) INTO total
  FROM salary_records sr
  WHERE (p_employee_id IS NULL OR sr.employee_id = p_employee_id)
    AND auth_effective_company_id(sr.company_id, sr.employee_id) = cid;

  SELECT COALESCE(jsonb_agg(to_jsonb(sr.*) ORDER BY sr.month_iso DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT * FROM salary_records sr
    WHERE (p_employee_id IS NULL OR sr.employee_id = p_employee_id)
      AND auth_effective_company_id(sr.company_id, sr.employee_id) = cid
    ORDER BY sr.month_iso DESC
    LIMIT lim OFFSET off
  ) sr;

  RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
END;
$$;

-- ----------------------------------------------------------
-- 2) Final write lock — super_admin only, run manually after v3 rollout
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_enable_write_lock()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  REVOKE INSERT, UPDATE, DELETE ON employees FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON attendance FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON salary_records FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON departments FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON notifications FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON employee_devices FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON companies FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON subscriptions FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON app_settings FROM authenticated;

  RETURN jsonb_build_object('ok', true, 'message', 'write_lock_enabled');
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_disable_write_lock()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  GRANT INSERT, UPDATE, DELETE ON employees TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON attendance TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON salary_records TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON departments TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON notifications TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON employee_devices TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON companies TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON subscriptions TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON app_settings TO authenticated;

  RETURN jsonb_build_object('ok', true, 'message', 'write_lock_disabled');
END;
$$;

-- ----------------------------------------------------------
-- 3) GRANTs
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_list_employees(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_employees(INTEGER, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_list_attendance(INTEGER, INTEGER, INTEGER, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_attendance(INTEGER, INTEGER, INTEGER, DATE, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_list_salary_records(INTEGER, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_salary_records(INTEGER, INTEGER, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_enable_write_lock() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_enable_write_lock() TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_disable_write_lock() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_disable_write_lock() TO authenticated;
