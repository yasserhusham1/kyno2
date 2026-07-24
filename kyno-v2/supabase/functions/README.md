# supabase/functions/

Edge Functions للعمليات الحساسة فقط.

---

## المبدأ

Edge Functions في KYNO v2 تُستخدم **فقط** لـ:
1. مصادقة المستخدمين (توليد JWT)
2. تسجيل حضور الموظف (fingerprint verification)
3. عمليات لا يمكن تأمينها بـ RLS وحده

**كل شيء آخر → RPC (PostgreSQL Functions)**

---

## الـ Functions الموجودة

| Function | الغرض | Auth Required |
|----------|-------|---------------|
| `auth-login` | تسجيل دخول + توليد JWT | لا (anon) |
| `auth-logout` | إلغاء الجلسة | نعم |
| `auth-session` | التحقق من الجلسة الحالية | نعم |
| `auth-refresh-token` | تجديد JWT | نعم |
| `auth-set-password` | تعيين/تغيير كلمة المرور | نعم |
| `auth-employee-attend` | تسجيل حضور بالـ fingerprint | لا (anon) |

---

## `_shared/`

مجلد **واحد فقط** للكود المشترك بين جميع functions.

**لا تنسخ كوداً بين functions — ضعه في `_shared/`.**

الملفات المتوقعة:
```
_shared/
├── supabase.ts       ← Supabase client
├── session.ts        ← JWT utilities
├── auth-jwt.ts       ← JWT signing/verification
├── cors.ts           ← CORS headers
└── types.ts          ← Shared TypeScript types
```

---

## قواعد Edge Functions

```
1. كل function في مجلدها المستقل
2. لا imports مباشرة من function أخرى — عبر _shared فقط
3. كل function تتحقق من CORS headers
4. لا secrets مكتوبة في الكود — من Supabase Secrets فقط
5. كل function تُعيد JSON response دائماً
6. لا تضع business logic في Edge Functions — فقط auth/security
```
