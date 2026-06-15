-- ============================================================
-- 015 — إصلاح حذف مستخدمي الشركة (مدير الشركة)
-- شغّل بعد 014
-- ============================================================

GRANT DELETE ON TABLE saas_users TO authenticated;

CREATE OR REPLACE FUNCTION saas_delete_company_user(
  p_user_id INTEGER,
  p_company_id INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uid INTEGER := p_user_id;
  actor_id INTEGER;
  deleted_count INTEGER;
BEGIN
  IF uid IS NULL OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := NULLIF(COALESCE(
    auth.jwt() -> 'app_metadata' ->> 'saas_user_id',
    auth.jwt() ->> 'saas_user_id'
  ), '')::INTEGER;

  IF actor_id IS NOT NULL AND actor_id = uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_delete');
  END IF;

  IF NOT auth_is_super_admin()
     AND NOT (
       auth_app_role() IN ('company_admin', 'super_admin')
       AND auth_company_id() IS NOT NULL
       AND auth_company_id() = cid
     ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users
    WHERE id = uid AND company_id = cid AND role <> 'super_admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  DELETE FROM saas_sessions WHERE user_id = uid;
  DELETE FROM saas_users WHERE id = uid AND company_id = cid;
  GET DIAGNOSTICS deleted_count = ROW_COUNT;

  IF deleted_count < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'delete_failed');
  END IF;

  RETURN jsonb_build_object('ok', true, 'deleted_id', uid);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

DROP POLICY IF EXISTS "saas_users_delete_super" ON saas_users;
DROP POLICY IF EXISTS "saas_users_delete_tenant" ON saas_users;

CREATE POLICY "saas_users_delete_tenant" ON saas_users
  FOR DELETE TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      auth_app_role() IN ('company_admin', 'super_admin')
      AND company_id IS NOT NULL
      AND company_id = auth_company_id()
      AND role <> 'super_admin'
    )
  );

REVOKE ALL ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) TO authenticated;
