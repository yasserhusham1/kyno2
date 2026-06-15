-- 020 — RPC لجلب إعدادات المنصة (إشعارات + واتساب) للشركات المسجّلة

CREATE OR REPLACE FUNCTION get_platform_public_settings()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'support_whatsapp', COALESCE(
      (SELECT value FROM app_settings WHERE key = 'global:support_whatsapp' LIMIT 1),
      '07733344940'
    ),
    'support_whatsapp_team', COALESCE(
      NULLIF(TRIM((SELECT value FROM app_settings WHERE key = 'global:support_whatsapp_team' LIMIT 1)), ''),
      (SELECT value FROM app_settings WHERE key = 'global:support_whatsapp' LIMIT 1),
      '07733344940'
    ),
    'announcements', COALESCE(
      (SELECT value::jsonb FROM app_settings WHERE key = 'global:platform_announcements' LIMIT 1),
      '[]'::jsonb
    )
  );
$$;

REVOKE ALL ON FUNCTION get_platform_public_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_platform_public_settings() TO authenticated;
