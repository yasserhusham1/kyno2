# دليل إعادة بناء قاعدة بيانات KYNO v1 + النشر على Netlify

**الحالة:** قاعدة البيانات القديمة (`qalcnvygyjtlmlauvzlk.supabase.co`) محذوفة.
**الهدف:** إنشاء مشروع Supabase جديد، تطبيق الـ 86 migration، نشر الـ Edge Functions، ثم نشر الواجهة على Netlify.

---

## الخطوة 0 — ما تم تنظيفه في المشروع (مهم قبل البدء)

- ✅ حُذف الـ proxy بالكامل (الملف + كل المراجع في 5 ملفات + netlify.toml).
- ✅ الاتصال الآن **مباشر** مع Supabase عبر anon key (محمي بـ RLS) — هذا هو النمط الطبيعي.
- ✅ `netlify.toml` يPublish من جذر المشروع بدون build.
- ✅ حُذف 9 ملفات ميتة/مكسورة (4 JS غير مستدعاة + 5 سكربتات PS1 تعتمد على proxy).
- ⚠️ `config/supabase.defaults.js` لا يزال يحمل **URL + anon key القديمة (المحذوفة)** — يجب تحديثه في الخطوة 4.

---

## الخطوة 1 — إنشاء مشروع Supabase جديد

1. اذهب إلى https://supabase.com → **New project**.
2. اختر اسماً (مثلاً `kyno-v1-restore`)، كلمة مرور قوية لقاعدة البيانات، ومنطقة قريبة (EU/Frankfurt غالباً).
3. انتظر حتى يكتمل provisioning (دقيقة-دقيقتين).
4. من **Project Settings → API**، احفظ:
   - `Project URL` (مثلاً `https://xxxx.supabase.co`)
   - `anon public` key
   - `service_role` key (سري — لا يوضع في الواجهة أبداً)
   - `Project ref` (من Settings → API، أو من URL Dashboard)

---

## الخطوة 2 — تطبيق الـ 86 migration لإنشاء الـ schema

**الخيار أ (موصى به — آمن ومنظم): طبقة بخدمة SQL Editor**

افتح **SQL Editor** في Supabase ونفّذ الملفات بالترتيب من `supabase/migrations/`:
ابدأ بـ `000_kyno_baseline_schema.sql` ثم `001_security_hardening.sql` ثم `002_strict_rls.sql` ... حتى `085_v_companies_summary.sql`.

> الترتيب مهم: رقم الملف يحدد التسلسل. نفّذها تصاعدياً (000 → 085).

**الخيار ب (مسار سريع — ملف مدمج):**

1. نفّذ `supabase/migrations/000_kyno_baseline_schema.sql` أولاً (الـ baseline).
2. ثم نفّذ `tools/sql/kyno-merged-migrations-001-084.sql` دفعة واحدة (يحتوي 001→084 مدمجة).
3. ثم نفّذ `supabase/migrations/085_v_companies_summary.sql` (لأن المدمج ينتهي عند 084).

**الخيار ج (supabase CLI — للمتقدمين):**

```bash
npm install -g supabase
supabase link --project-ref <PROJECT_REF>
supabase db push   # يطبّق migrations من supabase/migrations/
```

### التحقق من نجاح الـ migrations

في SQL Editor نفّذ `tools/sql/check-db-migration-markers.sql` (إن وُجد) أو تحقق يدوياً من وجود الجداول الأساسية:

```sql
SELECT tablename FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
```

يجب أن ترى: `saas_users`, `companies`, `employees`, `attendance`, `employee_devices`, `leaves`, `app_settings`, `saas_sessions`, `audit_logs`, إلخ.

---

## الخطوة 3 — إنشاء السوبر أدمن

بعد اكتمال الـ migrations، نفّذ في SQL Editor:

```
tools/sql/bootstrap-super-admin.sql
```

هذا ينشئ مستخدم `super_admin` (غالباً username `yasser`) مع كلمة مرور bcrypt. احفظ كلمة المرور — ستحتاجها لتسجيل الدخول.

---

## الخطوة 4 — تحديث إعدادات الواجهة (حرج)

افتح `config/supabase.defaults.js` وحدّث القيمتين:

```js
window.__BASMA_SUPABASE_DEFAULTS__ = {
  supabaseUrl: 'https://<PROJECT_REF>.supabase.co',   // ← URL الجديد
  supabaseAnonKey: '<ANON_KEY_NEW>',                  // ← anon key الجديد
  appEnv: 'production'
};
```

> لا تضع `service_role` key هنا أبداً — الواجهة تستخدم anon فقط (RLS يحمي البيانات).

إن وُجد `config/local.config.js`، حدّثه بنفس القيم (أو احذفه ليعمل التطبيق بـ defaults).

