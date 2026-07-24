# KYNO v2 — Environment Variables

توثيق متغيرات البيئة — الضرورية والاختيارية.

---

## 1. الملفات

| الملف | الوصف | في Git؟ |
|-------|-------|---------|
| `.env.example` | مثال بقيم وهمية — للتوثيق | ✅ نعم |
| `.env.local` | القيم الفعلية للتطوير المحلي | ❌ في .gitignore |
| Supabase Secrets | متغيرات الإنتاج في Supabase Dashboard | ❌ في Supabase فقط |

---

## 2. المتغيرات المطلوبة

### Supabase Connection
```
KYNO_SUPABASE_URL=https://xxxx.supabase.co
KYNO_SUPABASE_ANON_KEY=eyJhbGciOi...
KYNO_SUPABASE_SERVICE_KEY=eyJhbGciOi... ← للـ Edge Functions فقط
```

### Authentication
```
KYNO_JWT_SECRET=your-super-secret-jwt-key-min-32-chars
KYNO_JWT_EXPIRY=3600          ← ثوانٍ (1 ساعة)
KYNO_REFRESH_TOKEN_EXPIRY=604800  ← ثوانٍ (7 أيام)
```

### Application
```
KYNO_APP_ENV=development         ← development | staging | production
KYNO_APP_URL=http://localhost:3000
KYNO_APP_NAME=KYNO
```

---

## 3. المتغيرات الاختيارية

```
KYNO_SENTRY_DSN=https://...@sentry.io/...    ← للـ Error Monitoring
KYNO_WHATSAPP_API_KEY=...                    ← للإشعارات عبر WhatsApp
KYNO_MAX_LOGIN_ATTEMPTS=5                   ← محاولات قبل الحظر
KYNO_LOGIN_LOCKOUT_MINUTES=15               ← مدة الحظر
```

---

## 4. متغيرات Edge Functions (Supabase Secrets)

تُضبط عبر Supabase Dashboard أو CLI — **لا تُكتب في ملفات**:

```
SUPABASE_URL            ← تلقائي في Edge Functions
SUPABASE_SERVICE_KEY    ← تلقائي في Edge Functions
KYNO_JWT_SECRET         ← يُضبط يدوياً
```

---

## 5. قواعد صارمة

```
❌ لا تُكتب قيم حقيقية في .env.example
❌ لا تُكتب credentials في أي ملف مُضمَّن في Git
❌ لا console.log للمتغيرات الحساسة
✅ استخدم KYNO_ prefix لجميع المتغيرات الخاصة بالمشروع
✅ وثّق كل متغير جديد هنا فوراً
✅ قيم الـ production تكون في Supabase Secrets فقط
```

---

## 6. ملف .env.example

```env
# Supabase Connection
KYNO_SUPABASE_URL=https://your-project.supabase.co
KYNO_SUPABASE_ANON_KEY=your-anon-key-here

# Authentication
KYNO_JWT_SECRET=your-min-32-char-secret-here
KYNO_JWT_EXPIRY=3600
KYNO_REFRESH_TOKEN_EXPIRY=604800

# Application
KYNO_APP_ENV=development
KYNO_APP_URL=http://localhost:3000
KYNO_APP_NAME=KYNO

# Optional
# KYNO_SENTRY_DSN=
# KYNO_WHATSAPP_API_KEY=
```

---

*هذا الملف جزء من KYNO v2 — Project Foundation*
