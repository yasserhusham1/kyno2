-- ============================================================
-- KYNO — أول سوبر أدمن (بعد تطبيق 000 + 001..084)
-- ⚠️ غيّر كلمة المرور قبل التشغيل
-- ============================================================

INSERT INTO saas_users (
  username, display_name, email,
  password_hash, password_algo,
  role, company_id, permissions, is_active
) VALUES (
  'yasser',
  'Super Admin',
  NULL,
  saas_hash_password_bcrypt('CHANGE_STRONG_PASSWORD_12+'),
  'bcrypt',
  'super_admin',
  NULL,
  '{}'::jsonb,
  TRUE
)
ON CONFLICT (username) DO UPDATE SET
  password_hash = EXCLUDED.password_hash,
  password_algo = 'bcrypt',
  role = 'super_admin',
  is_active = TRUE,
  permissions = '{}'::jsonb;

SELECT id, username, role, is_active FROM saas_users WHERE role = 'super_admin';
