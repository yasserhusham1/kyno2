-- 019 — رقم واتساب فريق الدعم (منفصل عن تفعيل الاشتراك)

INSERT INTO app_settings (key, value, updated_at)
VALUES ('global:support_whatsapp_team', '07733344940', NOW())
ON CONFLICT (key) DO NOTHING;
