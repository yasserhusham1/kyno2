# config/

ملفات الإعداد — **لا secrets هنا أبداً**.

---

## الملفات

| الملف | الوصف | في Git؟ |
|-------|-------|---------|
| `public.config.js` | إعدادات عامة آمنة للعرض | ✅ نعم |
| `local.config.example.js` | مثال للإعداد المحلي | ✅ نعم |
| `local.config.js` | الإعداد المحلي الفعلي | ❌ في .gitignore |
| `supabase.defaults.js` | إعدادات Supabase الافتراضية | ✅ نعم |

---

## القاعدة

```
✅ public.config.js    ← URL المنصة، اسم التطبيق، إعدادات عامة
✅ supabase.defaults.js ← Default timeouts, retry counts
❌ لا تضع API Keys هنا
❌ لا تضع passwords هنا
❌ لا تضع JWT secrets هنا
```

**كل السيكريتس في `.env.local` (خارج Git)**
