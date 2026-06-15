-- ============================================================
-- KYNO 041 — Full employee delete (attendance + devices)
-- Prevents ghost data when re-adding employee with same id
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
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(emp);

  DELETE FROM attendance WHERE employee_id = p_employee_id;
  DELETE FROM employee_devices WHERE employee_id = p_employee_id;
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
END;
$$;

REVOKE ALL ON FUNCTION saas_delete_employee(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_employee(INTEGER) TO authenticated;
