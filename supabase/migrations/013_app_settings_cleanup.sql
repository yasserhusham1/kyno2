-- ============================================================
-- 013 — تنظيف مفاتيح app_settings المكررة (قديمة vs company:1:)
-- يمنع عودة «شركة النخبة العراقية» من مفتاح قديم
-- شغّل بعد 006
-- ============================================================

DELETE FROM app_settings AS old
WHERE old.key NOT LIKE 'company:%'
  AND old.key NOT LIKE 'global:%'
  AND EXISTS (
    SELECT 1 FROM app_settings AS newer
    WHERE newer.key = 'company:1:' || old.key
  );

-- تأكد أن المفاتيح القديمة المتبقية أُعيدت تسميتها
UPDATE app_settings
SET key = 'company:1:' || key
WHERE key NOT LIKE 'company:%'
  AND key NOT LIKE 'global:%';
