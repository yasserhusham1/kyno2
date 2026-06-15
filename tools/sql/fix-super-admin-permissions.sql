-- استعد صلاحيات السوبر أدمن الكاملة (إذا كانت كلها false وتعطل القائمة)
UPDATE saas_users
SET permissions = '{}'::jsonb
WHERE role = 'super_admin'
  AND is_active IS TRUE;
