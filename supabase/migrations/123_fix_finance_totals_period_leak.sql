-- 123 — إصلاح: حركات مالية (خصومات/مكافآت) بلا period صريح كانت تُطبَّق على كل شهر إلى الأبد
--
-- المشكلة: saas_v3_finance_totals (المُستخدمة من saas_v3_compute_salary / saas_preview_salary /
-- saas_issue_salary) كانت تعتبر أي حركة "خصم" أو "مكافأة" بلا حقل period صريح صالحة تلقائياً
-- لكل شهر (iperiod = '' كان يمرّ الشرط دائماً)، فتظل حركات الشهور السابقة تظهر وتُخصم/تُضاف
-- في رواتب الشهور التالية إلى ما لا نهاية بدل الاقتصار على شهرها الأصلي.
--
-- الإصلاح: عند غياب period الصريح، تُشتق الفترة من تاريخ الحركة (أو تاريخ الإنشاء)، ولا تُطابق
-- إلا شهرها الفعلي — بدل افتراض "صالحة لكل شهر". لا تغيير على منطق السلف (loans) القائم على
-- الحالة (status) فقط كما كان.

CREATE OR REPLACE FUNCTION saas_v3_finance_totals(
  p_company_id INTEGER,
  p_employee_id INTEGER,
  p_period_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tenant JSONB;
  raw TEXT;
  arr JSONB;
  item JSONB;
  deductions INTEGER := 0;
  bonuses INTEGER := 0;
  loans INTEGER := 0;
  amt INTEGER;
  status TEXT;
  iperiod TEXT;
  inst INTEGER;
  loan_items JSONB := '[]'::jsonb;
  applies BOOLEAN;
BEGIN
  tenant := saas_v3_assert_tenant(p_company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  raw := saas_v3_company_setting(p_company_id, 'finance_items');
  IF raw IS NULL OR trim(raw) = '' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END IF;
  BEGIN
    arr := raw::JSONB;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(arr)
  LOOP
    IF COALESCE((item->>'empId')::INTEGER, (item->>'emp_id')::INTEGER, 0) <> p_employee_id THEN
      CONTINUE;
    END IF;
    status := COALESCE(item->>'status', '');
    IF status IN ('ملغي', 'مسدد') THEN CONTINUE; END IF;

    iperiod := COALESCE(NULLIF(trim(item->>'period'), ''), '');
    IF iperiod = '' THEN
      -- بلا period صريح: اشتقاق الشهر من تاريخ الحركة، وإلا من تاريخ الإنشاء
      iperiod := left(COALESCE(
        NULLIF(trim(item->>'date'), ''),
        NULLIF(trim(item->>'createdAt'), ''),
        NULLIF(trim(item->>'created_at'), ''),
        ''
      ), 7);
    END IF;

    amt := GREATEST(0, COALESCE((item->>'amount')::INTEGER, 0));
    applies := (iperiod <> '') AND (iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7));

    IF COALESCE(item->>'type', '') = 'bonus' THEN
      IF applies THEN
        bonuses := bonuses + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'deduction' THEN
      IF applies THEN
        deductions := deductions + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'loan' THEN
      inst := saas_v3_loan_current_installment(item);
      IF inst > 0 THEN
        loans := loans + inst;
        loan_items := loan_items || jsonb_build_array(jsonb_build_object(
          'id', item->>'id',
          'amount', amt,
          'installment_count', COALESCE((item->>'installmentCount')::INTEGER, (item->>'installment_count')::INTEGER, 1),
          'paid_installments', COALESCE((item->>'paidInstallments')::INTEGER, (item->>'paid_installments')::INTEGER, 0),
          'current_installment', inst,
          'remaining_balance', saas_v3_loan_remaining_balance(item),
          'loan_mode', COALESCE(item->>'loanMode', item->>'loan_mode', 'lump'),
          'status', status
        ));
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'deductions', deductions,
    'bonuses', bonuses,
    'loans', loans,
    'loan_items', loan_items
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_finance_totals(INTEGER, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION saas_v3_finance_totals(INTEGER, INTEGER, TEXT) TO service_role;

NOTIFY pgrst, 'reload schema';
