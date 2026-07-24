-- =============================================================================
-- 113_employee_broadcast_notices.sql
-- إشعارات البثّ للموظفين (Broadcast Notices)
-- -----------------------------------------------------------------------------
-- هذه الميزة تُخزّن رسائل البثّ ضمن app_settings بالمفتاح:
--     company:<id>:broadcast_notices   (مصفوفة JSON)
-- تُحفظ وتُزامن من جهة المسؤول عبر نفس مسار الإعدادات (finance_items نمطاً).
--
-- الهدف من هذا الملف: توسيع دالة saas_fetch_employee_client_profile فقط
-- لإرجاع broadcast_notices ضمن ملف تعريف الموظف، حتى يراها عميل الموظف (anon).
--
-- آمنة تماماً:
--   • لا تغيير في المخطط (لا أعمدة/جداول جديدة).
--   • CREATE OR REPLACE يحافظ على صلاحيات التنفيذ الحالية للدالة.
--   • النسخة مطابقة تماماً لنسخة 077 مع إضافة قراءة broadcast_notices فقط.
--   • إن لم يُطبّق هذا الملف بعد، فإن الواجهة تتجاهل الحقل الغائب دون أعطال.
-- =============================================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_client_profile(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  emp RECORD;
  gps_prefix TEXT;
  v_lat TEXT;
  v_lng TEXT;
  v_range TEXT;
  v_name TEXT;
  v_finance TEXT;
  v_broadcast TEXT;
  finance_arr JSONB := '[]'::jsonb;
  emp_finance JSONB := '[]'::jsonb;
  broadcast_arr JSONB := '[]'::jsonb;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

  IF emp.company_id IS NOT NULL THEN
    gps_prefix := 'company:' || emp.company_id::text || ':';
    SELECT value INTO v_lat FROM app_settings WHERE key = gps_prefix || 'gps_lat' LIMIT 1;
    SELECT value INTO v_lng FROM app_settings WHERE key = gps_prefix || 'gps_lng' LIMIT 1;
    SELECT value INTO v_range FROM app_settings WHERE key = gps_prefix || 'gps_range' LIMIT 1;
    SELECT value INTO v_name FROM app_settings WHERE key = gps_prefix || 'gps_name' LIMIT 1;
    SELECT value INTO v_finance FROM app_settings WHERE key = gps_prefix || 'finance_items' LIMIT 1;
    SELECT value INTO v_broadcast FROM app_settings WHERE key = gps_prefix || 'broadcast_notices' LIMIT 1;
  END IF;

  IF v_finance IS NOT NULL AND v_finance <> '' THEN
    BEGIN
      finance_arr := v_finance::jsonb;
    EXCEPTION WHEN others THEN
      finance_arr := '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(COALESCE(finance_arr, '[]'::jsonb)) <> 'array' THEN
    finance_arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO emp_finance
  FROM jsonb_array_elements(COALESCE(finance_arr, '[]'::jsonb)) item
  WHERE (item->>'empId')::text = emp.id::text
     OR (item->>'emp_id')::text = emp.id::text
     OR (item->>'employee_id')::text = emp.id::text;

  -- إشعارات البثّ (على مستوى الشركة كاملة — تظهر لجميع الموظفين)
  IF v_broadcast IS NOT NULL AND v_broadcast <> '' THEN
    BEGIN
      broadcast_arr := v_broadcast::jsonb;
    EXCEPTION WHEN others THEN
      broadcast_arr := '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(COALESCE(broadcast_arr, '[]'::jsonb)) <> 'array' THEN
    broadcast_arr := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'role', emp.role,
    'phone', emp.phone,
    'salary', emp.salary,
    'salary_type', emp.salary_type,
    'salary_half', emp.salary_half,
    'daily_rate', emp.daily_rate,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE,
    'avatar_url', emp.avatar_url,
    'finance_items', emp_finance,
    'broadcast_notices', broadcast_arr,
    'gps_lat', NULLIF(trim(v_lat), ''),
    'gps_lng', NULLIF(trim(v_lng), ''),
    'gps_range', NULLIF(trim(v_range), ''),
    'gps_name', NULLIF(trim(v_name), '')
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
