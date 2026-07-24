# supabase/functions/_shared/

كود TypeScript مشترك بين جميع Edge Functions.

---

## المبدأ

**مجلد واحد فقط للكود المشترك** — لا نسخ بين functions.

---

## الملفات المتوقعة

| الملف | الوصف |
|-------|-------|
| `supabase.ts` | Supabase client singleton للـ Edge Functions |
| `session.ts` | JWT utilities: create, verify, decode |
| `auth-jwt.ts` | JWT signing with custom claims |
| `cors.ts` | CORS headers موحّدة |
| `types.ts` | TypeScript types مشتركة |
| `response.ts` | Response helpers: success, error, unauthorized |

---

## طريقة الاستخدام في function

```typescript
// في auth-login/index.ts
import { createClient } from '../_shared/supabase.ts'
import { signJWT } from '../_shared/auth-jwt.ts'
import { corsHeaders } from '../_shared/cors.ts'
import { successResponse, errorResponse } from '../_shared/response.ts'
```

---

## القاعدة

```
✅ أي كود مكرر في أكثر من function → ينتمي لـ _shared/
❌ لا imports من function إلى function مباشرة
```
