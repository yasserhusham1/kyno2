# supabase/

يحتوي على كل ما يخص Supabase: قاعدة البيانات، Edge Functions، الإعدادات.

---

## المجلدات

### `migrations/`
Migrations مرقّمة بالترتيب — **لا تُعدَّل migration موجودة أبداً**.

قاعدة التسمية:
```
NNN_وصف_قصير.sql
001_extensions_core_setup.sql
002_database_helper_functions.sql
003_table_plans.sql
...
```

### `seeds/`
بيانات ابتدائية لا تتغير — منفصلة عن الـ migrations.

```
001_plans.sql
002_platform_settings.sql
003_super_admin.sql
```

> ⚠️ Seeds لا تُطبَّق إلا مرة واحدة عند الإعداد الأولي.

### `functions/`
Edge Functions للعمليات الحساسة فقط (Auth + Critical).

```
_shared/          ← كود مشترك بين جميع functions (مجلد واحد لا غير)
auth-login/
auth-logout/
auth-session/
auth-refresh-token/
auth-set-password/
auth-employee-attend/
```

### `config.toml`
إعدادات Supabase CLI — لا تُضاف credentials هنا.

---

## القواعد

1. كل migration: مهمة واحدة فقط
2. لا migration يُعدَّل migration سابق
3. كل migration: idempotent قدر الإمكان
4. لا تُكتب credentials في أي ملف هنا
5. `_shared/` للكود المشترك فقط — لا تكرار في functions
