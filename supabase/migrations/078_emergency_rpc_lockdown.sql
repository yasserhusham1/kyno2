-- ============================================================
-- KYNO 078 — Emergency RPC grant lockdown + critical function fixes
-- Apply when 077 is not yet on production. Idempotent REVOKE/GRANT.
-- Run: tools/apply-migration-078.ps1
-- Verify: tools/verify-full-security-audit.ps1
-- ============================================================

-- ---------- 0) Helper: employee portal auth (H3) ----------
CREATE OR REPLACE FUNCTION saas_v3_employee_portal_authorize(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
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
  sub_chk JSONB;
  cid INTEGER;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  cid := auth_company_id();
  IF cid IS NOT NULL AND cid > 0 THEN
    IF emp.company_id IS DISTINCT FROM cid THEN
      RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
    END IF;
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 8 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 16 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'company_id', emp.company_id
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_employee_portal_authorize(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_employee_portal_authorize(INTEGER, TEXT, TEXT) TO anon, authenticated, service_role;

-- ---------- C1: drop ambiguous overload (PostgREST 300) ----------
DROP FUNCTION IF EXISTS saas_mark_emp_notification_read(BIGINT);

-- ---------- C1: Admin mark read — authenticated tenant only ----------
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
  updated_count INTEGER := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    IF auth_is_super_admin() THEN
      IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
        UPDATE employee_notifications SET is_read = TRUE WHERE id = p_notif_id;
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
      END IF;
      IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
        UPDATE employee_notifications SET is_read = TRUE WHERE notif_ref = btrim(p_notif_ref);
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id AND company_id = cid;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref) AND company_id = cid;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) TO authenticated, service_role;

-- Portal mark read (device proof)
CREATE OR REPLACE FUNCTION saas_mark_employee_portal_notification_read(
  p_employee_id INTEGER,
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  cid INTEGER;
  updated_count INTEGER := 0;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;
  cid := (auth_result->>'company_id')::INTEGER;

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id AND company_id = cid AND employee_id = p_employee_id;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref) AND company_id = cid AND employee_id = p_employee_id;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;

-- ---------- CRITICAL: lock saas_rotate_user_password to service_role ONLY ----------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'saas_rotate_user_password'
  ) THEN
    REVOKE ALL ON FUNCTION saas_rotate_user_password(TEXT, TEXT) FROM PUBLIC;
    REVOKE ALL ON FUNCTION saas_rotate_user_password(TEXT, TEXT) FROM anon;
    REVOKE ALL ON FUNCTION saas_rotate_user_password(TEXT, TEXT) FROM authenticated;
    GRANT EXECUTE ON FUNCTION saas_rotate_user_password(TEXT, TEXT) TO service_role;
  END IF;
END $$;

-- Lock session revoke helpers
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'saas_revoke_all_sessions_for_user') THEN
    REVOKE ALL ON FUNCTION saas_revoke_all_sessions_for_user(INTEGER) FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION saas_revoke_all_sessions_for_user(INTEGER) TO service_role;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'saas_revoke_all_super_admin_sessions') THEN
    REVOKE ALL ON FUNCTION saas_revoke_all_super_admin_sessions() FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION saas_revoke_all_super_admin_sessions() TO service_role;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'saas_user_auth_email') THEN
    REVOKE ALL ON FUNCTION saas_user_auth_email(INTEGER) FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION saas_user_auth_email(INTEGER) TO service_role;
  END IF;
END $$;

-- ---------- H3: attendance fetch — device required ----------
CREATE OR REPLACE FUNCTION saas_fetch_employee_attendance(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

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
    ORDER BY att.date_iso DESC LIMIT lim
  ) a;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

-- ---------- H1: subscription_plans RLS ----------
ALTER TABLE subscription_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscription_plans_deny_anon ON subscription_plans;
CREATE POLICY subscription_plans_deny_anon ON subscription_plans
  FOR ALL TO anon USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS subscription_plans_authenticated_read ON subscription_plans;
