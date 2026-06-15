-- Run in Supabase Dashboard → SQL Editor (read-only check)
SELECT id, username, display_name, role, is_active,
       password_algo, force_password_reset, last_login
FROM saas_users
WHERE role = 'super_admin'
ORDER BY id;

-- Recent failed login attempts (rate limit)
SELECT username, ip_address, success, created_at
FROM login_attempts
WHERE lower(username) IN (SELECT lower(username) FROM saas_users WHERE role = 'super_admin')
ORDER BY created_at DESC
LIMIT 20;
