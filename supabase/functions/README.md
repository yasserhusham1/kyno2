# Supabase Edge Functions

## هيكل الملفات

```
functions/
  deno.json              ← إعدادات Deno للمحرر (محلي)
  _shared/
    session.ts           ← CORS، cookies، tokens
    types.ts             ← parseSaasUser
    supabase.ts          ← createServiceClient
  auth-login/deno.json + index.ts
  auth-session/...
  auth-logout/...
  auth-set-password/...
```

## أخطاء شائعة في المحرر

1. **`Cannot find name 'Deno'`** — فعّل Deno لمجلد `supabase/functions` (انظر `.vscode/settings.json`).
2. **`Cannot find module '../_shared/...'`** — استخدم الاستيراد `@shared/...` مع `deno.json` في كل دالة.
3. **`Property 'id' does not exist on type 'Json'`** — استخدم `parseSaasUser()` من `@shared/types.ts`.

## النشر

**قبل النشر** (نسخ `_shared` داخل كل دالة — يمنع خطأ `Module not found _shared/session.ts`):

```powershell
powershell -File tools/prepare-edge-functions.ps1
```

### عبر CLI

```bash
supabase link --project-ref qalcnvygyjltmlauvzlk
supabase functions deploy auth-login --no-verify-jwt
supabase functions deploy auth-session --no-verify-jwt
supabase functions deploy auth-logout --no-verify-jwt
supabase functions deploy auth-set-password --no-verify-jwt
```

### بدون CLI (Management API)

```powershell
$env:SUPABASE_ACCESS_TOKEN = 'sbp_...'
powershell -File tools/deploy-edge-auth-api.ps1
```

### من لوحة Supabase (Dashboard)

لا تلصق `index.ts` فقط — يجب رفع مجلد الدالة كاملاً بما فيه `_shared/` (أو استخدم CLI/API أعلاه).
`auth-login` فقط يمكن لصقه كملف واحد (بدون imports).

(لا حاجة لـ `supabase secrets set SUPABASE_SERVICE_ROLE_KEY` — المفتاح مُحقَن تلقائياً من Supabase)

### إعداد من لوحة Supabase (Dashboard)

1. **Edge Functions → auth-login → Settings** → أوقف **Enforce JWT Verification** (Verify JWT = OFF)
2. **لا تضف** Secret باسم `SUPABASE_SERVICE_ROLE_KEY` — Supabase يحقن تلقائياً:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`
   (رسالة «Name must not start with the SUPABASE_ prefix» طبيعية — تجاهلها)
3. **Test** — افتح في المتصفح (Console):

```javascript
fetch('https://YOUR_PROJECT.supabase.co/functions/v1/auth-login', {
  headers: { apikey: 'YOUR_ANON_KEY', Authorization: 'Bearer YOUR_ANON_KEY' }
}).then(r => r.json()).then(console.log).catch(console.error);
```

يجب أن ترى: `{ ok: true, fn: "auth-login", has_service_role: true, ... }`

إذا `has_service_role: false` → أضف الـ Secret وأعد النشر.

## متطلبات SQL

شغّل `supabase/migrations/003_auth_sessions_bcrypt.sql` قبل استخدام الجلسات.
