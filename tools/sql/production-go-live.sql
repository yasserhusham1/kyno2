-- KYNO Production go-live (run in Supabase SQL Editor, in order)
-- Project: qalcnvygyjltmlauvzlk

-- 1) Migration markers (expect all applied = true)
-- Paste/run: tools/sql/check-db-migration-markers.sql

-- 2) Super admin (change password before RUN)
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

DELETE FROM login_attempts WHERE lower(username) = 'yasser';

SELECT id, username, role, is_active, password_algo
FROM saas_users WHERE role = 'super_admin';

-- 3) Platform WhatsApp (optional — login page support button)
-- SELECT get_platform_support_whatsapp();
