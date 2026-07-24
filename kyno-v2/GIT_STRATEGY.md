# KYNO v2 — Git Branch Strategy

استراتيجية Git للمشروع — بسيطة وفعّالة.

---

## 1. الـ Branches الرئيسية

```
main          ← الإنتاج فقط — محمي
dev           ← التطوير الرئيسي — يُدمج في main عند الإصدار
```

---

## 2. أنواع الـ Branches

| النوع | الصيغة | مثال |
|-------|-------|------|
| Migration | `migration/m{NNN}-{desc}` | `migration/m001-extensions` |
| Feature | `feat/{desc}` | `feat/employee-attendance` |
| Bug Fix | `fix/{desc}` | `fix/salary-calculation-overtime` |
| Documentation | `docs/{desc}` | `docs/update-erd` |
| Refactor | `refactor/{desc}` | `refactor/auth-module` |
| Test | `test/{desc}` | `test/payroll-rpc` |
| Chore | `chore/{desc}` | `chore/update-gitignore` |

---

## 3. سير العمل (Workflow)

### لكل Migration

```
1. أنشئ branch: migration/m001-extensions
2. اكتب SQL في supabase/migrations/001_extensions_core_setup.sql
3. اختبر محلياً
4. Commit: "migration: M001 extensions and core setup"
5. PR → dev
6. Review → Merge → حذف الـ branch
```

### لكل Feature

```
1. أنشئ branch من dev: feat/employees-crud
2. طوّر الميزة
3. Commit صغيرة ومتكررة
4. PR → dev
5. Review → Merge → حذف الـ branch
```

---

## 4. Commit Messages

### الصيغة
```
{type}: {short description}

{body optional}

{footer optional: refs #issue}
```

### الأنواع
```
feat      ← ميزة جديدة
fix       ← إصلاح خطأ
migration ← migration جديد
docs      ← تحديث توثيق
refactor  ← إعادة هيكلة بدون تغيير وظيفي
test      ← إضافة أو تعديل اختبارات
chore     ← مهام صيانة (update deps, config...)
style     ← تنسيق فقط، لا تغيير وظيفي
```

### أمثلة جيدة
```
feat: add employee device fingerprint binding
migration: M001 PostgreSQL extensions and core setup
fix: correct overtime calculation when work exceeds midnight
docs: update migration plan after review changes
refactor: extract JWT verification to auth helper
```

### أمثلة سيئة
```
❌ update
❌ fix stuff
❌ wip
❌ changes
❌ done
```

---

## 5. قواعد الـ Commit

```
✅ Commits صغيرة ومتكررة — لا "كل شيء في commit واحد"
✅ كل commit: مسؤولية واحدة
✅ Message يصف ما تغيّر، ليس كيف
✅ لا push مباشر لـ main
✅ كل migration في commit منفرد
❌ لا ملفات .env أو secrets في commits
```

---

## 6. حماية الـ Branches

```
main:
  ✅ لا push مباشر
  ✅ يتطلب PR + Review
  ✅ يتطلب tests تجتاز

dev:
  ✅ المرجع للتطوير
  ✅ merge من feature branches
```

---

## 7. Tagging الإصدارات

```
v{major}.{minor}.{patch}
v2.0.0  ← الإطلاق الأول
v2.1.0  ← ميزة جديدة
v2.1.1  ← إصلاح bug
```

---

## 8. .gitignore الأساسي

```
.env.local
.env.*.local
config/local.config.js
dist/
release/
node_modules/
*.log
.DS_Store
Thumbs.db
supabase/.temp/
```

---

*هذا الملف جزء من KYNO v2 — Project Foundation*
