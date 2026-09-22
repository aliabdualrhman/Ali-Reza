set search_path = public, extensions;

-- =============================================================================
-- 0017 — البحث المستمر عن سائق، وتشغيل العامل الدوري
-- =============================================================================
-- **ثغرة أخطر اكتُشفت أثناء هذا العمل:** كتبنا `expire_stale_offers()` في
-- 0006 لتنهي العروض المنتهية وتنتقل للسائق التالي… **ولم نجدولها إطلاقاً.**
--
-- الأثر: عرض لم يردّ عليه السائق يبقى `pending` إلى الأبد، والرحلة عالقة
-- في `searching` بلا محاولة تالية. لم نلحظه لأن اختباراتنا كانت بسائق
-- واحد يقبل فوراً.
--
-- **والتغيير المطلوب:** لا نقول للراكب "لا يوجد سائق" بعد ثماني محاولات.
-- نستمر بالبحث حتى يلغي هو أو تنتهي مهلة طويلة. السائق قد يتصل بعد
-- دقيقة، والراكب الذي رُفض طلبه لن يعيد المحاولة غالباً.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ١) مهلة البحث القصوى
-- -----------------------------------------------------------------------------
alter table public.pricing_zones
  add column if not exists max_search_seconds integer not null default 600;

comment on column public.pricing_zones.max_search_seconds is
  'أقصى مدة بحث قبل الاستسلام. ١٠ دقائق افتراضياً.';


-- -----------------------------------------------------------------------------
-- ٢) إعادة كتابة الإرسال: نستمر بدل الاستسلام
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_next_offer(p_trip_id uuid)
returns public.trip_offers
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_trip     public.trips;
  v_zone     public.pricing_zones;
  v_tried    uuid[];
  v_rank     smallint;
  v_radius   integer;
  v_candidate record;
  v_offer    public.trip_offers;
  v_elapsed  integer;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;   -- الرحلة قُبلت أو أُلغيت بينما كنا نبحث
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  -- هل تجاوزنا مهلة البحث الكلية؟
  v_elapsed := extract(epoch from (now() - v_trip.requested_at))::integer;
  if v_elapsed > v_zone.max_search_seconds then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  -- لا يوجد عرض معلّق حالياً؟ (وإلا ننتظر رده)
  if exists (
    select 1 from public.trip_offers
    where trip_id = p_trip_id and status = 'pending' and expires_at > now()
  ) then
    return null;
  end if;

  -- السائقون الذين عُرضت عليهم الرحلة في **الجولة الحالية**.
  --
  -- **التغيير الجوهري:** بعد استنفاد كل السائقين نبدأ جولة جديدة بدل
  -- الاستسلام. السائق الذي رفض قبل دقيقتين قد يكون فرغ الآن، والذي كان
  -- بعيداً قد اقترب.
  select coalesce(array_agg(driver_id), array[]::uuid[]), count(*)
  into v_tried, v_rank
  from public.trip_offers
  where trip_id = p_trip_id
    and sent_at > now() - make_interval(secs => 120);   -- جولة = دقيقتان

  -- توسيع النطاق تدريجياً داخل الجولة
  v_radius := least(
    v_zone.search_radius_m * (1 + (v_rank / 3)),
    v_zone.max_search_radius_m
  );

  select * into v_candidate
  from public.find_nearby_drivers(v_trip.pickup_location, v_radius, 1, v_tried);

  if not found then
    -- لا سائق متاح الآن — **لا نستسلم**. نترك الرحلة `searching`
    -- والعامل الدوري سيعيد المحاولة بعد ثوانٍ.
    return null;
  end if;

  insert into public.trip_offers (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
  values (
    p_trip_id,
    v_candidate.driver_id,
    v_rank + 1,
    v_candidate.distance_m,
    (v_candidate.distance_m / 6.9)::integer,
    now() + make_interval(secs => v_zone.offer_timeout_s)
  )
  returning * into v_offer;

  return v_offer;
end;
$$;


-- -----------------------------------------------------------------------------
-- ٣) العامل الدوري: ينهي المنتهي ويعيد المحاولة
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_tick()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_expired integer := 0;
  v_retried integer := 0;
  v_offline integer := 0;
  v_trip_id uuid;
begin
  -- إنهاء العروض التي انتهت مهلتها
  with done as (
    update public.trip_offers
    set status = 'expired', responded_at = now()
    where status = 'pending' and expires_at < now()
    returning 1
  )
  select count(*) into v_expired from done;

  -- فصل السائقين الذين انقطع تحديث موقعهم.
  -- موقع عمره دقيقتان لا يُعتمد عليه — أسوأ من لا موقع لأنه يرسل
  -- الراكب إلى مكان غادره السائق.
  with gone as (
    update public.drivers
    set status = 'offline'
    where status = 'online'
      and (location_updated_at is null
           or location_updated_at < now() - interval '2 minutes')
    returning 1
  )
  select count(*) into v_offline from gone;

  -- إعادة المحاولة لكل رحلة ما زالت تبحث
  for v_trip_id in
    select id from public.trips where status = 'searching'
  loop
    perform public.dispatch_next_offer(v_trip_id);
    v_retried := v_retried + 1;
  end loop;

  return jsonb_build_object(
    'expired_offers', v_expired,
    'searching_trips', v_retried,
    'drivers_set_offline', v_offline,
    'at', now()
  );
end;
$$;

revoke all on function public.dispatch_tick from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٤) الجدولة — هذا ما كان ناقصاً
-- -----------------------------------------------------------------------------
-- pg_cron أدق تفصيل يقبله هو الدقيقة. ونحن نحتاج كل خمس ثوانٍ، فنجدول
-- مهمة واحدة كل دقيقة تدور داخلياً اثنتي عشرة مرة بفاصل خمس ثوانٍ.
--
-- حيلة مقبولة عند هذا الحجم. عند آلاف الرحلات يومياً تُستبدل بخدمة
-- مستقلة تحتفظ بشبكة السائقين في الذاكرة.
-- -----------------------------------------------------------------------------
create extension if not exists pg_cron with schema extensions;

create or replace function public.dispatch_minute()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  i integer;
begin
  for i in 1..12 loop
    perform public.dispatch_tick();
    -- pg_sleep داخل مهمة مجدولة مقبول: تعمل في اتصالها الخاص ولا
    -- تحجب أحداً. لكنها تشغل اتصالاً لدقيقة كاملة — سبب إضافي
    -- لاستبدالها بخدمة مستقلة عند التوسّع.
    if i < 12 then perform pg_sleep(5); end if;
  end loop;
end;
$$;

-- نحذف أي جدولة سابقة قبل الإضافة — يجعل الملف آمناً للتكرار
select cron.unschedule('zanbour-dispatch')
where exists (select 1 from cron.job where jobname = 'zanbour-dispatch');

select cron.schedule(
  'zanbour-dispatch',
  '* * * * *',                       -- كل دقيقة
  $cron$ select public.dispatch_minute(); $cron$
);


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  jobname   as "المهمة",
  schedule  as "الجدولة",
  active    as "مفعّلة"
from cron.job
where jobname = 'zanbour-dispatch';
