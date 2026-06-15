-- ============================================================
-- 007 — إنشاء قسم للشركة عبر RPC (تجاوز مشاكل upsert المباشر + RLS)
-- شغّل بعد 004
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

  IF EXISTS (SELECT 1 FROM departments WHERE name = n LIMIT 1) THEN
    RETURN jsonb_build_object('ok', true, 'exists', true, 'name', n);
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

REVOKE ALL ON FUNCTION saas_ensure_department(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_ensure_department(TEXT) TO authenticated;

-- السماح بقراءة الأقسام للمستخدم المصادق (إن كان GRANT ناقصاً)
GRANT SELECT, INSERT, UPDATE ON departments TO authenticated;
