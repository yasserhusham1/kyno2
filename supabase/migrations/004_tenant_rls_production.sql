-- ============================================================
-- KYNO 004 — RLS إنتاجي صارم (عزل الشركات + حماية الجلسات)
-- شغّل بعد 001 + 002 + 003
--
-- ⚠️ مهم: سياسات العزل تعتمد على JWT (auth.jwt) بعد ربط Supabase Auth
-- أو إصدار Access Token من Edge Function عند تسجيل الدخول.
-- بدون JWT صالح، العميل (anon) لن يقرأ/يكتب جداول البيانات مباشرة — وهذا مقصود.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ============================================================
-- 0) company_id — إلزامي قبل RLS (إن لم تُشغّل الجزء SaaS من supabase_schema.sql)
-- ============================================================
ALTER TABLE employees        ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE attendance       ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE employee_devices ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE salary_records   ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE notifications    ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE departments      ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;

UPDATE employees        SET company_id = 1 WHERE company_id IS NULL;
UPDATE attendance       SET company_id = 1 WHERE company_id IS NULL;
UPDATE employee_devices SET company_id = 1 WHERE company_id IS NULL;
UPDATE salary_records   SET company_id = 1 WHERE company_id IS NULL;
UPDATE notifications    SET company_id = 1 WHERE company_id IS NULL;
UPDATE departments      SET company_id = 1 WHERE company_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_employees_company    ON employees(company_id);
CREATE INDEX IF NOT EXISTS idx_attendance_company   ON attendance(company_id);
CREATE INDEX IF NOT EXISTS idx_devices_company      ON employee_devices(company_id);
CREATE INDEX IF NOT EXISTS idx_salary_company       ON salary_records(company_id);
CREATE INDEX IF NOT EXISTS idx_notif_company        ON notifications(company_id);
CREATE INDEX IF NOT EXISTS idx_departments_company  ON departments(company_id);

-- ============================================================
-- 1) دوال مساعدة لقراءة claims من JWT
-- ============================================================
CREATE OR REPLACE FUNCTION auth_company_id()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT NULLIF(
    COALESCE(
      auth.jwt() -> 'app_metadata' ->> 'company_id',
      auth.jwt() ->> 'company_id'
    ),
    ''
  )::INTEGER;
$$;

CREATE OR REPLACE FUNCTION auth_app_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT COALESCE(
    auth.jwt() -> 'app_metadata' ->> 'role',
    auth.jwt() ->> 'role',
    ''
  );
$$;

CREATE OR REPLACE FUNCTION auth_is_super_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT auth_app_role() = 'super_admin';
$$;

CREATE OR REPLACE FUNCTION auth_tenant_owns_row(row_company_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND row_company_id IS NOT NULL
      AND row_company_id = auth_company_id()
    );
$$;

-- ============================================================
-- 2) saas_sessions — لا وصول مباشر من الواجهة (فقط service_role + RPC)
-- ============================================================
ALTER TABLE saas_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "saas_sessions_service_only" ON saas_sessions;
DROP POLICY IF EXISTS "saas_sessions_deny_all" ON saas_sessions;

CREATE POLICY "saas_sessions_deny_all" ON saas_sessions
  FOR ALL TO anon, authenticated
  USING (false) WITH CHECK (false);

-- service_role يتجاوز RLS تلقائياً عند Edge Functions

-- ============================================================
-- 3) saas_users — منع تسريب password_hash وعزل الشركات
-- ============================================================
ALTER TABLE saas_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_saas_users" ON saas_users;
DROP POLICY IF EXISTS "saas_users_deny_anon" ON saas_users;
DROP POLICY IF EXISTS "saas_users_select_tenant" ON saas_users;
DROP POLICY IF EXISTS "saas_users_modify_super" ON saas_users;

-- منع anon بالكامل (يوقف fallback القديم .eq('password_hash') من المتصفح)
CREATE POLICY "saas_users_deny_anon" ON saas_users
  FOR ALL TO anon
  USING (false) WITH CHECK (false);

