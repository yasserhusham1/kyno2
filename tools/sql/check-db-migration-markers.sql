-- KYNO — فحص ما هو مطبّق فعلياً على Postgres (بدون schema_migrations)
-- شغّل في Supabase Dashboard → SQL Editor (قراءة فقط)

-- 1) هل جدول تتبع CLI موجود؟
SELECT EXISTS (
  SELECT 1 FROM information_schema.schemata WHERE schema_name = 'supabase_migrations'
) AS has_supabase_migrations_schema;

-- 2) علامات migrations رئيسية (true = موجود)
SELECT '031/056 saas_v3_assert_tenant' AS marker,
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_v3_assert_tenant') AS applied
UNION ALL
SELECT '033 lockdown (no direct INSERT on employees for authenticated)',
       NOT has_table_privilege('authenticated', 'public.employees', 'INSERT')
UNION ALL
SELECT '079 auth_session_is_revoked',
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'auth_session_is_revoked')
UNION ALL
SELECT '081 saas_check_login_rate_limit',
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_check_login_rate_limit')
UNION ALL
SELECT '082+ saas_security_health_report',
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_security_health_report')
UNION ALL
SELECT '084 report (verdict_ar in function body)',
       EXISTS (
         SELECT 1 FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'saas_security_health_report'
           AND pg_get_functiondef(p.oid) LIKE '%verdict_ar%'
       )
UNION ALL
SELECT '075 admin device manage RPC',
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_admin_upsert_employee_device')
UNION ALL
SELECT 'core table employees',
       EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'employees')
UNION ALL
SELECT 'RLS enabled on employees',
       EXISTS (
         SELECT 1 FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname = 'employees' AND c.relrowsecurity = TRUE
       );

-- 3) عدد الجداول والسياسات والدوال في public
SELECT
  (SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r') AS public_tables,
  (SELECT COUNT(*) FROM pg_policies WHERE schemaname = 'public') AS rls_policies,
  (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f') AS public_functions;

-- 4) anon SELECT على employees (يجب false بعد 084)
SELECT has_table_privilege('anon', 'public.employees', 'SELECT') AS anon_can_select_employees;
