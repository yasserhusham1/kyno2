# KYNO v2 — Contributing Guide

دليل المساهمة في المشروع.

---

## قبل أي شيء

اقرأ هذه الملفات أولاً:

1. `README.md` — نظرة عامة على المشروع
2. `DEV_RULES.md` — قواعد التطوير الإلزامية
3. `CODING_STANDARDS.md` — معايير الكود
4. `NAMING_CONVENTION.md` — اتفاقيات التسمية
5. `docs/v2/DatabaseSpecification.md` — مواصفات قاعدة البيانات
6. `docs/v2/MigrationPlan.md` — خطة الـ Migrations

---

## 1. إعداد بيئة التطوير

```
1. انسخ المستودع
2. انسخ .env.example → .env.local
3. أدخل القيم الفعلية في .env.local
4. شغّل Supabase محلياً أو استخدم Supabase cloud
5. طبّق الـ migrations بالترتيب من M001
```

---

## 2. سير العمل للمساهمة

### خطوة 1: أنشئ Branch

```
# migration جديد
git checkout -b migration/m001-extensions

# ميزة جديدة
git checkout -b feat/employee-attendance-module

# إصلاح
git checkout -b fix/payroll-overtime-calculation
```

### خطوة 2: طوّر

اتبع قواعد `DEV_RULES.md` و`CODING_STANDARDS.md`.

### خطوة 3: اختبر

```
✅ اختبر التغيير محلياً
✅ اختبر Edge Cases
✅ إذا migration: تحقق من صحة البيانات بعد التطبيق
✅ إذا RPC: اختبر مع أدوار مختلفة (SA, company_admin, company_user)
```

### خطوة 4: Commit

```
git add .
git commit -m "feat: add employee fingerprint device binding"
```

اتبع صيغة `GIT_STRATEGY.md`.

### خطوة 5: Push + PR

```
git push origin feat/employee-attendance-module
```

افتح Pull Request إلى `dev`.

---

## 3. Checklist قبل فتح PR

```
□ الكود يتبع CODING_STANDARDS.md
□ التسمية تتبع NAMING_CONVENTION.md
□ لا console.log مُتبقية
□ لا ملفات .env أو credentials في الكود
□ لا TODO مُهمَل
□ تم الاختبار محلياً
□ Migration (إن وجد) مُختبر ومُطبَّق بنجاح
□ RLS (إن وجد) مُختبر: شركة A لا ترى بيانات شركة B
□ Commit message يتبع الصيغة المطلوبة
□ Branch مُحدَّث مع آخر تغييرات dev
```

---

## 4. نموذج Pull Request

```markdown
## ماذا يفعل هذا التغيير؟
وصف موجز لما تغيّر.

## لماذا؟
السبب أو المشكلة التي يحلها.

## نوع التغيير
- [ ] Migration
- [ ] Feature
- [ ] Bug Fix
- [ ] Refactor
- [ ] Documentation

## كيف اختبرته؟
- [ ] اختبار محلي
- [ ] اختبار RLS
- [ ] اختبار Edge Cases

## ملاحظات للـ Reviewer
أي شيء يجب الانتباه له.
```

---

## 5. للـ Migrations تحديداً

```
□ اسم الملف يتبع الصيغة: NNN_وصف_قصير.sql
□ الرقم يتبع آخر migration موجود
□ الملف يحتوي على header comment
□ تم الاختبار على قاعدة بيانات نظيفة
□ migration لا يُعدِّل migration سابق
□ تم تحديث README في supabase/migrations/
```

---

## 6. للـ Edge Functions تحديداً

```
□ الكود المشترك في _shared/ فقط
□ CORS headers موجودة
□ JSON response دائماً
□ لا hardcoded secrets
□ validation على كل input
□ لا business logic
```

---

## 7. ما لا يُقبَل في PR

```
❌ code من v1 منسوخ بدون مراجعة
❌ ملفات .env أو config بقيم حقيقية
❌ console.log للبيانات الحساسة
❌ migrations تُعدِّل migrations سابقة
❌ تغييرات غير مرتبطة بالموضوع الأصلي
❌ كود بدون اختبار
❌ commit message غير واضح
```

---

## 8. مبدأ المساهمة الذهبي

> **"مهمة صغيرة، migration واحد، صفحة واحدة — وليس كل شيء دفعة واحدة."**
>
> الـ PR الجيد صغير وواضح ومحدد الهدف.
> أفضل بكثير من PR ضخم يصعب مراجعته.

---

*KYNO v2 — Built with discipline, reviewed with care.*
