-- ============================================================
-- 084 — إصلاح تقرير الأمان: إيجابيات خاطئة + قفل anon الحقيقي
-- ============================================================

-- ---------- إزالة صلاحيات anon غير الضرورية (بيانات + super RPCs) ----------
REVOKE ALL ON TABLE employees, attendance, salary_records, companies, subscriptions,
  saas_users, app_settings, audit_logs, departments, leaves, employee_notifications,
  login_attempts, saas_sessions
FROM anon;

REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM anon;

DO $$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'saas_super_upsert_company',
        'saas_super_delete_company',
        'saas_super_toggle_company_status',
        'saas_super_renew_subscription',
        'saas_super_delete_subscription',
        'saas_rotate_user_password',
        'saas_revoke_all_sessions_for_user',
        'saas_revoke_all_super_admin_sessions',
        'saas_revoke_auth_sessions_for_user',
        'saas_user_auth_email',
        'saas_save_platform_globals'
      )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', fn.sig);
  END LOOP;
END $$;

-- إعادة منح super RPCs للمصادقين فقط
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_super_upsert_company') THEN
    REVOKE ALL ON FUNCTION saas_super_upsert_company(JSONB) FROM PUBLIC, anon;
    GRANT EXECUTE ON FUNCTION saas_super_upsert_company(JSONB) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_super_delete_company') THEN
    REVOKE ALL ON FUNCTION saas_super_delete_company(INTEGER) FROM PUBLIC, anon;
    GRANT EXECUTE ON FUNCTION saas_super_delete_company(INTEGER) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_super_toggle_company_status') THEN
    REVOKE ALL ON FUNCTION saas_super_toggle_company_status(INTEGER, TEXT) FROM PUBLIC, anon;
    GRANT EXECUTE ON FUNCTION saas_super_toggle_company_status(INTEGER, TEXT) TO authenticated;
  END IF;
END $$;

