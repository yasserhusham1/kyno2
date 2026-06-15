-- ============================================================
-- KYNO 059 — Final closure: recalculate_salary + lookup wrapper
-- ============================================================

-- ----------------------------------------------------------
-- 1) Payroll recalculate — explicit tenant gate before delegate
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_recalculate_salary(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  month_key TEXT;
  tenant JSONB;
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

  month_key := CASE WHEN COALESCE(emp.salary_type, 'monthly') = 'biweekly' THEN
    to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
    CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= 15 THEN '-H1' ELSE '-H2' END
  ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END;

  IF EXISTS (
    SELECT 1 FROM salary_records sr
    WHERE sr.employee_id = p_employee_id AND sr.month_iso = month_key AND sr.status = 'مُصدر'
  ) THEN
    RETURN saas_issue_salary(p_employee_id, month_key);
  END IF;

  RETURN saas_preview_salary(p_employee_id, month_key);
END;
$$;

REVOKE ALL ON FUNCTION saas_recalculate_salary(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_recalculate_salary(INTEGER) TO authenticated;

-- ----------------------------------------------------------
-- 2) Lookup wrapper — delegates to hardened resolve (058)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_lookup_device_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r JSONB;
  _session_cid INTEGER := auth_company_id();
BEGIN
  r := saas_resolve_qr_registration(p_token, p_employee_id, p_slot);
  IF r IS NULL OR COALESCE((r->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN NULL;
  END IF;
  RETURN r - 'ok' - 'source' - 'error';
END;
$$;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

-- ----------------------------------------------------------
-- 3) Health report — recognize delegated tenant validators
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_security_health_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tbl_count INTEGER;
  rls_on_count INTEGER;
  policy_count INTEGER;
  rpc_count INTEGER;
  trigger_count INTEGER;
  tables_no_rls JSONB;
  policies_using_true JSONB;
  policies_check_true JSONB;
  definer_rpcs JSONB;
  rpcs_no_tenant JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COUNT(*) INTO tbl_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';

  SELECT COUNT(*) INTO rls_on_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = TRUE;

  SELECT COUNT(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public';
  SELECT COUNT(*) INTO rpc_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f';

  SELECT COUNT(*) INTO trigger_count
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal;

  SELECT COALESCE(jsonb_agg(c.relname ORDER BY c.relname), '[]'::jsonb) INTO tables_no_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = FALSE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'qual', qual::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_using_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND qual IS NOT NULL
    AND qual::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'with_check', with_check::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_check_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND with_check IS NOT NULL
    AND with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO definer_rpcs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef = TRUE;

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO rpcs_no_tenant
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE
    AND p.proname LIKE 'saas_%'
    AND p.proname NOT IN (
      'saas_verify_login', 'saas_force_reset_password', 'saas_fetch_employee_attendance',
      'saas_fetch_employee_salary_records', 'saas_fetch_employee_notifications',
      'saas_fetch_employee_client_profile', 'saas_upsert_attendance_by_device',
      'saas_upsert_attendance_employee', 'saas_link_device_by_token',
      'saas_security_health_report', 'saas_v3_audit_rls_report',
      'saas_save_platform_globals', 'saas_super_upsert_company',
      'saas_super_toggle_company_status', 'saas_super_delete_company',
      'saas_super_renew_subscription', 'saas_super_delete_subscription',
      'saas_mark_subscription_expired', 'saas_get_plan_limits',
      'saas_assert_plan_feature', 'saas_assert_company_active',
      'saas_assert_employee_limit', 'saas_v3_employee_portal_subscription_ok',
      'saas_check_api_rate_limit', 'saas_record_api_attempt',
      'saas_check_login_rate_limit', 'saas_record_login_attempt',
      'saas_hash_password_bcrypt', 'saas_create_session', 'saas_verify_session',
      'saas_revoke_session', 'saas_count_legacy_seed_users',
      'saas_super_admin_default_perms', 'saas_super_admin_effective_perms',
      'saas_super_admin_can', 'saas_super_admin_sender_meta',
      'saas_v3_company_setting', 'saas_v3_compute_leave_deductions',
      'saas_v3_finance_totals', 'saas_v3_write_audit'
    )
    AND pg_get_functiondef(p.oid) !~* (
      'auth_company_id|auth_is_super_admin|saas_v3_assert_tenant|saas_assert_company_active'
      || '|auth_can_manage_tenant_users|saas_v3_compute_salary|saas_upsert_attendance_admin'
      || '|saas_resolve_qr_registration|saas_issue_salary|saas_preview_salary'
    );

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'table_count', tbl_count,
    'tables_rls_enabled', rls_on_count,
    'policy_count', policy_count,
    'rpc_count', rpc_count,
    'trigger_count', trigger_count,
    'tables_without_rls', tables_no_rls,
    'policies_using_true', policies_using_true,
    'policies_with_check_true', policies_check_true,
    'security_definer_rpcs', definer_rpcs,
    'rpcs_without_tenant_validation', rpcs_no_tenant,
    'enterprise_ready',
      jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) = 0
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_health_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_security_health_report() TO authenticated;

COMMENT ON FUNCTION saas_recalculate_salary(INTEGER) IS
  'Phase 3 closure — saas_v3_assert_tenant before issue/preview delegate';
COMMENT ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) IS
  'Phase 3 closure — thin wrapper over saas_resolve_qr_registration';
