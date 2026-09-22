-- =============================================================================
-- 0079 — مفتاح التسوّق مستقلٌّ عن مفتاح طلبات الدراجات
-- =============================================================================
-- **عطلٌ في 0077 لم أنتبه له.** طلب التسوّق يُنشأ بـ`vehicle_kind = 'bike'`،
-- فيمرّ على مرشّح المركبة في `find_nearby_drivers`:
--
--     دراجة  →  السائق دراجة، أو تكتكٌ فعّل «أقبل طلبات الدراجات»
--
-- فسائق تكتكٍ أطفأ طلبات الركّاب بالدراجة — وهو حقّه — لا تصله طلبات
-- تسوّقٍ أبداً، وإن فتح مفتاح التسوّق. **مفتاحٌ يُفتح ولا يفعل شيئاً**،
-- وهو أسوأ من مفتاحٍ غائب: يظنّ السائق أن لا طلبات في السوق.
--
-- والمفتاحان مستقلّان بطبيعتهما: نقل راكبٍ على دراجة قرارٌ عن المركبة،
-- وشراء بضاعةٍ بمالٍ من الجيب قرارٌ عن النقد. فلا يجوز أن يحكم أحدهما
-- الآخر.
--
-- ------------------------------------------------------------------
-- والسعر سعر الدراجة، ولا زيادة تكتك — وهذا قائمٌ لا يحتاج تغييراً
-- ------------------------------------------------------------------
-- زيادة التكتك تُطبَّق في `calculate_multi_fare` حين `p_kind = 'tuktuk'`.
-- وطلب التسوّق يُسعَّر بـ`calculate_fare` — وهي بلا `p_kind` إطلاقاً،
-- فلا سبيل لزيادةٍ أن تدخلها. نثبّت ذلك بتعليقٍ لا بكود.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) البحث يقبل «أيّ مركبة»
-- -----------------------------------------------------------------------------
-- **`null` تعني: لا تُرشّح بالمركبة.** بديلاً عن دالةٍ ثانية تكرّر
-- الاستعلام كلّه — والتكرار هو ما لدغَنا مرتين أمس.
--
-- والبصمة لم تتغيّر: `p_kind` له قيمة افتراضية أصلاً، فكل من يستدعيها
-- اليوم يبقى على حاله.
create or replace function public.find_nearby_drivers(
  p_pickup     geography,
  -- **القيمة الافتراضية تبقى.** بوستغرس يرفض إزالتها من دالةٍ قائمة
  -- بـ`create or replace` — ‏42P13. وقد حذفتُها سهواً فتعطّل الترحيل.
  p_radius_m   integer default 3000,
  p_limit      integer default 10,
  p_exclude    uuid[]  default '{}',
  p_kind       public.vehicle_kind default 'bike'
)
returns table (
  driver_id     uuid,
  distance_m    integer,
  rating_avg    numeric,
  full_name     text,
  vehicle_plate text
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select
    d.id,
    st_distance(d.current_location, p_pickup)::integer as distance_m,
    d.rating_avg,
    p.full_name,
    d.vehicle_plate
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.is_available_for_matching
    and d.current_location is not null
    and d.location_updated_at > now() - interval '90 seconds'
    and not (d.id = any(p_exclude))
    and p.is_blocked = false
    and st_dwithin(d.current_location, p_pickup, p_radius_m)
    and (
      p_kind is null
      or case p_kind
           when 'tuktuk' then d.vehicle_kind = 'tuktuk'
           else d.vehicle_kind = 'bike'
                or (d.vehicle_kind = 'tuktuk' and d.accepts_bike_trips)
         end
    )
    and not exists (
      select 1 from public.trips t
      where t.driver_id = d.id
        and t.status in ('accepted', 'driver_arrived', 'in_progress')
    )
  order by st_distance(d.current_location, p_pickup)
  limit p_limit;
$fn$;

revoke all on function public.find_nearby_drivers(
  geography, integer, integer, uuid[], public.vehicle_kind)
  from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٢) طلب التسوّق لا يُرشَّح بالمركبة
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
  v_candidate record;
  v_offer     public.trip_offers;
  v_sent      integer;
  v_need      integer;
  v_radius    integer;
  v_tried     uuid[];
  v_since     timestamptz;
  v_shopping  boolean;
  v_kind      public.vehicle_kind;
begin
  select * into v_trip from public.trips where id = p_trip_id;
  if v_trip.status <> 'searching' then return null; end if;

  v_shopping := (v_trip.kind = 'shopping');

  -- **التسوّق يفتح البابين.** دراجةً كان السائق أو تكتكاً، ما دام
  -- فتح مفتاح التسوّق. والسعر سعر الدراجة في الحالين.
  v_kind := case when v_shopping then null else v_trip.vehicle_kind end;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);
  if not found then return null; end if;

  v_need := case when coalesce(v_trip.fare_boost_iqd, 0) > 0 then 10 else 5 end;

  v_since := greatest(
    coalesce(v_trip.requested_at, '-infinity'::timestamptz),
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
    select c.*
    from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried, v_kind
    ) c
    join public.drivers d on d.id = c.driver_id
    where (not v_shopping or d.accepts_shopping)
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


comment on column public.drivers.accepts_shopping is
  'يستقبل طلبات التسوّق — مستقلٌّ عن accepts_bike_trips تماماً. '
  'مغلقٌ افتراضاً: يتطلّب نقداً في الجيب.';

comment on column public.trips.kind is
  'ride = رحلة راكب · shopping = طلب تسوّق. المحل هو نقطة الانطلاق، '
  'والتسعير بسعر الدراجة دائماً — لا زيادة تكتك على التسوّق.';


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
-- من يستقبل التسوّق الآن، وأيّ مركبةٍ يقود.
select
  d.vehicle_kind      as "المركبة",
  d.accepts_shopping  as "يقبل التسوّق",
  d.accepts_bike_trips as "يقبل الدراجات",
  count(*)            as "العدد"
from public.drivers d
group by 1, 2, 3
order by 1, 2;
