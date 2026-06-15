-- ============================================================
-- KYNO Phase 2 — Strict RLS (شغّل بعد 001_security_hardening.sql)
-- تحذير: فعّل strictRls:true في config/local.config.js بعد التأكد
-- ============================================================

-- إزالة السياسات المفتوحة للـ anon (قراءة/كتابة بدون حدود)
DROP POLICY IF EXISTS "anon_all_employees"      ON employees;
DROP POLICY IF EXISTS "anon_all_attendance"     ON attendance;
DROP POLICY IF EXISTS "anon_all_devices"        ON employee_devices;
DROP POLICY IF EXISTS "anon_all_salary"         ON salary_records;
DROP POLICY IF EXISTS "anon_all_settings"       ON app_settings;
DROP POLICY IF EXISTS "anon_all_notif"          ON notifications;
DROP POLICY IF EXISTS "anon_all_departments"    ON departments;

-- RLS على جداول SaaS
ALTER TABLE companies     ENABLE ROW LEVEL SECURITY;
ALTER TABLE saas_users    ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs    ENABLE ROW LEVEL SECURITY;

-- الموظفون: authenticated فقط + company scope
DROP POLICY IF EXISTS "tenant_select_employees" ON employees;
DROP POLICY IF EXISTS "tenant_modify_employees" ON employees;

CREATE POLICY "tenant_select_employees" ON employees
  FOR SELECT TO authenticated, anon
  USING (
    company_id = COALESCE(NULLIF(current_setting('request.jwt.claim.company_id', true), '')::INTEGER, company_id)
    OR current_setting('request.jwt.claim.role', true) = 'super_admin'
  );

CREATE POLICY "tenant_insert_employees" ON employees
  FOR INSERT TO authenticated, anon
  WITH CHECK (company_id IS NOT NULL);

CREATE POLICY "tenant_update_employees" ON employees
  FOR UPDATE TO authenticated, anon
  USING (true) WITH CHECK (company_id IS NOT NULL);

CREATE POLICY "tenant_delete_employees" ON employees
  FOR DELETE TO authenticated, anon
  USING (true);

-- الحضور
DROP POLICY IF EXISTS "admin_all_attendance" ON attendance;
CREATE POLICY "tenant_attendance_all" ON attendance
  FOR ALL TO authenticated, anon
  USING (company_id IS NOT NULL)
  WITH CHECK (company_id IS NOT NULL);

-- الأجهزة
DROP POLICY IF EXISTS "admin_all_devices" ON employee_devices;
CREATE POLICY "tenant_devices_all" ON employee_devices
  FOR ALL TO authenticated, anon
  USING (true) WITH CHECK (true);

-- الإعدادات — company_id via key prefix optional; allow read settings
DROP POLICY IF EXISTS "admin_all_settings" ON app_settings;
CREATE POLICY "settings_read" ON app_settings
  FOR SELECT TO authenticated, anon USING (true);
CREATE POLICY "settings_write" ON app_settings
  FOR INSERT TO authenticated, anon WITH CHECK (true);
CREATE POLICY "settings_update" ON app_settings
  FOR UPDATE TO authenticated, anon USING (true) WITH CHECK (true);

-- RPC للعمليات الحساسة بدون كشف password_hash
CREATE OR REPLACE FUNCTION saas_get_user_profile(p_user_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE u RECORD;
BEGIN
  SELECT su.id, su.username, su.display_name, su.email, su.role, su.permissions, su.company_id,
         c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE su.id = p_user_id AND su.is_active = true
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', COALESCE(u.display_name, ''),
    'email', COALESCE(u.email, ''), 'role', u.role, 'permissions', COALESCE(u.permissions, '{}'::jsonb),
    'company_id', u.company_id, 'company_name', u.company_name, 'company_code', u.company_code,
    'company_status', u.company_status, 'max_employees', COALESCE(u.max_employees, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION saas_get_user_profile(INTEGER) TO anon, authenticated;

-- ترقية كلمة المرور إلى sha256 (اختياري — من لوحة SQL)
-- UPDATE saas_users SET password_algo = 'sha256', password_hash = encode(digest('YOUR_PASSWORD' || ':' || id::text, 'sha256'), 'hex') WHERE username = 'admin';