-- authenticated: قراءة مستخدمي نفس الشركة فقط (بدون أعمدة حساسة عبر VIEW لاحقاً)
CREATE POLICY "saas_users_select_tenant" ON saas_users
  FOR SELECT TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      company_id IS NOT NULL
      AND company_id = auth_company_id()
    )
    OR id::text = auth.uid()::text
  );

CREATE POLICY "saas_users_insert_super" ON saas_users
  FOR INSERT TO authenticated
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

CREATE POLICY "saas_users_update_tenant" ON saas_users
  FOR UPDATE TO authenticated
  USING (auth_is_super_admin() OR company_id = auth_company_id())
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

CREATE POLICY "saas_users_delete_super" ON saas_users
  FOR DELETE TO authenticated
  USING (auth_is_super_admin());

-- إخفاء password_hash عن الأدوار العامة (عمودية)
REVOKE ALL ON TABLE saas_users FROM anon;
REVOKE ALL ON TABLE saas_users FROM authenticated;
GRANT SELECT (id, username, display_name, email, role, permissions, company_id, is_active, last_login, created_at)
  ON saas_users TO authenticated;
GRANT INSERT, UPDATE ON saas_users TO authenticated;

-- ============================================================
-- 4) companies & subscriptions
-- ============================================================
ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_companies" ON companies;
DROP POLICY IF EXISTS "anon_all_subscriptions" ON subscriptions;

CREATE POLICY "companies_deny_anon" ON companies
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "companies_select_tenant" ON companies
  FOR SELECT TO authenticated
  USING (auth_is_super_admin() OR id = auth_company_id());

CREATE POLICY "companies_modify_super" ON companies
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

CREATE POLICY "subscriptions_deny_anon" ON subscriptions
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "subscriptions_tenant" ON subscriptions
  FOR ALL TO authenticated
  USING (auth_is_super_admin() OR company_id = auth_company_id())
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

-- ============================================================
-- 5) employees — عزل company_id صارم (استبدال سياسات 002 الضعيفة)
-- ============================================================
ALTER TABLE employees ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_select_employees" ON employees;
DROP POLICY IF EXISTS "tenant_insert_employees" ON employees;
DROP POLICY IF EXISTS "tenant_update_employees" ON employees;
DROP POLICY IF EXISTS "tenant_delete_employees" ON employees;
DROP POLICY IF EXISTS "tenant_modify_employees" ON employees;
DROP POLICY IF EXISTS "anon_all_employees" ON employees;

CREATE POLICY "employees_deny_anon" ON employees
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "employees_select_tenant" ON employees
  FOR SELECT TO authenticated
  USING (auth_tenant_owns_row(company_id));

CREATE POLICY "employees_insert_tenant" ON employees
  FOR INSERT TO authenticated
  WITH CHECK (
    company_id IS NOT NULL
    AND auth_tenant_owns_row(company_id)
  );

CREATE POLICY "employees_update_tenant" ON employees
  FOR UPDATE TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (auth_tenant_owns_row(company_id));

CREATE POLICY "employees_delete_tenant" ON employees
  FOR DELETE TO authenticated
  USING (auth_tenant_owns_row(company_id));

-- ============================================================
-- 6) attendance
-- ============================================================
ALTER TABLE attendance ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_attendance_all" ON attendance;
DROP POLICY IF EXISTS "admin_all_attendance" ON attendance;
DROP POLICY IF EXISTS "anon_all_attendance" ON attendance;

CREATE POLICY "attendance_deny_anon" ON attendance
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "attendance_select_tenant" ON attendance
  FOR SELECT TO authenticated
  USING (auth_tenant_owns_row(company_id));

CREATE POLICY "attendance_insert_tenant" ON attendance
  FOR INSERT TO authenticated
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

CREATE POLICY "attendance_update_tenant" ON attendance
  FOR UPDATE TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (auth_tenant_owns_row(company_id));

