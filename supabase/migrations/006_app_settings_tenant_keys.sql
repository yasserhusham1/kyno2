-- ============================================================
-- 006 — ترحيل مفاتيح app_settings إلى company:{id}:key (RLS 004)
-- آمن عند وجود مفاتيح company:1:… مسبقاً (لا duplicate key)
-- ============================================================

-- 1) احذف المفاتيح القديمة إذا النسخة الجديدة موجودة already
DELETE FROM app_settings AS old
WHERE old.key NOT LIKE 'company:%'
  AND old.key NOT LIKE 'global:%'
  AND EXISTS (
    SELECT 1 FROM app_settings AS newer
    WHERE newer.key = 'company:1:' || old.key
  );

-- 2) أعد تسمية ما تبقّى من مفاتيح قديمة
UPDATE app_settings
SET key = 'company:1:' || key
WHERE key NOT LIKE 'company:%'
  AND key NOT LIKE 'global:%';