CREATE POLICY subscription_plans_authenticated_read ON subscription_plans
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS subscription_plans_super_admin ON subscription_plans;
CREATE POLICY subscription_plans_super_admin ON subscription_plans
  FOR ALL TO authenticated
  USING (auth_is_super_admin()) WITH CHECK (auth_is_super_admin());

REVOKE ALL ON TABLE subscription_plans FROM anon;
GRANT SELECT ON TABLE subscription_plans TO authenticated;

-- ---------- H2: subscription status read-only ----------
CREATE OR REPLACE FUNCTION saas_get_company_subscription_status(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
  days_left INTEGER;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('valid', true, 'status', 'active', 'message', '', 'daysLeft', 0);
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'status', 'pending', 'message', 'الشركة غير موجودة', 'daysLeft', 0);
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object('valid', false, 'status', 'suspended', 'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.', 'daysLeft', 0);
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'status', 'pending', 'message', 'لا يوجد اشتراك نشط', 'daysLeft', 0);
  END IF;

  days_left := (sub.end_date - CURRENT_DATE);

  IF sub.status = 'suspended' OR sub.status = 'pending' OR sub.end_date < CURRENT_DATE
     OR (sub.status = 'expired' AND sub.end_date >= CURRENT_DATE) THEN
    RETURN jsonb_build_object(
      'valid', false,
      'status', CASE WHEN sub.status = 'suspended' THEN 'suspended' ELSE 'expired' END,
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  RETURN jsonb_build_object(
    'valid', true, 'status', 'active', 'end_date', sub.end_date,
    'daysLeft', GREATEST(days_left, 0),
    'warning', days_left <= 10,
    'message', CASE WHEN days_left <= 10 THEN 'ينتهي الاشتراك خلال ' || GREATEST(days_left, 0)::text || ' يوم' ELSE '' END
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_company_subscription_status(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_company_subscription_status(INTEGER) TO anon, authenticated, service_role;

REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM anon;

-- ---------- Audit RPC (super_admin) — live grants/policies report ----------
CREATE OR REPLACE FUNCTION saas_security_grants_audit()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rls_rows JSONB;
  anon_grants JSONB;
  rpc_grants JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', c.relname,
    'rls_enabled', c.relrowsecurity,
    'rls_forced', c.relforcerowsecurity
  ) ORDER BY c.relname), '[]'::jsonb) INTO rls_rows
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
    AND c.relname IN (
      'subscription_plans','employee_notifications','attendance','employees',
      'salary_records','companies','subscriptions','saas_users','departments','leaves'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', table_name,
    'privilege', privilege_type
  ) ORDER BY table_name, privilege_type), '[]'::jsonb) INTO anon_grants
  FROM information_schema.role_table_grants
  WHERE grantee = 'anon' AND table_schema = 'public';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'function', p.proname,
    'grantee', grantee.rolname
  ) ORDER BY p.proname, grantee.rolname), '[]'::jsonb) INTO rpc_grants
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
  JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'saas_mark_emp_notification_read',
      'saas_mark_employee_portal_notification_read',
      'saas_rotate_user_password',
      'saas_fetch_employee_attendance',
      'saas_v3_employee_portal_authorize',
      'saas_get_company_subscription_status'
    );

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'rls_tables', rls_rows,
    'anon_table_grants', anon_grants,
    'critical_rpc_grants', rpc_grants,
    'policies', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'table', tablename, 'policy', policyname, 'roles', roles, 'cmd', cmd
      ) ORDER BY tablename, policyname), '[]'::jsonb)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename IN ('subscription_plans','employee_notifications','attendance','employees')
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_grants_audit() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION saas_security_grants_audit() TO authenticated, service_role;

COMMENT ON FUNCTION saas_security_grants_audit() IS '078: Live RLS/grants/policies audit for super_admin verification.';
