-- =============================================================================
-- 0070 — لوحة الأرقام
-- =============================================================================
-- المدير يفتح اللوحة اليوم فيرى جداول: سائقين، ورحلات، ورموزاً. ولا يرى
-- **الأرقام** — كم رصيداً ولّدنا، وكم منه دخل جيوب السائقين، وكم رحلةً
-- جرت اليوم، وكم كسبنا منها.
--
-- ------------------------------------------------------------------
-- ثلاثة أرقامٍ للمال لا رقم واحد
-- ------------------------------------------------------------------
--   • **مُولَّد** — مجموع الرموز التي أنشأناها. ورقةٌ لا مال بعد.
--   • **مُعبَّأ** — ما استُهلك منها فعلاً ودخل محافظ السائقين.
--   • **معلَّق** — الفرق: رموزٌ في أيدي الناس لم تُستعمل بعد، وهي
--     التزامٌ علينا لا رصيدٌ لنا.
--
-- وخلطُها في رقمٍ واحد يُخفي أخطر ما فيها: من يرى «١٦٥٠٠٠ مُولَّد» ويظنّه
-- مصروفاً يوقف التوليد بلا داعٍ، ومن يظنّه دخلاً يحتفل بلا سبب.
--
-- ------------------------------------------------------------------
-- والعمولة تُقرأ من الرحلة لا تُحسب هنا
-- ------------------------------------------------------------------
-- `trips.commission_iqd` مثبّتة لحظة الإكمال بسعر منطقتها يومها
-- (`0006`). وإعادة حسابها بالنسبة الحالية تُغيّر تاريخ الشهر الماضي كلما
-- عدّل المدير نسبة منطقة — فتصير الأرقام لا تُصدَّق.
--
-- **والمكتملة وحدها تُحسب في المال.** الملغاة تدخل عدّاد الرحلات لأن
-- إلغاءً كثيراً خبرٌ يجب أن يُرى، ولا تدخل الدخل لأن لا مال فيها.

set search_path = public, extensions;


create or replace function public.admin_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_day    timestamptz := date_trunc('day', now());
  v_month  timestamptz := date_trunc('month', now());
  v_codes  jsonb;
  v_trips  jsonb;
  v_people jsonb;
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح';
  end if;

  -- ---- المال ----
  select jsonb_build_object(
    'generated_iqd', coalesce(sum(amount_iqd), 0),
    'redeemed_iqd',
      coalesce(sum(amount_iqd) filter (where redeemed_by is not null), 0),
    -- الملغى ليس معلَّقاً: أُبطل فلا يُنتظر.
    'outstanding_iqd',
      coalesce(sum(amount_iqd)
        filter (where redeemed_by is null and not is_void), 0),
    'redeemed_today_iqd',
      coalesce(sum(amount_iqd)
        filter (where redeemed_at >= v_day), 0),
    'redeemed_month_iqd',
      coalesce(sum(amount_iqd)
        filter (where redeemed_at >= v_month), 0),
    'count_total', count(*),
    'count_unused', count(*) filter (where redeemed_by is null and not is_void)
  )
  into v_codes
  from public.topup_codes;

  -- ---- الرحلات والعمولات ----
  select jsonb_build_object(
    'total',            count(*),
    'month',            count(*) filter (where requested_at >= v_month),
    'today',            count(*) filter (where requested_at >= v_day),

    'completed_total',  count(*) filter (where status = 'completed'),
    'completed_month',  count(*) filter (
                          where status = 'completed'
                            and requested_at >= v_month),
    'completed_today',  count(*) filter (
                          where status = 'completed'
                            and requested_at >= v_day),

    'cancelled_total',  count(*) filter (where status = 'cancelled'),
    'cancelled_month',  count(*) filter (
                          where status = 'cancelled'
                            and requested_at >= v_month),

    'fare_total',  coalesce(sum(fare_final_iqd)
                     filter (where status = 'completed'), 0),
    'fare_month',  coalesce(sum(fare_final_iqd)
                     filter (where status = 'completed'
                               and requested_at >= v_month), 0),
    'fare_today',  coalesce(sum(fare_final_iqd)
                     filter (where status = 'completed'
                               and requested_at >= v_day), 0),

    'commission_total', coalesce(sum(commission_iqd)
                          filter (where status = 'completed'), 0),
    'commission_month', coalesce(sum(commission_iqd)
                          filter (where status = 'completed'
                                    and requested_at >= v_month), 0),
    'commission_today', coalesce(sum(commission_iqd)
                          filter (where status = 'completed'
                                    and requested_at >= v_day), 0)
  )
  into v_trips
  from public.trips;

  -- ---- الناس ----
  -- **والنشط منهم لا المسجَّل وحده.** ألف حسابٍ نائم رقمٌ يُطمئن كذباً.
  select jsonb_build_object(
    'drivers',          count(*) filter (where role = 'driver'),
    'drivers_approved', count(*) filter (
                          where role = 'driver' and identity_verified),
    'riders',           count(*) filter (where role = 'rider'),
    'new_month',        count(*) filter (where created_at >= v_month),
    'new_today',        count(*) filter (where created_at >= v_day)
  )
  into v_people
  from public.profiles
  where deleted_at is null;

  return jsonb_build_object(
    'codes',  v_codes,
    'trips',  v_trips,
    'people', v_people,
    -- **الساعة تُعاد.** الرقم بلا وقته لا يُصدَّق: من يرى «اليوم ٣»
    -- ولا يعرف متى قُرئ لا يدري أهو قديمٌ أم لحظته.
    'at', now()
  );
end;
$fn$;

revoke all on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
-- **لا نستدعي `admin_dashboard()` هنا.** محرّر SQL يعمل بدور `postgres`
-- لا بجلسة مشرف، فـ`is_admin()` تردّ false ويخرج «غير مصرّح» — وهو
-- نجاحُ الحارس لا فشلُ الدالة. وقعنا فيها في 0056 من قبل.
select count(*) as "الدالة موجودة"
from pg_proc
where proname = 'admin_dashboard'
  and pronamespace = 'public'::regnamespace;
