-- =============================================================================
-- 0053 — تسجيل الرحلة التي أُنهيت بعيداً عن وجهتها
-- =============================================================================
-- **حارسٌ في نظام الدعوة لا يعمل بدون هذا الملف.**
--
-- اتفقنا أن رحلةً أنهاها السائق وهو بعيد عن نقطة الوصول لا تُحتسب ضمن
-- الرحلات الثلاث التي تفتح المكافأة. لأنها أسهل طريق للاحتيال: يقبل
-- العرض، ويمضي مئة متر، ويضغط «وصلت» — ثلاث مرات في عشر دقائق.
--
-- **لكنّ التطبيق يحذّر ولا يسجّل.** يسأل السائق «أنت بعيد، أمتأكد؟»،
-- فيضغط «نعم» ويمضي، **ولا يبقى أثر**. فلا سبيل لاحقاً لمعرفة أيّ رحلة
-- أُنهيت في مكانها وأيّها في منتصف الطريق.
--
-- **ولماذا لا نمنع الإنهاء البعيد أصلاً؟** لأن له أعذاراً حقيقية: الراكب
-- يطلب النزول قبل الوصول، أو الشارع مغلق، أو الوجهة على الخريطة خاطئة.
-- المنع يعاقب الصادق ليردع الكاذب. **نسجّل ونحاسب لا نمنع.**
--
-- والعمود يفيد ما هو أبعد من الدعوة: نمطُ سائقٍ ينهي رحلاته كلها بعيداً
-- إشارةٌ تستحق النظر، حتى بلا نظام مكافآت.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) العمودان
-- -----------------------------------------------------------------------------
alter table public.trips
  -- المسافة بين موقع السائق ونقطة الوصول لحظة الإنهاء، بالأمتار.
  -- **نخزّن المسافة لا العلامة وحدها**: الحدّ اليوم ٤٠٠ متر وقد نغيّره،
  -- ولو خزّنّا `true/false` لصارت البيانات القديمة بلا معنى بعد التغيير.
  add column if not exists completed_distance_m integer,

  -- هل تجاوز الحدّ الذي أنذره التطبيق ومضى رغمه؟
  add column if not exists completed_far boolean not null default false;

comment on column public.trips.completed_distance_m is
  'بُعد السائق عن نقطة الوصول لحظة الإنهاء. فارغ = لم يُقَس (لا موقع أو لا إحداثيات).';

comment on column public.trips.completed_far is
  'أُنهيت رغم تحذير البُعد. لا تُحتسب في مكافآت الدعوة.';

-- استعلام الدعوة يعدّ الرحلات المكتملة السليمة لسائق أو راكب.
create index if not exists trips_completed_far_idx
  on public.trips (driver_id, status) where not completed_far;


-- -----------------------------------------------------------------------------
-- ٢) `complete_trip` تقبل المسافة وتحكم بنفسها
-- -----------------------------------------------------------------------------
-- **الحكم في القاعدة لا في التطبيق.** التطبيق يرسل مسافةً قاسها، والقاعدة
-- تقارنها بحدّ المنطقة وتقرّر. ولو أرسل التطبيق `completed_far` جاهزةً
-- لأمكن تزويرها بتعديل الحزمة — ومن يحتال على مكافأة يحتال على هذا.
alter table public.pricing_zones
  add column if not exists dropoff_warn_radius_m integer not null default 400;

comment on column public.pricing_zones.dropoff_warn_radius_m is
  'الحد الذي ينذر عنده التطبيق السائق. ما بعده يُسجَّل completed_far.';


create or replace function public.mark_completion_distance(
  p_trip_id    uuid,
  p_distance_m integer
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip   public.trips;
  v_radius integer;
begin
  if p_distance_m is null or p_distance_m < 0 then
    return;   -- لا قياس، لا حكم. ولا نُفشل الإنهاء بسببه.
  end if;

  select * into v_trip from public.trips where id = p_trip_id;
  if not found then return; end if;

  -- **السائق وحده يبلّغ عن رحلته.** ولو قبلنا من أي مستدعٍ لأمكن لراكب
  -- أن يَسِم رحلة سائقٍ آخر بأنها بعيدة فيحرمه مكافأته.
  if v_trip.driver_id is distinct from auth.uid() then
    raise exception 'ليست رحلتك' using errcode = 'insufficient_privilege';
  end if;

  select coalesce(z.dropoff_warn_radius_m, 400) into v_radius
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  perform set_config('app.bypass_guards', 'on', true);

  update public.trips
  set completed_distance_m = p_distance_m,
      completed_far        = p_distance_m > coalesce(v_radius, 400)
  where id = p_trip_id;

  perform set_config('app.bypass_guards', 'off', true);
end;
$fn$;


-- **الحدّان من اللوحة لا من الكود.** ما يصلح للناصرية قد لا يصلح لمدينة
-- أخرى، وتغييرُ رقمٍ لا يستحق بناءً جديداً ونشراً ومراجعة.
alter table public.pricing_zones
  add column if not exists min_qualifying_distance_m integer not null default 1000,
  add column if not exists min_qualifying_fare_iqd   numeric(10,2) not null default 1000;

comment on column public.pricing_zones.min_qualifying_distance_m is
  'أقل مسافة تجعل الرحلة مؤهِّلة لمكافآت الدعوة.';
comment on column public.pricing_zones.min_qualifying_fare_iqd is
  'أقل أجرة تجعل الرحلة مؤهِّلة لمكافآت الدعوة.';

-- -----------------------------------------------------------------------------
-- ٣) الرحلات المؤهِّلة — تعريفٌ واحد يقرؤه نظام الدعوة
-- -----------------------------------------------------------------------------
-- **دالةٌ لا استعلامٌ مكرّر.** شروط «الرحلة المؤهِّلة» ستُقرأ من ثلاثة
-- مواضع على الأقل: عند احتساب المكافأة، وفي اللوحة، وفي التقارير. وكل
-- نسخةٍ منها تتباعد عن أختها مع أول تعديل.
create or replace function public.qualifying_trip_count(
  p_user_id uuid,
  p_since   timestamptz default '-infinity'
)
returns integer
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select count(*)::integer
  from public.trips t
  join public.pricing_zones z
    on z.id = public.zone_for_point(t.pickup_location)
  where (t.rider_id = p_user_id or t.driver_id = p_user_id)
    and t.status = 'completed'
    and t.requested_at >= p_since
    -- أُنهيت في مكانها
    and not t.completed_far
    -- ورحلةٌ حقيقية لا مسافة رمزية
    and coalesce(t.actual_distance_m, t.estimated_distance_m, 0)
        >= z.min_qualifying_distance_m
    and coalesce(t.fare_final_iqd, 0) >= z.min_qualifying_fare_iqd;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.mark_completion_distance(uuid, integer)
  from public, anon;
grant execute on function public.mark_completion_distance(uuid, integer)
  to authenticated;

revoke all on function public.qualifying_trip_count(uuid, timestamptz)
  from public, anon;
grant execute on function public.qualifying_trip_count(uuid, timestamptz)
  to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  city_name_ar               as "المنطقة",
  dropoff_warn_radius_m      as "حد التحذير (م)",
  min_qualifying_distance_m  as "أقل مسافة مؤهِّلة",
  min_qualifying_fare_iqd::bigint as "أقل أجرة مؤهِّلة"
from public.pricing_zones
order by city_name_ar;
