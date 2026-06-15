-- ============================================================
-- 009 — تسجيل audit_logs عبر RPC (لا يعطل حفظ الإعدادات/GPS)
-- شغّل بعد 004
-- ============================================================

CREATE OR REPLACE FUNCTION saas_insert_audit_log(
  p_action TEXT,
  p_category TEXT DEFAULT NULL,
  p_details TEXT DEFAULT NULL,
  p_target_name TEXT DEFAULT NULL,
  p_actor_id INTEGER DEFAULT NULL,
  p_actor_name TEXT DEFAULT NULL,
  p_actor_role TEXT DEFAULT NULL,
  p_meta JSONB DEFAULT '{}'::jsonb
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
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta
  ) VALUES (
    cid,
    p_actor_id,
    NULLIF(trim(p_actor_name), ''),
    NULLIF(trim(p_actor_role), ''),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    COALESCE(p_meta, '{}'::jsonb)
  );

  RETURN jsonb_build_object('ok', true);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_insert_audit_log(TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_insert_audit_log(TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT, JSONB) TO authenticated;

GRANT SELECT, INSERT ON audit_logs TO authenticated;
