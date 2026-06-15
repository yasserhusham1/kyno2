-- ============================================================
-- KYNO — تفريغ البيانات فقط (نفس المشروع، نفس الـ schema)
-- ⚠️ يحذف: شركات، موظفين، حضور، مستخدمين، سجلات…
-- ⚠️ لا يحذف: Saved Queries في SQL Editor (من Dashboard يدوياً)
-- شغّل في SQL Editor مرة واحدة
-- ============================================================

BEGIN;

-- جلسات ومحاولات
TRUNCATE TABLE saas_sessions RESTART IDENTITY CASCADE;
TRUNCATE TABLE login_attempts RESTART IDENTITY CASCADE;
TRUNCATE TABLE api_rate_attempts RESTART IDENTITY CASCADE;

-- بيانات تشغيلية (ترتيب FK)
TRUNCATE TABLE attendance RESTART IDENTITY CASCADE;
TRUNCATE TABLE salary_records RESTART IDENTITY CASCADE;
TRUNCATE TABLE employee_devices RESTART IDENTITY CASCADE;
TRUNCATE TABLE leaves RESTART IDENTITY CASCADE;
TRUNCATE TABLE employee_notifications RESTART IDENTITY CASCADE;
TRUNCATE TABLE admin_notifications RESTART IDENTITY CASCADE;
TRUNCATE TABLE notifications RESTART IDENTITY CASCADE;
TRUNCATE TABLE employees RESTART IDENTITY CASCADE;
TRUNCATE TABLE departments RESTART IDENTITY CASCADE;
TRUNCATE TABLE audit_logs RESTART IDENTITY CASCADE;
TRUNCATE TABLE subscriptions RESTART IDENTITY CASCADE;
TRUNCATE TABLE saas_users RESTART IDENTITY CASCADE;
TRUNCATE TABLE companies RESTART IDENTITY CASCADE;

-- إعدادات (اختياري — احذف التعليق إن أردت مسح إعدادات المنصة أيضاً)
-- TRUNCATE TABLE app_settings RESTART IDENTITY CASCADE;

COMMIT;

-- ---------- إنشاء أول سوبر أدمن (غيّر كلمة المرور فوراً) ----------
-- استبدل YOUR_STRONG_PASSWORD_12+ بكلمة مرور قوية
INSERT INTO saas_users (
  username, display_name, email,
  password_hash, password_algo,
  role, company_id, permissions, is_active
) VALUES (
  'yasser',
  'Super Admin',
  NULL,
  saas_hash_password_bcrypt('YOUR_STRONG_PASSWORD_12+'),
  'bcrypt',
  'super_admin',
  NULL,
  '{}'::jsonb,
  TRUE
);

-- تحقق
SELECT id, username, role, is_active FROM saas_users WHERE role = 'super_admin';