-- ---------- تقرير محسّن — يفحص SELECT/INSERT/UPDATE/DELETE فقط ----------
CREATE OR REPLACE FUNCTION saas_security_health_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
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
  anon_data_grants JSONB;
  dangerous_rpc_anon JSONB;
  employee_portal_rpc_anon JSONB;
  critical_rls JSONB;
  findings JSONB := '[]'::jsonb;
  fail_logins_24h INTEGER := 0;
  fail_logins_15m INTEGER := 0;
  top_attack_ips JSONB := '[]'::jsonb;
  audit_deletes_24h INTEGER := 0;
  audit_perm_24h INTEGER := 0;
  audit_super_24h INTEGER := 0;
  super_admin_count INTEGER := 0;
  active_companies INTEGER := 0;
  suspended_companies INTEGER := 0;
  score INTEGER := 100;
  verdict TEXT := 'safe';
  verdict_ar TEXT;
  verdict_summary_ar TEXT;
  attack_suspected BOOLEAN := false;
  has_critical BOOLEAN := false;
  has_high BOOLEAN := false;
  enterprise_ready BOOLEAN;
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
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE
    AND p.proname LIKE 'saas_%'
    AND p.proname NOT IN (
      'saas_verify_login', 'saas_force_reset_password', 'saas_fetch_employee_attendance',
      'saas_fetch_employee_salary_records', 'saas_fetch_employee_notifications',
      'saas_fetch_employee_client_profile', 'saas_fetch_employee_leaves',
      'saas_upsert_attendance_by_device', 'saas_upsert_attendance_employee',
      'saas_link_device_by_token', 'saas_mark_employee_portal_notification_read',
      'saas_get_company_subscription_status', 'saas_logout_self',
      'saas_revoke_all_sessions_for_user', 'saas_revoke_all_super_admin_sessions',
      'saas_revoke_auth_sessions_for_user', 'saas_rotate_user_password',
      'saas_super_admin_user_id', 'saas_user_auth_email',
      'saas_security_health_report', 'saas_v3_audit_rls_report', 'saas_security_grants_audit',
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
      'saas_v3_finance_totals', 'saas_v3_write_audit', 'saas_v3_employee_portal_authorize'
    )
    AND pg_get_functiondef(p.oid) !~* (
      'auth_company_id|auth_is_super_admin|saas_v3_assert_tenant|saas_assert_company_active'
      || '|auth_can_manage_tenant_users|saas_v3_compute_salary|saas_upsert_attendance_admin'
      || '|saas_resolve_qr_registration|saas_issue_salary|saas_preview_salary'
      || '|saas_v3_employee_portal_authorize|auth_jwt_saas_user_id_raw|auth\.uid\(\)'
    );

  -- صلاحيات بيانات anon فقط (SELECT/INSERT/UPDATE/DELETE) — REFERENCES/TRIGGER ليست ثغرة
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', table_name, 'privilege', privilege_type
  ) ORDER BY table_name, privilege_type), '[]'::jsonb) INTO anon_data_grants
  FROM information_schema.role_table_grants
  WHERE grantee = 'anon' AND table_schema = 'public'
    AND privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
    AND table_name IN (
      'employees', 'attendance', 'salary_records', 'companies', 'subscriptions',
      'saas_users', 'app_settings', 'audit_logs', 'departments', 'leaves',
      'employee_notifications', 'login_attempts', 'saas_sessions'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'function', p.proname, 'grantee', grantee.rolname
  ) ORDER BY p.proname), '[]'::jsonb) INTO dangerous_rpc_anon
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
  JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND grantee.rolname IN ('anon', 'public')
    AND p.proname IN (
      'saas_rotate_user_password', 'saas_super_upsert_company', 'saas_super_delete_company',
      'saas_super_toggle_company_status', 'saas_super_renew_subscription',
      'saas_super_delete_subscription', 'saas_save_platform_globals',
      'saas_revoke_all_sessions_for_user', 'saas_user_auth_email'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'function', p.proname, 'grantee', grantee.rolname
  ) ORDER BY p.proname), '[]'::jsonb) INTO employee_portal_rpc_anon
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
  JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND grantee.rolname = 'anon'
    AND p.proname IN (
      'saas_fetch_employee_attendance', 'saas_fetch_employee_salary_records',
      'saas_fetch_employee_notifications', 'saas_fetch_employee_leaves',
      'saas_fetch_employee_client_profile', 'saas_mark_employee_portal_notification_read',
      'saas_v3_employee_portal_authorize', 'saas_verify_login',
      'saas_get_company_subscription_status', 'saas_link_device_by_token',
      'saas_resolve_qr_registration', 'saas_lookup_device_registration'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', c.relname, 'rls_enabled', c.relrowsecurity
  ) ORDER BY c.relname), '[]'::jsonb) INTO critical_rls
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
    AND c.relname IN (
      'employees', 'attendance', 'salary_records', 'companies', 'subscriptions',
      'saas_users', 'app_settings', 'audit_logs', 'departments', 'leaves'
    )
    AND c.relrowsecurity IS NOT TRUE;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'login_attempts') THEN
    SELECT COUNT(*) INTO fail_logins_24h
    FROM login_attempts WHERE success = false AND created_at >= NOW() - INTERVAL '24 hours';
    SELECT COUNT(*) INTO fail_logins_15m
    FROM login_attempts WHERE success = false AND created_at >= NOW() - INTERVAL '15 minutes';
    SELECT COALESCE(jsonb_agg(jsonb_build_object('ip', sub.ip_address, 'attempts', sub.cnt) ORDER BY sub.cnt DESC), '[]'::jsonb)
    INTO top_attack_ips
    FROM (
      SELECT ip_address, COUNT(*) AS cnt FROM login_attempts
      WHERE success = false AND created_at >= NOW() - INTERVAL '24 hours' AND COALESCE(ip_address, '') <> ''
      GROUP BY ip_address ORDER BY cnt DESC LIMIT 5
    ) sub;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'audit_logs') THEN
    SELECT COUNT(*) INTO audit_deletes_24h FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (action ILIKE '%delete%' OR action ILIKE '%حذف%' OR details ILIKE '%delete%' OR details ILIKE '%حذف%');
    SELECT COUNT(*) INTO audit_perm_24h FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (action ILIKE '%perm%' OR details ILIKE '%perm%' OR details ILIKE '%صلاح%');
    SELECT COUNT(*) INTO audit_super_24h FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (actor_role = 'super_admin' OR details ILIKE '%super_admin%');
  END IF;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'saas_users') THEN
    SELECT COUNT(*) INTO super_admin_count FROM saas_users WHERE role = 'super_admin' AND is_active IS TRUE;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'companies') THEN
    SELECT COUNT(*) INTO active_companies FROM companies WHERE status = 'active';
    SELECT COUNT(*) INTO suspended_companies FROM companies WHERE status = 'suspended';
  END IF;

  enterprise_ready :=
    jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(rpcs_no_tenant, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(anon_data_grants, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(dangerous_rpc_anon, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(critical_rls, '[]'::jsonb)) = 0;

  -- findings
  IF jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) > 0 THEN
    has_critical := true; score := score - 35;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'tables_no_rls', 'severity', 'critical', 'status', 'fail',
      'title_ar', 'جداول عامة بدون عزل RLS',
      'detail_ar', 'يوجد ' || jsonb_array_length(tables_no_rls)::text || ' جدول/جداول بدون RLS — خطر تسرب بيانات بين الشركات.',
      'recommendation_ar', 'فعّل RLS فوراً على كل الجداول الحساسة.',
      'count', jsonb_array_length(tables_no_rls), 'items', tables_no_rls));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'tables_no_rls', 'severity', 'info', 'status', 'pass',
      'title_ar', 'عزل الجداول (RLS)', 'detail_ar', 'جميع الجداول العامة محمية بـ RLS.',
      'recommendation_ar', '—', 'count', 0, 'items', '[]'::jsonb));
  END IF;

  IF jsonb_array_length(COALESCE(anon_data_grants, '[]'::jsonb)) > 0 THEN
    has_critical := true; score := score - 40;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'anon_data_grants', 'severity', 'critical', 'status', 'fail',
      'title_ar', 'صلاحيات anon لقراءة/كتابة البيانات',
      'detail_ar', 'دور anon يملك SELECT/INSERT/UPDATE/DELETE على جداول حساسة — ثغرة حقيقية.',
      'recommendation_ar', 'نفّذ: REVOKE ALL ON TABLE ... FROM anon; وREVOKE SELECT ON ALL TABLES FROM anon;',
      'count', jsonb_array_length(anon_data_grants), 'items', anon_data_grants));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'anon_data_grants', 'severity', 'info', 'status', 'pass',
      'title_ar', 'حماية anon على الجداول',
      'detail_ar', 'لا توجد صلاحيات SELECT/INSERT/UPDATE/DELETE لـ anon على الجداول الحساسة. (REFERENCES/TRIGGER لا تُعد ثغرة)',
      'recommendation_ar', '—', 'count', 0, 'items', '[]'::jsonb));
  END IF;

  IF jsonb_array_length(COALESCE(dangerous_rpc_anon, '[]'::jsonb)) > 0 THEN
    has_critical := true; score := score - 45;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'dangerous_rpc_anon', 'severity', 'critical', 'status', 'fail',
      'title_ar', 'دوال Super Admin / حساسة مفتوحة لـ anon',
      'detail_ar', 'RPCs إدارية متاحة لـ anon أو PUBLIC — يجب تقييدها على authenticated فقط.',
      'recommendation_ar', 'طبّق migration 084 أو REVOKE EXECUTE FROM anon, PUBLIC على هذه الدوال.',
      'count', jsonb_array_length(dangerous_rpc_anon), 'items', dangerous_rpc_anon));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'dangerous_rpc_anon', 'severity', 'info', 'status', 'pass',
      'title_ar', 'دوال Super Admin محمية',
      'detail_ar', 'لا توجد RPCs إدارية خطرة متاحة لـ anon.',
      'recommendation_ar', '—', 'count', 0, 'items', '[]'::jsonb));
  END IF;

  IF jsonb_array_length(COALESCE(employee_portal_rpc_anon, '[]'::jsonb)) > 0 THEN
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'employee_portal_anon_rpc', 'severity', 'info', 'status', 'pass',
      'title_ar', 'بوابة الموظف (anon RPCs — مقصود)',
      'detail_ar', jsonb_array_length(employee_portal_rpc_anon)::text
        || ' دالة anon لبوابة الموظف — محمية داخلياً بـ saas_v3_employee_portal_authorize وبصمة الجهاز.',
      'recommendation_ar', 'لا إجراء — هذا التصميم مقصود. تأكد فقط من RLS على الجداول.',
      'count', jsonb_array_length(employee_portal_rpc_anon), 'items', employee_portal_rpc_anon));
  END IF;

  IF jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) > 0
     OR jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) > 0 THEN
    has_high := true; score := score - 15;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'policies_literal_true', 'severity', 'high', 'status', 'warn',
      'title_ar', 'سياسات RLS مفتوحة (true)',
      'detail_ar', 'توجد policies تستخدم USING(true) أو WITH CHECK(true).',
      'recommendation_ar', 'استبدل true بشروط auth.uid() أو auth_company_id().',
      'count', jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb))
        + jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)),
      'items', COALESCE(policies_using_true, '[]'::jsonb) || COALESCE(policies_check_true, '[]'::jsonb)));
  END IF;

  IF jsonb_array_length(COALESCE(rpcs_no_tenant, '[]'::jsonb)) > 0 THEN
    has_high := true; score := score - 8;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'rpcs_no_tenant', 'severity', 'medium', 'status', 'warn',
      'title_ar', 'RPCs للمراجعة اليدوية',
      'detail_ar', jsonb_array_length(rpcs_no_tenant)::text || ' دالة بدون تحقق tenant ظاهر في الكود — راجعها.',
      'recommendation_ar', 'تأكد أن كل RPC يتحقق من الشركة أو يكون في whitelist.',
      'count', jsonb_array_length(rpcs_no_tenant), 'items', rpcs_no_tenant));
  END IF;

  IF fail_logins_15m >= 30 OR fail_logins_24h >= 150 THEN
    attack_suspected := true; has_critical := true; score := score - 25;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force_attack', 'severity', 'critical', 'status', 'fail',
      'title_ar', 'هجوم تخمين كلمات المرور',
      'detail_ar', fail_logins_15m::text || ' فاشلة / 15د، ' || fail_logins_24h::text || ' / 24س.',
      'recommendation_ar', 'راجع login_attempts وحظر IPs المشبوهة.',
      'count', fail_logins_24h, 'items', top_attack_ips));
  ELSIF fail_logins_24h >= 40 THEN
    has_high := true; score := score - 10;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force_elevated', 'severity', 'high', 'status', 'warn',
      'title_ar', 'محاولات دخول فاشلة مرتفعة',
      'detail_ar', fail_logins_24h::text || ' محاولة فاشلة / 24 ساعة.',
      'recommendation_ar', 'راقب الحسابات المستهدفة.',
      'count', fail_logins_24h, 'items', top_attack_ips));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force', 'severity', 'info', 'status', 'pass',
      'title_ar', 'محاولات الدخول', 'detail_ar', 'لا هجوم واضح (' || fail_logins_24h::text || ' فاشلة / 24س).',
      'recommendation_ar', '—', 'count', fail_logins_24h, 'items', top_attack_ips));
  END IF;

  IF audit_deletes_24h >= 25 THEN
    attack_suspected := true; has_high := true; score := score - 12;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'mass_deletes', 'severity', 'high', 'status', 'warn',
      'title_ar', 'حذف جماعي مشبوه',
      'detail_ar', audit_deletes_24h::text || ' عملية حذف / 24 ساعة.',
      'recommendation_ar', 'راجع audit_logs.',
      'count', audit_deletes_24h, 'items', '[]'::jsonb));
  END IF;

  score := GREATEST(0, LEAST(100, score));

  IF attack_suspected AND (has_critical OR fail_logins_24h >= 100) THEN
    verdict := 'attack_suspected';
    verdict_ar := '⚠️ نشاط مشبوه — احتمال هجوم';
    verdict_summary_ar := 'رُصدت محاولات دخول أو نشاط غير طبيعي. راجع السجلات فوراً.';
  ELSIF has_critical OR score < 50 THEN
    verdict := 'critical';
    verdict_ar := '🔴 خطر أمني حرج';
    verdict_summary_ar := 'ثغرات حقيقية في RLS أو صلاحيات anon أو RPCs إدارية — عالج فوراً.';
  ELSIF has_high OR score < 80 OR NOT enterprise_ready THEN
    verdict := 'warning';
    verdict_ar := '🟡 تحذير — مراجعة مطلوبة';
    verdict_summary_ar := 'لا دليل على اختراق، لكن توجد نقاط تحتاج مراجعة.';
  ELSE
    verdict := 'safe';
    verdict_ar := '🟢 آمن — لم يُكتشَف اختراق';
    verdict_summary_ar := 'RLS، anon، RPCs، ومحاولات الدخول ضمن المستوى المقبول.';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'verdict', verdict,
    'verdict_ar', verdict_ar,
    'verdict_summary_ar', verdict_summary_ar,
    'security_score', score,
    'attack_suspected', attack_suspected,
    'compromised_confirmed', false,
    'findings', findings,
    'metrics', jsonb_build_object(
      'failed_logins_24h', fail_logins_24h,
      'failed_logins_15m', fail_logins_15m,
      'audit_deletes_24h', audit_deletes_24h,
      'audit_permission_changes_24h', audit_perm_24h,
      'audit_super_admin_actions_24h', audit_super_24h,
      'super_admin_active_count', super_admin_count,
      'active_companies', active_companies,
      'suspended_companies', suspended_companies
    ),
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
    'anon_table_grants', anon_data_grants,
    'anon_data_grants', anon_data_grants,
    'critical_rpc_anon_grants', dangerous_rpc_anon,
    'dangerous_rpc_anon_grants', dangerous_rpc_anon,
    'employee_portal_anon_rpcs', employee_portal_rpc_anon,
    'critical_tables_rls_off', critical_rls,
    'top_attack_ips', top_attack_ips,
    'enterprise_ready', enterprise_ready
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_health_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_security_health_report() TO authenticated;

COMMENT ON FUNCTION saas_security_health_report() IS
  '084 — فحص دقيق: anon data grants فقط، whitelist بوابة الموظف، قفل super RPCs';
