-- ============================================================
-- KYNO 023 — حذف/إعادة تسمية الأقسام (عزل company_id)
-- ============================================================

CREATE OR REPLACE FUNCTION saas_ensure_department(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  n TEXT := NULLIF(trim(p_name), '');
BEGIN
  IF n IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  IF EXISTS (
    SELECT 1 FROM departments
    WHERE name = n AND company_id = cid
    LIMIT 1
  ) THEN
    RETURN jsonb_build_object('ok', true, 'exists', true, 'name', n, 'company_id', cid);
  END IF;

  INSERT INTO departments (name, company_id) VALUES (n, cid);
  RETURN jsonb_build_object('ok', true, 'created', true, 'name', n, 'company_id', cid);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', true, 'exists', true, 'name', n);
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_department(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  n TEXT := NULLIF(trim(p_name), '');
  used_count INTEGER := 0;
BEGIN
  IF n IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_name');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  SELECT COUNT(*) INTO used_count
  FROM employees e
  WHERE e.dept = n AND e.company_id = cid;

  IF used_count > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'in_use', 'count', used_count);
  END IF;

  DELETE FROM departments
  WHERE name = n AND company_id = cid;

  RETURN jsonb_build_object('ok', true, 'deleted', true, 'name', n, 'company_id', cid);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_rename_department(p_old TEXT, p_new TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  old_n TEXT := NULLIF(trim(p_old), '');
  new_n TEXT := NULLIF(trim(p_new), '');
BEGIN
  IF old_n IS NULL OR new_n IS NULL OR old_n = new_n THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_names');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM departments WHERE name = old_n AND company_id = cid LIMIT 1
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF EXISTS (
    SELECT 1 FROM departments WHERE name = new_n AND company_id = cid AND name <> old_n LIMIT 1
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'duplicate');
  END IF;

  UPDATE departments SET name = new_n
  WHERE name = old_n AND company_id = cid;

  UPDATE employees SET dept = new_n
  WHERE dept = old_n AND company_id = cid;

  RETURN jsonb_build_object('ok', true, 'renamed', true, 'from', old_n, 'to', new_n, 'company_id', cid);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'duplicate');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_delete_department(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_rename_department(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_department(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION saas_rename_department(TEXT, TEXT) TO authenticated;
