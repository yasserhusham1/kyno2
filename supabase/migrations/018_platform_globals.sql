-- 018 — إعدادات المنصة العامة: واتساب الدعم + إشعارات البث للشركات

INSERT INTO app_settings (key, value, updated_at)
VALUES
  ('global:support_whatsapp', '07733344940', NOW()),
  ('global:platform_announcements', '[]', NOW())
ON CONFLICT (key) DO NOTHING;

-- رقم واتساب الدعم — قابل للقراءة قبل تسجيل الدخول (صفحة الدخول)
CREATE OR REPLACE FUNCTION get_platform_support_whatsapp()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT value FROM app_settings WHERE key = 'global:support_whatsapp' LIMIT 1),
    '07733344940'
  );
$$;

REVOKE ALL ON FUNCTION get_platform_support_whatsapp() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_platform_support_whatsapp() TO anon, authenticated;
