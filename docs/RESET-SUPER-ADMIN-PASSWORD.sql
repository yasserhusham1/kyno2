-- ============================================================
-- إعادة تعيين كلمة مرور السوبر أدمن (Production)
-- نفّذ في Supabase SQL Editor
-- ============================================================

-- 1) تحقق من الحسابات:
SELECT id, username, role, is_active, password_algo,
       left(password_hash, 20) AS hash_prefix,
       force_password_reset, last_login
FROM saas_users
WHERE role = 'super_admin'
ORDER BY id;

-- 2) توليد bcrypt لكلمة مرور جديدة (غيّر النص):
SELECT saas_hash_password_bcrypt('1998@@1998') AS new_hash;

-- 3) تحديث (استبدل USERNAME و HASH من الخطوة 2):
/*
UPDATE saas_users
SET
  password_hash = '$2a$12$....',
  password_algo = 'bcrypt',
  force_password_reset = false,
  is_active = true,
  updated_at = NOW()
WHERE lower(username) = 'superadmin';
*/

-- 4) مسح محاولات الدخول الفاشلة (إن وُجد rate limit):
-- DELETE FROM login_attempts WHERE lower(username) = 'superadmin';

-- 5) اختبار RPC مباشرة (اختياري — من SQL فقط، ليس كلمة المرور الحقيقية في السجل):
-- SELECT saas_verify_login('superadmin', 'YourNewPassword123', NULL);