---

## الخطوة 5 — نشر الـ Edge Functions الأربع

الواجهة تحتاج هذه الدوال: `auth-login`, `auth-session`, `auth-logout`, `auth-set-password`.

### المتغيرات البيئية المطلوبة في Supabase (Edge Functions secrets)

من **Project Settings → Edge Functions → Secrets** أضف:

| الاسم | القيمة |
|------|-------|
| `SUPABASE_URL` | `https://<PROJECT_REF>.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role key |
| `SUPABASE_ANON_KEY` | anon key |
| `BASMA_ALLOWED_ORIGINS` | `https://YOUR-SITE.netlify.app,http://localhost:5500` |

### النشر

**الطريقة أ — supabase CLI (موصى به):**

```bash
supabase functions deploy auth-login
supabase functions deploy auth-session
supabase functions deploy auth-logout
supabase functions deploy auth-set-password
```

**الطريقة ب — لوحة Supabase:**
Functions → Deploy new function → الصق محتوى `index.ts` من كل مجلد. ملاحظة: `auth-login/index.ts` مكتوب ليُلصق كاملاً (بدون imports). الباقي يستورد من `_shared/` — انسخ محتوى `_shared/*.ts` معها عند اللصق اليدوي.

### إعداد حرج — Verify JWT = OFF

لكل دالة من الأربع في لوحة Supabase:
**Functions → اختر الدالة → Settings → Verify JWT = OFF**

> هذه الدوال تُصدّر توكناتها الخاصة عبر GoTrue؛ لا يجب أن تطلب JWT للوصول.

### التحقق

شغّل:

```bash
powershell -File tools/preflight-netlify.ps1
```

يجب أن يعطي: `auth-login`, `auth-session`, `auth-logout`, `auth-set-password` جميعها reachable، و `RLS: anon blocked from employees (expected)`، و `auth-login + saas_verify_login RPC working`.

---

## الخطوة 6 — نشر الواجهة على Netlify

`netlify.toml` جاهز: نشر ثابت من جذر المشروع، بدون build، بدون functions.

### الطريقة أ — ربط Git (موصى به، تلقائي):

1. ارفع المشروع إلى GitHub.
2. Netlify → **Add new site → Import from Git**.
3. اختر الـ repo. لا تُعدّل build command (فارغة) و publish directory (`.` جاهز من netlify.toml).
4. في **Site settings → Environment variables** أضف (اختياري — يساعد preflight فقط):
   - `BASMA_SUPABASE_URL` = URL الجديد
   - `BASMA_SUPABASE_ANON_KEY` = anon key
   - `BASMA_APP_ENV` = `production`
5. Deploy. كل push لـ main يُعيد النشر تلقائياً.

### الطريقة ب — Netlify CLI:

```bash
npm install -g netlify-cli
netlify login
netlify init           # اربط الموقع
netlify deploy --prod  # من جذر المشروع (publish = ".")
```

### الطريقة ج — سحب إيداع (Drag & Drop):

اسحب **مجلد المشروع كاملاً** إلى https://app.netlify.com/drop.
> ملاحظة: هذه الطريقة لا تربط Git — للتحديث المستمر استخدم الطريقة أ.

---

## الخطوة 7 — اختبار تسجيل الدخول

1. افتح `https://YOUR-SITE.netlify.app` (Ctrl+Shift+R لتفريض الكاش).
2. سجّل دخول بـ username السوبر أدمن (مثلاً `yasser`) + كلمة المرور من الخطوة 3.
3. إن نجح → النظام يعمل. إن فشل راجع `tools/preflight-netlify.ps1` للتشخيص.

---

## ملخص سريع

```
1. Supabase: مشروع جديد → احفظ URL + anon + service + ref
2. SQL Editor: 000 → 085 (أو 000 + merged + 085)
3. SQL Editor: bootstrap-super-admin.sql
4. config/supabase.defaults.js: حدّث URL + anon key
5. Supabase Secrets + deploy 4 Edge Functions + Verify JWT = OFF
6. preflight-netlify.ps1 → كلها OK
7. Netlify: اربط Git / CLI / drop → افتح الموقع → سجّل دخول
```

---

## تحذيرات

- ❌ لا تضع `service_role` key في الواجهة (config/ أو JS) — فقط في Edge Functions secrets.
- ❌ لا تنسَ `Verify JWT = OFF` للدوال الأربع — وإلا سيفشل تسجيل الدخول بـ 401.
- ✅ anon key في الواجهة آمن لأن RLS يحمي البيانات.
- ✅ الاتصال المباشر بـ Supabase (بدون proxy) هو النمط الطبيعي والمدعوم.