CREATE POLICY "attendance_delete_tenant" ON attendance
  FOR DELETE TO authenticated
  USING (auth_tenant_owns_row(company_id));

-- ============================================================
-- 7) employee_devices — عبر company_id من employees
-- ============================================================
ALTER TABLE employee_devices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_devices_all" ON employee_devices;
DROP POLICY IF EXISTS "anon_all_devices" ON employee_devices;

CREATE POLICY "devices_deny_anon" ON employee_devices
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "devices_tenant" ON employee_devices
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = employee_devices.employee_id
        AND auth_tenant_owns_row(e.company_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = employee_devices.employee_id
        AND auth_tenant_owns_row(e.company_id)
    )
  );

-- ============================================================
-- 8) salary_records
-- ============================================================
ALTER TABLE salary_records ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_salary" ON salary_records;

CREATE POLICY "salary_deny_anon" ON salary_records
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "salary_tenant" ON salary_records
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = salary_records.employee_id
        AND auth_tenant_owns_row(e.company_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = salary_records.employee_id
        AND auth_tenant_owns_row(e.company_id)
    )
  );

-- ============================================================
-- 9) app_settings — مفاتيح عامة vs مفاتيح شركة (key: company:{id}:...)
-- ============================================================
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "settings_read" ON app_settings;
DROP POLICY IF EXISTS "settings_write" ON app_settings;
DROP POLICY IF EXISTS "settings_update" ON app_settings;
DROP POLICY IF EXISTS "anon_all_settings" ON app_settings;

CREATE POLICY "settings_deny_anon" ON app_settings
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "settings_select_tenant" ON app_settings
  FOR SELECT TO authenticated
  USING (
    auth_is_super_admin()
    OR key LIKE 'global:%'
    OR key LIKE ('company:' || auth_company_id()::text || ':%')
  );

CREATE POLICY "settings_write_tenant" ON app_settings
  FOR INSERT TO authenticated
  WITH CHECK (
    auth_is_super_admin()
    OR key LIKE ('company:' || auth_company_id()::text || ':%')
  );

CREATE POLICY "settings_update_tenant" ON app_settings
  FOR UPDATE TO authenticated
  USING (
    auth_is_super_admin()
    OR key LIKE ('company:' || auth_company_id()::text || ':%')
  )
  WITH CHECK (
    auth_is_super_admin()
    OR key LIKE ('company:' || auth_company_id()::text || ':%')
  );

-- ============================================================
-- 10) departments — company_id إلزامي
-- ============================================================
ALTER TABLE departments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_departments" ON departments;

CREATE POLICY "departments_deny_anon" ON departments
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "departments_tenant" ON departments
  FOR ALL TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

-- ============================================================
-- 11) notifications
-- ============================================================
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_notif" ON notifications;

CREATE POLICY "notifications_deny_anon" ON notifications
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "notifications_tenant" ON notifications
  FOR ALL TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

-- ============================================================
-- 12) audit_logs
-- ============================================================
DROP POLICY IF EXISTS "audit_insert_authenticated" ON audit_logs;
DROP POLICY IF EXISTS "audit_select_company" ON audit_logs;

CREATE POLICY "audit_insert_tenant" ON audit_logs
  FOR INSERT TO authenticated, anon
  WITH CHECK (
    company_id IS NULL
    OR auth_tenant_owns_row(company_id)
  );

CREATE POLICY "audit_select_tenant" ON audit_logs
  FOR SELECT TO authenticated
  USING (auth_tenant_owns_row(company_id) OR company_id IS NULL);

-- ============================================================
-- 13) تقييد RPCs الحساسة
-- ============================================================
REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_get_user_profile(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_user_profile(INTEGER) TO service_role;

-- منع enumerate users عبر anon
REVOKE EXECUTE ON FUNCTION saas_get_user_profile(INTEGER) FROM anon;
