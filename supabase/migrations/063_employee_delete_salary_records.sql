-- ============================================================
-- KYNO 063 — Full employee delete (salary_records + related rows)
-- Fixes 400 on saas_delete_employee when salary_records exist
-- ============================================================

CREATE OR REPLACE FUNCTION saas_delete_employee(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
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

  before_row := to_jsonb(emp);

  DELETE FROM salary_records
  WHERE employee_id = p_employee_id
    AND company_id = emp.company_id;

  DELETE FROM attendance
  WHERE employee_id = p_employee_id
    AND company_id = emp.company_id;

  DELETE FROM leaves
  WHERE employee_id = p_employee_id
    AND company_id = emp.company_id;

  DELETE FROM employee_notifications
  WHERE employee_id = p_employee_id
    AND company_id = emp.company_id;

  DELETE FROM employee_devices
  WHERE employee_id = p_employee_id;

  DELETE FROM employees WHERE id = p_employee_id;

  PERFORM saas_v3_write_audit(
    'employee_deleted', 'employees',
    'Deleted employee ' || p_employee_id::TEXT,
    emp.name,
    emp.company_id,
    before_row,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id);
EXCEPTION
  WHEN foreign_key_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_has_dependencies');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_delete_employee(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_employee(INTEGER) TO authenticated;
