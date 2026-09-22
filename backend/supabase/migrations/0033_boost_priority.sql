set search_path = public, extensions;

-- =============================================================================
-- 0033 — الطلب المرفوع سعره: أولوية، وعشرة سائقين بدل خمسة
-- =============================================================================
-- رفعُ السعر في 0032 كان يبدأ جولة جديدة فوراً — وهذا نصف ما يستحقه من
-- دفع أكثر. النصف الآخر: **أن يراه سائقون أكثر، وقبل غيره.**
--
-- ثلاثة تغييرات لغرض واحد:
--
--   ١) **عشرة مقاعد بدل خمسة.** ضِعف الفرص في الجولة الواحدة.
--   ٢) **أولوية في العامل الدوري.** الطلبات المرفوعة تُخدَم أولاً حين
--      تتزاحم عدة رحلات على السائقين أنفسهم.
--   ٣) **أولوية في شاشة السائق.** يظهر أول ما يمرّر لا آخره.
--
-- **ولماذا لا نرفع الجميع إلى عشرة؟** لأن العشرة تعني إشعاراً لعشرة
-- سائقين لطلب واحد، وتسعة منهم يفتحون التطبيق ليجدوه ذهب. تكرار ذلك
-- يعلّمهم تجاهل الإشعارات. نحتفظ بالإزعاج للحظة التي يستحقها.
-- =============================================================================


alter table public.pricing_zones
  add column if not exists boosted_concurrent_offers smallint not null default 10;

comment on column public.pricing_zones.boosted_concurrent_offers is
  'كم سائقاً يرى الطلب معاً بعد أن يرفع الراكب سعره. ضِعف العادي.';


-- -----------------------------------------------------------------------------
-- ١) الإرسال: مقاعد أكثر للمرفوع
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_next_offer(p_trip_id uuid)
returns public.trip_offers
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip      public.trips;
  v_zone      public.pricing_zones;
  v_tried     uuid[];
  v_sent      integer;
  v_live      integer;
  v_need      integer;
  v_seats     integer;
  v_radius    integer;
  v_since     timestamptz;
  v_candidate record;
  v_offer     public.trip_offers;
  v_elapsed   integer;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  v_elapsed := extract(epoch from (now() - v_trip.requested_at))::integer;
  if v_elapsed > v_zone.max_search_seconds then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  select count(*) into v_live
  from public.trip_offers
  where trip_id = p_trip_id and status = 'pending' and expires_at > now();

  -- من رفع سعره يُعرض على ضِعف العدد
  v_seats := case
    when coalesce(v_trip.fare_boost_pct, 0) > 0
      then v_zone.boosted_concurrent_offers
    else v_zone.max_concurrent_offers
  end;

  v_need := v_seats - v_live;
  if v_need <= 0 then
    return null;
  end if;

  v_since := greatest(
    now() - make_interval(secs => v_zone.offer_round_seconds),
    coalesce(v_trip.offers_reset_at, '-infinity'::timestamptz)
  );

  select coalesce(array_agg(driver_id), array[]::uuid[])
  into v_tried
  from public.trip_offers
  where trip_id = p_trip_id and sent_at > v_since;

  select count(*) into v_sent
  from public.trip_offers where trip_id = p_trip_id;

  v_radius := least(
    v_zone.search_radius_m * (1 + (v_sent / 5)),
    v_zone.max_search_radius_m
  );

  for v_candidate in
    select * from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried, v_trip.vehicle_kind
    )
  loop
    insert into public.trip_offers
      (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
    values (
      p_trip_id, v_candidate.driver_id, v_sent + 1, v_candidate.distance_m,
      (v_candidate.distance_m / 6.9)::integer,
      now() + make_interval(secs => v_zone.offer_timeout_s)
    )
    on conflict do nothing
    returning * into v_offer;

    v_sent := v_sent + 1;
  end loop;

  return v_offer;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) العامل الدوري يخدم المرفوع أولاً
-- -----------------------------------------------------------------------------
-- **الترتيب يهمّ حين تتزاحم الرحلات.** رحلتان تبحثان في حيٍّ واحد
-- تتنافسان على السائقين أنفسهم، ومن يُخدَم أولاً يملأ المقاعد أولاً.
-- بلا ترتيب صريح تخدم القاعدة أيّهما صادف — فلا يشتري الرفعُ شيئاً.
create or replace function public.dispatch_tick()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_expired integer := 0;
  v_retried integer := 0;
  v_offline integer := 0;
  v_trip_id uuid;
begin
  with done as (
    update public.trip_offers
    set status = 'expired', responded_at = now()
    where status = 'pending' and expires_at < now()
    returning 1
  )
  select count(*) into v_expired from done;

  -- فصل السائقين الذين انقطع تحديث موقعهم. موقع عمره دقيقتان لا يُعتمد
  -- عليه — أسوأ من لا موقع لأنه يرسل الراكب إلى مكان غادره السائق.
  with gone as (
    update public.drivers
    set status = 'offline'
    where status = 'online'
      and (location_updated_at is null
           or location_updated_at < now() - interval '2 minutes')
    returning 1
  )
  select count(*) into v_offline from gone;

  for v_trip_id in
    select id from public.trips
    where status = 'searching'
    order by fare_boost_pct desc, requested_at
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
$fn$;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar               as "المنطقة",
  max_concurrent_offers      as "عروض عادية",
  boosted_concurrent_offers  as "عروض بعد الرفع",
  search_boost_pct           as "نسبة الرفع ٪"
from public.pricing_zones
where is_active;
