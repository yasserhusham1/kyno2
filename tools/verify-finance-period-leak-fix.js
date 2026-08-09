/**
 * اختبار منطقي (بدون DB حية) لإصلاح تسرّب حركات المالية بلا period صريح
 * إلى كل شهر إلى الأبد — يحاكي منطق saas_v3_finance_totals (migration 123)
 * ومنطق normalizeFinanceItem/financeItemAppliesToPeriod في js/app/main.js.
 *
 * يشغّل: node tools/verify-finance-period-leak-fix.js
 */
'use strict';

var pass = 0;
var fail = 0;

function assert(cond, msg) {
  if (cond) {
    pass++;
    console.log('  ✓', msg);
  } else {
    fail++;
    console.error('  ✕', msg);
  }
}

// -- محاكاة saas_v3_finance_totals القديمة (قبل migration 123) --
function financeApplies_OLD(item, periodKey) {
  var status = item.status || '';
  if (status === 'ملغي' || status === 'مسدد') return false;
  var iperiod = item.period || '';
  if (item.type === 'bonus' || item.type === 'deduction') {
    return iperiod === '' || iperiod === periodKey || iperiod.slice(0, 7) === periodKey.slice(0, 7);
  }
  return null; // loans غير معنية بهذا الاختبار
}

// -- محاكاة saas_v3_finance_totals الجديدة (بعد migration 123) --
function financeApplies_NEW(item, periodKey) {
  var status = item.status || '';
  if (status === 'ملغي' || status === 'مسدد') return false;
  var iperiod = item.period || '';
  if (iperiod === '') {
    iperiod = (item.date || item.createdAt || '').slice(0, 7);
  }
  if (item.type === 'bonus' || item.type === 'deduction') {
    return iperiod !== '' && (iperiod === periodKey || iperiod.slice(0, 7) === periodKey.slice(0, 7));
  }
  return null;
}

console.log('\n=== حركة قديمة بلا period صريح (خصم أُضيف في يونيو، لا يحمل period) ===');
var legacyDeduction = { type: 'deduction', status: 'نشط', amount: 50000, date: '2026-06-10', period: '' };

assert(financeApplies_OLD(legacyDeduction, '2026-06') === true, 'الخلل القديم: يظهر في يونيو (شهره الفعلي) — متوقع');
assert(financeApplies_OLD(legacyDeduction, '2026-07') === true, 'الخلل القديم: يظهر أيضاً في يوليو رغم انتهاء شهره — هذا هو التسرّب');
assert(financeApplies_OLD(legacyDeduction, '2026-12') === true, 'الخلل القديم: يظهر حتى في ديسمبر — يتكرر إلى الأبد');

assert(financeApplies_NEW(legacyDeduction, '2026-06') === true, 'الإصلاح: يظهر في يونيو (شهره الفعلي)');
assert(financeApplies_NEW(legacyDeduction, '2026-07') === false, 'الإصلاح: لا يظهر في يوليو');
assert(financeApplies_NEW(legacyDeduction, '2026-12') === false, 'الإصلاح: لا يظهر في ديسمبر');

console.log('\n=== حركة حديثة بـ period صريح (يجب ألا يتأثر سلوكها) ===');
var taggedBonus = { type: 'bonus', status: 'نشط', amount: 30000, date: '2026-08-01', period: '2026-08' };
assert(financeApplies_OLD(taggedBonus, '2026-08') === true, 'قديم: مكافأة أغسطس تظهر في أغسطس');
assert(financeApplies_OLD(taggedBonus, '2026-09') === false, 'قديم: لا تظهر في سبتمبر (period صريح يمنع التسرّب أصلاً)');
assert(financeApplies_NEW(taggedBonus, '2026-08') === true, 'جديد: مكافأة أغسطس تظهر في أغسطس (بلا تغيير)');
assert(financeApplies_NEW(taggedBonus, '2026-09') === false, 'جديد: لا تظهر في سبتمبر (بلا تغيير)');

console.log('\n=== حركة مسددة/ملغاة: تُستبعد دوماً بغض النظر عن period ===');
var paidLoan = { type: 'deduction', status: 'مسدد', amount: 10000, date: '2026-05-01', period: '' };
assert(financeApplies_OLD(paidLoan, '2026-05') === false, 'قديم: خصم مسدد مُستبعد أصلاً');
assert(financeApplies_NEW(paidLoan, '2026-05') === false, 'جديد: خصم مسدد يبقى مُستبعداً');

// -- محاكاة saas_v3_finance_totals/normalizeFinanceItem: اشتقاق الفترة من تاريخ الحركة --
function financePeriodFromDateLike(dateStr) {
  return String(dateStr || '').slice(0, 7);
}

// -- محاكاة preConfirm في openFinanceItemForm --
function saveFinanceItem_OLD(existing, formDate, nowMonthKey) {
  return {
    date: formDate,
    period: nowMonthKey, // كان دوماً "الشهر الحالي" بصرف النظر عن تاريخ الحركة أو حالة existing
    status: 'نشط'        // كان دوماً يُعاد ضبطه إلى "نشط" حتى لو كان "مسدد"
  };
}
function saveFinanceItem_NEW(existing, formDate) {
  return {
    date: formDate,
    period: financePeriodFromDateLike(formDate),
    status: existing ? (existing.status || 'نشط') : 'نشط'
  };
}

console.log('\n=== تعديل حركة سُدِّدت في يوليو (تعديل بسيط: تصحيح ملاحظة فقط) — الشهر الحالي أغسطس ===');
var julyPaidItem = { period: '2026-07', date: '2026-07-15', status: 'مسدد' };
var savedOld = saveFinanceItem_OLD(julyPaidItem, '2026-07-15', '2026-08');
assert(savedOld.period === '2026-08', 'الخلل القديم: التعديل ينقل الحركة إلى أغسطس رغم أن تاريخها يوليو');
assert(savedOld.status === 'نشط', 'الخلل القديم: التعديل يعيد تفعيل حركة "مسدد" إلى "نشط" — تُخصم من جديد!');

var savedNew = saveFinanceItem_NEW(julyPaidItem, '2026-07-15');
assert(savedNew.period === '2026-07', 'الإصلاح: التعديل يحافظ على شهر يوليو (مُشتق من تاريخ الحركة نفسه)');
assert(savedNew.status === 'مسدد', 'الإصلاح: التعديل يحافظ على حالة "مسدد" — لا يُعاد تفعيلها');

console.log('\n=== إضافة حركة جديدة بتاريخ يدوي داخل شهر سابق (مثال: تسجيل متأخر لسلفة يوليو) ===');
var newItemNew = saveFinanceItem_NEW(null, '2026-07-20');
assert(newItemNew.period === '2026-07', 'الإصلاح: حركة جديدة بتاريخ يوليو تُربط بيوليو (وليس الشهر الحالي)');
assert(newItemNew.status === 'نشط', 'الإصلاح: حركة جديدة افتراضياً "نشط"');

console.log('\n────────────');
console.log('النتيجة:', pass, 'نجحت،', fail, 'فشلت');
if (fail) process.exit(1);
