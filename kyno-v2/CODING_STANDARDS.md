# KYNO v2 — Coding Standards

معايير كتابة الكود في المشروع. هذه ليست اقتراحات — هي قواعد إلزامية.

---

## 1. JavaScript Standards

### الإعلان عن المتغيرات

```
✅ const  → للقيم الثابتة (الغالبية)
✅ let    → للقيم المتغيرة فقط
❌ var    → ممنوع تماماً
```

### الدوال

```
✅ دوال صغيرة: مسؤولية واحدة فقط
✅ اسم الدالة يصف ما تفعله بدقة
✅ الحجم الأقصى: 40 سطر — إذا تجاوزت، قسّمها
❌ دوال بأسماء غامضة مثل: doStuff(), handle(), process()
```

### Async/Await

```javascript
// ✅ صحيح
async function getEmployees(companyId) {
  try {
    const { data, error } = await rpc('get_employees', { company_id: companyId })
    if (error) throw error
    return data
  } catch (err) {
    logger.error('getEmployees failed', err)
    throw err
  }
}

// ❌ خطأ — لا Promise chains
getEmployees(id)
  .then(data => ...)
  .catch(err => ...)
```

### Error Handling

```javascript
// ✅ دائماً try/catch في async functions
// ✅ دائماً log الأخطاء قبل re-throw
// ✅ لا تبتلع الأخطاء بصمت
// ❌ catch (e) {} ← ممنوع
```

---

## 2. SQL / Migration Standards

### تسمية الـ Migrations

```
NNN_وصف_قصير.sql
001_extensions_core_setup.sql      ✅
001_setup.sql                      ❌ (غامض)
my_migration.sql                   ❌ (بدون رقم)
```

### كتابة SQL

```sql
-- ✅ كل عبارة في سطرها
-- ✅ الكلمات المفتاحية بالكبير: CREATE TABLE, NOT NULL, DEFAULT
-- ✅ كل عمود في سطره مع indent
-- ✅ تعليق على الـ migration في أعلى الملف
-- ❌ كل شيء في سطر واحد
```

### قواعد صارمة

```
❌ لا تُعدِّل migration موجودة
❌ لا DROP TABLE في migrations (استخدم ALTER بحذر)
❌ لا secrets في migrations
✅ كل migration له comment يشرح الهدف
✅ كل migration يحتوي على timestamp في header
```

---

## 3. Edge Functions (TypeScript) Standards

```typescript
// ✅ كل function تبدأ بـ CORS headers check
// ✅ كل function ترد بـ JSON دائماً
// ✅ معالجة الأخطاء المركزية
// ✅ Validation للـ input قبل أي معالجة
// ❌ لا business logic في Edge Functions
// ❌ لا hardcoded credentials
```

---

## 4. التعليقات

```javascript
// ✅ علّق على الـ "لماذا" — ليس الـ "ماذا"
// كلمة المرور تُشفَّر قبل الحفظ لأن bcrypt أبطأ عمداً ضد brute force
const hashedPassword = await bcrypt.hash(password, 12)

// ❌ لا تعليقات تشرح ما يفعله الكود الواضح
// تشفير كلمة المرور ← (واضح من الكود نفسه)
const hashedPassword = await bcrypt.hash(password, 12)
```

---

## 5. ترتيب ملفات JS

```javascript
// 1. Imports (إذا كانت modules)
// 2. Constants
// 3. State variables
// 4. Helper functions (private)
// 5. Main functions (exported/public)
// 6. Event listeners / initialization
```

---

## 6. Security Standards

```
✅ كل input من المستخدم يمر عبر sanitizer.js قبل الإرسال
✅ كل query parameter يُتحقق منه
✅ لا تثق بـ client-side data — تحقق في قاعدة البيانات
✅ كل عملية حساسة تُسجَّل في audit_logs
❌ لا console.log في Production
❌ لا alert() أو confirm() للأخطاء — استخدم toast.js
```

---

## 7. Performance Standards

```
✅ لا queries داخل loops
✅ Debounce على search inputs (300ms)
✅ Loading state على كل async operation
✅ Pagination — لا تجلب أكثر من 100 سجل دفعة واحدة
❌ لا DOM manipulation في loops كبيرة
```

---

## 8. الجودة العامة

```
✅ قبل commit: مراجعة الكود يدوياً مرة واحدة
✅ لا dead code مُعلَّق بـ // TODO منذ أسابيع
✅ كل دالة جديدة: هل تحتاج test؟
❌ لا copy-paste من v1 بدون مراجعة كاملة
```

---

*هذا الملف جزء من KYNO v2 — Project Foundation*
