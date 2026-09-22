-- =============================================================================
-- 0085 — تقدير أجرة التسوّق، وإشعار السائق بإلغاء الراكب
-- =============================================================================
-- أمران يشتركان في مبدأ واحد: **لا يُترك أحد الطرفين يخمّن.**
--
--   • الراكب كان يحدّد المحل والتسليم ثم يضغط «اطلب» بلا أن يعرف كم
--     ستكلّفه الأجرة. وهو الرقم الوحيد الذي نتحكّم فيه — ثمن البضاعة
--     تقديرُه هو، أما التوصيل فسعرُنا.
--
--   • والسائق كان يقود إلى الراكب، فيُلغي الراكب، فيبقى ذاهباً إلى
--     نقطةٍ لا أحد فيها حتى يفتح التطبيق. وقد يقطع كيلومترين قبل أن
--     يعرف.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) تقدير أجرة التسوّق قبل الطلب
-- -----------------------------------------------------------------------------
-- **الحساب في القاعدة كما كل سعر.** التطبيق يعمل على جهاز المستخدم،
-- ومن يفكّك الحزمة يستطيع تعديل حسابٍ فيها ويطلب بأجرة صفر.
--
-- ولا نستعمل `estimate_multi_trip`: لا تعرف حدّ التسوّق الأدنى، فتردّ
-- رقماً يخالف ما تحسبه `request_shopping` — ورقمان مختلفان لفعلٍ واحد
-- أسوأ من رقمٍ غائب.
create or replace function public.estimate_shopping(
  p_shop_lat   double precision,
  p_shop_lng   double precision,
  p_distance_m integer,
  p_duration_s integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_shop  geography;
  v_zone  uuid;
  v_fare  jsonb;
  v_min   numeric(10,2);
  v_total numeric(10,2);
begin
  if public.referral_setting('shopping_enabled', 1) = 0 then
    return jsonb_build_object(
      'available', false,
      'message', coalesce(
        (select nullif(btrim(value), '') from public.public_settings
         where key = 'shopping_closed_msg'),
        'خدمة التسوّق متوقّفة حالياً.')
    );
  end if;

  v_shop := st_setsrid(st_makepoint(p_shop_lng, p_shop_lat), 4326)::geography;
  v_zone := public.zone_for_point(v_shop);

  if v_zone is null then
    return jsonb_build_object(
      'available', false,
      'message', 'المحل خارج نطاق الخدمة'
    );
  end if;

  v_fare  := public.calculate_fare(v_zone, p_distance_m, p_duration_s, 1.0);
  v_min   := public.referral_setting('shopping_min_fare_iqd', 1500);
  v_total := greatest((v_fare ->> 'total')::numeric, v_min);

  return jsonb_build_object(
    'available', true,
    'total', v_total,
    'minimum', v_min,
    'at_minimum', v_total <= v_min
  );
end;
$fn$;

revoke all on function public.estimate_shopping(
  double precision, double precision, integer, integer) from public, anon;
grant execute on function public.estimate_shopping(
  double precision, double precision, integer, integer) to authenticated;


-- -----------------------------------------------------------------------------
-- ٢) السائق يُخبَر حين يُلغي الراكب
-- -----------------------------------------------------------------------------
-- **الصفّ يكفي.** مُشغّل 0061 يلتقط كل صفٍّ في `notifications` ويدفعه
-- إلى أجهزة صاحبه — فلا نحتاج دالةَ حافةٍ جديدة، ويظهر الخبر في الجرس
-- أيضاً لمن أغلق إشعارات النظام.
create or replace function public.notify_driver_of_cancel()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_name text;
begin
  if new.status <> 'cancelled' or old.status = 'cancelled' then
    return new;
  end if;

  -- سائقٌ لم يُسند بعد لا ينتظر شيئاً.
  if new.driver_id is null then return new; end if;

  -- **الراكب وحده.** إلغاء السائق نفسه لا يُشعَر به، وإلغاء المدير
  -- يصله بقناةٍ أخرى.
  if new.cancelled_by is distinct from new.rider_id then return new; end if;

  select split_part(full_name, ' ', 1) into v_name
  from public.profiles where id = new.rider_id;

  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (
    new.driver_id,
    'أُلغيت الرحلة من قبل الراكب',
    format('ألغى %s الطلب رقم %s. أنت متاحٌ لطلبٍ جديد الآن.',
           coalesce(v_name, 'الراكب'), new.trip_number),
    'direct',
    new.rider_id
  );

  return new;
end;
$fn$;

drop trigger if exists trips_notify_driver_cancel on public.trips;
create trigger trips_notify_driver_cancel
  after update of status on public.trips
  for each row execute function public.notify_driver_of_cancel();


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'estimate_shopping')                as "دالة التقدير (١)",
  (select count(*) from pg_trigger
   where tgname = 'trips_notify_driver_cancel')        as "مُشغّل الإشعار (١)";
