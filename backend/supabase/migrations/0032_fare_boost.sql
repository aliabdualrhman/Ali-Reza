set search_path = public, extensions;

-- =============================================================================
-- 0032 — رفع السعر لتسريع البحث
-- =============================================================================
-- الراكب الذي طال انتظاره يملك خياراً واحداً اليوم: الإلغاء. وهذا خسارة
-- للطرفين — هو لا يصل، ونحن نفقد رحلة كان مستعداً أن يدفع أكثر مقابلها.
--
-- الزر يمنحه خياراً ثالثاً: **يرفع الأجرة ٢٠٪ فيصير الطلب أجذب.**
--
-- **مرة واحدة لكل رحلة.** الراكب المتوتّر يضغط ثلاثاً فيصير السعر ضعفاً،
-- ثم يندم عند الوصول ويرفض الدفع — والدفع نقدي فلا ضمان لنا. مرة واحدة
-- تكفي لتحريك القرار ولا تفتح باب ندمٍ نتحمّله نحن.
-- =============================================================================


alter table public.pricing_zones
  add column if not exists search_boost_pct smallint not null default 20;

comment on column public.pricing_zones.search_boost_pct is
  'كم يرفع الراكب أجرته مرة واحدة لتسريع البحث.';

alter table public.trips
  add column if not exists fare_boost_pct smallint not null default 0,

  -- **لحظة إعادة ضبط الجولة.** `dispatch_next_offer` يستبعد من عُرضت
  -- عليه الرحلة خلال آخر دقيقة. بعد رفع السعر نريد أن يراه **الجميع
  -- الآن** لا بعد انقضاء تلك الدقيقة — فمن دفع أكثر دفع ليصل أسرع.
  add column if not exists offers_reset_at timestamptz;

comment on column public.trips.fare_boost_pct is
  'كم رفع الراكب أجرته. صفر = لم يرفع. يُضبط مرة واحدة.';


-- -----------------------------------------------------------------------------
-- ١) الرفع
-- -----------------------------------------------------------------------------
create or replace function public.boost_trip_fare(p_trip_id uuid)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip public.trips;
  v_zone public.pricing_zones;
  v_new  numeric(10,2);
begin
  select * into v_trip from public.trips
  where id = p_trip_id and rider_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك'
      using errcode = 'insufficient_privilege';
  end if;

  -- **أثناء البحث وحده.** بعد أن يقبل سائق صار السعر عقداً بين طرفين،
  -- ورفعُه حينها هبة لا تسريع.
  if v_trip.status <> 'searching' then
    raise exception 'رفع السعر متاح أثناء البحث عن سائق فقط';
  end if;

  if v_trip.fare_boost_pct > 0 then
    raise exception 'رفعت السعر لهذه الرحلة بالفعل';
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  v_new := round(
    (coalesce(v_trip.fare_locked_iqd, v_trip.fare_estimated_iqd)
       * (1 + v_zone.search_boost_pct / 100.0)) / 250
  ) * 250;

  update public.trips
  set fare_estimated_iqd = v_new,
      -- الأجرة مجمَّدة منذ 0028، فرفعُها يجب أن يمسّ النسختين معاً
      -- وإلا أنهى `complete_trip` الرحلة بالسعر القديم.
      fare_locked_iqd    = v_new,
      fare_boost_pct     = v_zone.search_boost_pct,
      offers_reset_at    = now()
  where id = p_trip_id
  returning * into v_trip;

  -- نُبطل العروض المعلّقة: السائق الذي يقرأ عرضاً الآن يرى السعر القديم،
  -- وقبولُه بذلك السعر يظلمه. العرض التالي يحمل الجديد.
  update public.trip_offers
  set status = 'cancelled', responded_at = now()
  where trip_id = p_trip_id and status = 'pending';

  -- وإرسال فوري بالسعر الجديد بدل انتظار النبضة
  perform public.dispatch_next_offer(p_trip_id);

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الإرسال يحترم إعادة ضبط الجولة
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

  v_need := v_zone.max_concurrent_offers - v_live;
  if v_need <= 0 then
    return null;
  end if;

  -- نافذة الجولة: آخر `offer_round_seconds`، **أو منذ رفع السعر إن كان
  -- أحدث**. رفعُ السعر يبدأ جولة جديدة فوراً — من دفع أكثر دفع ليصل
  -- أسرع، لا لينتظر انقضاء دقيقة بدأت قبل أن يدفع.
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


revoke all on function public.boost_trip_fare from public, anon;
grant execute on function public.boost_trip_fare(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar     as "المنطقة",
  search_boost_pct as "رفع البحث ٪"
from public.pricing_zones
where is_active;
