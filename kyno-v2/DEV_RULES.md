# KYNO v2 — Development Rules

قواعد التطوير — تُقرأ قبل البدء بأي مهمة.

---

## القاعدة الأهم

> **مهمة واحدة في كل مرة.**
>
> Migration واحد. صفحة واحدة. خدمة واحدة. جدول واحد. API واحد.
>
> لا تبدأ الثانية قبل انتهاء الأولى واختبارها.

---

## 1. قواعد الـ Database

```
✅ كل migration يُختبر محلياً قبل push
✅ كل migration يُراجَع مقابل DatabaseSpecification.md
✅ كل migration يحتوي على header comment يشرح الهدف
✅ الـ Migrations تُطبَّق بالترتيب دائماً

❌ لا تُعدِّل migration موجود في Git
❌ لا تُطبِّق migration بدون اختبار محلي
❌ لا تُدمج migration تالٍ قبل اعتماد السابق
❌ لا تكتب SQL مباشرة في قاعدة الإنتاج — Migrations فقط
```

---

## 2. قواعد الـ Authentication

```
✅ كل طلب حساس يتحقق من الـ JWT
✅ كل JWT يحمل: user_id + company_id + role
✅ server-side validation دائماً — لا تثق بـ client
✅ تسجيل كل login/logout في audit_logs

❌ لا hardcoded credentials
❌ لا plain text passwords
❌ لا تخزين JWT في localStorage — sessionStorage أو memory
```

---

## 3. قواعد الـ Multi-Tenancy

```
✅ كل query يفلتر بـ company_id
✅ RLS هو خط الدفاع الأخير — لا تعتمد عليه وحده
✅ كل RPC تتحقق من company_id في المنطق نفسه
✅ اختبر: هل يمكن لمستخدم شركة A رؤية بيانات شركة B؟

❌ لا تفترض أن RLS كافٍ بدون اختبار
❌ لا queries بدون company_id filter في الجداول التشغيلية
```

---

## 4. قواعد Security

```
✅ sanitize كل input من المستخدم قبل إرساله
✅ validate البيانات في قاعدة البيانات (CHECK constraints)
✅ rate limiting على Auth endpoints
✅ كل عملية حساسة في audit_logs

❌ لا console.log للبيانات الحساسة
❌ لا تُعيد كلمة المرور أو الـ hash للـ client
❌ لا تُخزِّن fingerprint الخام — SHA-256 hash فقط
❌ لا تُكشِف رسائل أخطاء تقنية للمستخدم النهائي
```

---

## 5. قواعد الكود

```
✅ اقرأ الكود الموجود قبل إضافة جديد
✅ لا code duplication — إذا كتبت نفس الكود مرتين، حوّله لدالة
✅ اسم الدالة يصف ما تفعله بالضبط
✅ دالة واحدة = مسؤولية واحدة

❌ لا copy-paste من v1 بدون مراجعة كاملة
❌ لا var — const أو let فقط
❌ لا promise chains — async/await فقط
❌ لا catch فارغ: catch(e) {}
```

---

## 6. قواعد الـ Git

```
✅ branch لكل مهمة — لا تطوير مباشر على dev
✅ commits صغيرة ومتكررة
✅ message واضح يصف التغيير
✅ review الكود قبل كل PR

❌ لا push مباشر لـ main
❌ لا ملفات .env في commits
❌ لا "wip" أو "fix" كـ commit message
```

---

## 7. قواعد الـ Testing

```
✅ اختبر كل RPC جديد قبل بناء UI عليه
✅ اختبر RLS: هل الشركة B ترى بيانات الشركة A؟
✅ اختبر Edge Cases: null, empty, max_length
✅ اختبر مع دور مختلف: SA, company_admin, company_user

❌ لا تنتقل لـ module تالٍ قبل اختبار الحالي
```

---

## 8. تسلسل التطوير المُوصى به

```
لكل ميزة جديدة:

1. اقرأ الـ DatabaseSpecification.md للجدول المعني
2. تأكد أن الـ Migration موجود ومطبّق
3. اختبر الـ RPC مباشرة (بدون UI)
4. ابنِ الـ UI على RPC يعمل بتأكيد
5. اختبر التكامل
6. Commit + PR
```

---

## 9. عند الشك

```
? هل يجب أن أضيف column جديد؟
  → راجع DatabaseSpecification.md أولاً
  → إذا لزم: migration جديد، لا تعديل قائم

? هل يجب أن أضيف RPC جديد؟
  → هل يوجد RPC مشابه يمكن تعميمه؟
  → يجب أن يكون SECURITY DEFINER إذا يتجاوز RLS

? هل يجب استخدام Edge Function أم RPC؟
  → Edge Function: Auth فقط أو عمليات حساسة لا تعمل في SQL
  → RPC: كل شيء آخر
```

---

*هذا الملف جزء من KYNO v2 — Project Foundation*
