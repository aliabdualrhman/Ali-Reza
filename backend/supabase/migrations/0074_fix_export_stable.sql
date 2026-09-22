-- =============================================================================
-- 0074 — التصدير كان يَعِد بألّا يكتب ثم يكتب
-- =============================================================================
-- **`cannot execute INSERT in a read-only transaction`.**
--
-- عرّفتُ `admin_export_trips` بـ`stable`، وهي وعدٌ لبوستغرس بأن الدالة
-- لا تغيّر شيئاً. فيفتح لها معاملةً للقراءة فقط ويحسّن على ذلك الأساس.
-- ثم جعلتُها تكتب سطر تدقيقٍ بـ`log_action` — فيرفض الإدراج.
--
-- **والحلّ إزالة الوعد لا إزالة الكتابة.** سطر التدقيق هو الفائدة:
-- تنزيلُ أرقام الشركة كاملةً فعلٌ يجب أن يُعرف فاعله ووقته. وإسقاطه
-- ليُرضي `stable` مقايضةٌ خاسرة — سرعةٌ لا تُلحظ مقابل أثرٍ يُسأل عنه.
--
-- ونفس الخطأ ليس في `admin_dashboard`: هي `stable` ولا تكتب شيئاً.

set search_path = public, extensions;


create or replace function public.admin_export_trips(p_code text)
returns table (
  "رقم الرحلة"    text,
  "التاريخ"       text,
  "الحالة"        text,
  "الراكب"        text,
  "هاتف الراكب"   text,
  "السائق"        text,
  "هاتف السائق"   text,
  "من"            text,
  "إلى"           text,
  "المسافة (كم)"  numeric,
  "الأجرة"        numeric,
  "العمولة"       numeric,
  "حصة السائق"    numeric
)
language plpgsql
-- **بلا `stable` عمداً.** انظر رأس الملف.
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;
  if not public.check_admin_code(p_code) then
    raise exception 'رمز المدير غير صحيح';
  end if;

  perform public.log_action('dashboard.export', 'trips', null,
    'صُدِّرت بيانات اللوحة');

  return query
  select
    left(t.id::text, 8),
    to_char(t.requested_at at time zone 'Asia/Baghdad', 'YYYY-MM-DD HH24:MI'),
    case t.status
      when 'completed' then 'مكتملة'
      when 'cancelled' then 'ملغاة'
      else t.status::text
    end,
    r.full_name, r.phone,
    d.full_name, d.phone,
    t.pickup_address,
    t.dropoff_address,
    -- الفعلية إن سُجّلت، وإلا التقدير — والصفر يعني أن لا هذه ولا تلك.
    round(coalesce(t.actual_distance_m, t.estimated_distance_m, 0)
          / 1000.0, 2),
    t.fare_final_iqd,
    t.commission_iqd,
    t.driver_earning_iqd
  from public.trips t
  left join public.profiles r on r.id = t.rider_id
  left join public.profiles d on d.id = t.driver_id
  where t.requested_at >= coalesce(public.dashboard_epoch(), '-infinity')
  order by t.requested_at desc
  limit 5000;
end;
$fn$;

revoke all on function public.admin_export_trips(text) from public, anon;
grant execute on function public.admin_export_trips(text) to authenticated;

notify pgrst, 'reload schema';


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — يجب أن تكون provolatile = 'v'
-- -----------------------------------------------------------------------------
select proname as "الدالة",
       case provolatile when 'v' then 'تكتب (صحيح)'
                        when 's' then 'لا تكتب (خطأ)'
                        else provolatile::text end as "الحال"
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname = 'admin_export_trips';
