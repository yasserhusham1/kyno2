-- ============================================================
-- KYNO 065 — Fix saas_v3_write_audit overload ambiguity (42725)
-- Legacy 7-arg function from 031 coexists with 11-arg 056/058.
-- Calls with 7 args match BOTH → "function ... is not unique"
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

DROP FUNCTION IF EXISTS saas_v3_write_audit(TEXT, TEXT, TEXT, TEXT, INTEGER, JSONB, JSONB);

CREATE OR REPLACE FUNCTION saas_v3_write_audit(
  p_action TEXT,
  p_category TEXT,
  p_details TEXT,
  p_target_name TEXT,
  p_company_id INTEGER,
  p_before JSONB DEFAULT NULL,
  p_after JSONB DEFAULT NULL,
  p_entity_type TEXT DEFAULT NULL,
  p_entity_id TEXT DEFAULT NULL,
  p_ip_address TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta JSONB;
  cid INTEGER;
  tenant JSONB;
BEGIN
  cid := NULLIF(p_company_id, 0);
  IF cid IS NULL OR cid <= 0 THEN
    cid := auth_company_id();
  END IF;
  IF auth_is_super_admin() AND (cid IS NULL OR cid <= 0) THEN
    cid := NULLIF(p_company_id, 0);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN;
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN;
  END IF;

  meta := jsonb_build_object(
    'company_id', cid,
    'timestamp', to_jsonb(NOW()),
    'entity_type', NULLIF(trim(p_entity_type), ''),
    'entity_id', NULLIF(trim(p_entity_id), ''),
    'old_value', COALESCE(p_before, 'null'::jsonb),
    'new_value', COALESCE(p_after, 'null'::jsonb),
    'before', COALESCE(p_before, 'null'::jsonb),
    'after', COALESCE(p_after, 'null'::jsonb)
  );

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta,
    ip_address, user_agent
  ) VALUES (
    cid,
    NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER,
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'display_name', auth.jwt() ->> 'email', ''),
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth_app_role()),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    meta,
    NULLIF(trim(p_ip_address), ''),
    NULLIF(trim(p_user_agent), '')
  );
EXCEPTION
  WHEN others THEN
    NULL;
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_write_audit(TEXT, TEXT, TEXT, TEXT, INTEGER, JSONB, JSONB, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION saas_v3_write_audit(TEXT, TEXT, TEXT, TEXT, INTEGER, JSONB, JSONB, TEXT, TEXT, TEXT, TEXT) IS
  'Single canonical audit writer — legacy 7-arg overload removed in 065';
