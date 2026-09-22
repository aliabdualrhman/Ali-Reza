set search_path = public, extensions;

-- =============================================================================
-- 0031 — التكتك: نوع مركبة ثانٍ
-- =============================================================================
-- **القاعدة الحاكمة، ومنها يتفرّع كل ما تحتها:**
--
--   الزيادة تتبع **نوع الطلب** لا نوع مركبة السائق.
--
-- سائق تكتك يقبل طلب دراجة يأخذ سعر الدراجة كاملاً بلا زيادة. وهذا عدل
-- لا تقتير: الراكب طلب دراجة ودفع سعرها، وما ركبه بعد ذلك شأن السائق.
-- ولو ربطنا الزيادة بالمركبة لصار الراكب يدفع ٤٥٪ إضافية لأن السائق
-- الأقرب صادف أن يملك تكتكاً — وهو ما يجعله يلغي ويعيد الطلب.
--
-- ولذلك السعر يُجمَّد لحظة الطلب في `fare_locked_iqd` (0028): الراكب رأى
-- رقماً ووافق عليه قبل أن يُعرف من سيأتيه أصلاً.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) النوع
-- -----------------------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from pg_type where typname = 'vehicle_kind') then
    create type public.vehicle_kind as enum ('bike', 'tuktuk');
  end if;
end
$do$;

alter table public.drivers
  add column if not exists vehicle_kind public.vehicle_kind not null default 'bike',

  -- **يخصّ سائق التكتك وحده.** سائق الدراجة لا يستطيع خدمة طلب تكتك
  -- مهما فعل، فالعمود بلا معنى عنده ويبقى على قيمته الافتراضية.
  add column if not exists accepts_bike_trips boolean not null default true;

comment on column public.drivers.accepts_bike_trips is
  'سائق التكتك يقبل طلبات الدراجات أيضاً. بلا أثر على سائق الدراجة.';

alter table public.trips
  add column if not exists vehicle_kind public.vehicle_kind not null default 'bike';

comment on column public.trips.vehicle_kind is
  'ما طلبه الراكب. عليه تُحسب الزيادة، لا على مركبة من جاءه.';

alter table public.pricing_zones
  add column if not exists tuktuk_surcharge_pct smallint not null default 45;


-- -----------------------------------------------------------------------------
-- ٢) التسجيل يلتقط نوع المركبة
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  requested_role public.user_role;
  v_full_name text;
  v_phone     text;
  v_address   text;
  v_dob       date;
  v_age       integer;
  v_kind      public.vehicle_kind;
begin
  requested_role := coalesce(
    nullif(new.raw_user_meta_data ->> 'role', '')::public.user_role, 'rider');

  v_full_name := btrim(new.raw_user_meta_data ->> 'full_name');
  v_phone     := nullif(btrim(new.raw_user_meta_data ->> 'phone'), '');
  v_address   := nullif(btrim(new.raw_user_meta_data ->> 'address'), '');
  v_dob       := (nullif(new.raw_user_meta_data ->> 'date_of_birth', ''))::date;

  if v_full_name is null or v_full_name = '' then
    raise exception 'الاسم الكامل مطلوب للتسجيل';
  end if;

  if array_length(regexp_split_to_array(v_full_name, '\s+'), 1) < 3 then
    raise exception 'الاسم الثلاثي مطلوب: الاسم واسم الأب واسم الجد';
  end if;

  if v_phone is null then
    raise exception 'رقم الهاتف مطلوب للتسجيل';
  end if;

  if v_address is null then
    raise exception 'العنوان مطلوب للتسجيل';
  end if;

  if v_dob is null then
    raise exception 'تاريخ الميلاد مطلوب للتسجيل';
  end if;

  v_age := extract(year from age(current_date, v_dob))::integer;
  if requested_role = 'driver' and v_age < 18 then
    raise exception 'العمر الأدنى لتسجيل السائق ١٨ سنة';
  elsif v_age < 16 then
    raise exception 'العمر الأدنى للتسجيل ١٦ سنة';
  end if;

  if exists (select 1 from public.profiles where phone = v_phone) then
    raise exception 'رقم الهاتف مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;
  if exists (select 1 from public.profiles where full_name = v_full_name) then
    raise exception 'الاسم مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;

  insert into public.profiles (
    id, full_name, email, date_of_birth, address, phone, role, locale
  ) values (
    new.id, v_full_name, new.email, v_dob, v_address, v_phone, requested_role,
    coalesce(nullif(new.raw_user_meta_data ->> 'locale', ''), 'ar')
  );

  if requested_role = 'driver' then
    v_kind := coalesce(
      nullif(new.raw_user_meta_data ->> 'vehicle_kind', '')::public.vehicle_kind,
      'bike');

    insert into public.drivers (
      id, vehicle_type, vehicle_plate, vehicle_color, vehicle_kind
    ) values (
      new.id,
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_type'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_plate'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_color'), ''),
      v_kind
    );
  end if;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) البحث يحترم النوع
-- -----------------------------------------------------------------------------
-- **غير المتماثل مقصود:** طلب التكتك لا يصل إلا سائق تكتك، وطلب الدراجة
-- يصل سائقي الدراجات **وسائقي التكتك الذين فتحوا ذلك**. عكسه مستحيل
-- مادياً — لا يستطيع سائق دراجة أن يخدم من طلب تكتكاً.
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname = 'find_nearby_drivers' and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

create or replace function public.find_nearby_drivers(
  p_pickup     geography,
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
      case p_kind
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


-- الإرسال يمرّر نوع الرحلة إلى البحث
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

  select coalesce(array_agg(driver_id), array[]::uuid[])
  into v_tried
  from public.trip_offers
  where trip_id = p_trip_id
    and sent_at > now() - make_interval(secs => v_zone.offer_round_seconds);

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
-- ٤) التسعير: زيادة التكتك قبل التقريب
-- -----------------------------------------------------------------------------
-- **ترتيب العمليات يهمّ:** الزيادة تُحسب على المجموع قبل التقريب لأقرب
-- ٢٥٠. لو قرّبنا ثم زدنا لتراكم خطأ التقريب مرتين على الرحلة الواحدة.
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname in ('calculate_multi_fare', 'estimate_multi_trip')
      and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

create or replace function public.calculate_multi_fare(
  p_zone_id   uuid,
  p_leg1_m    integer,
  p_leg1_s    integer,
  p_leg2_m    integer default null,
  p_leg2_s    integer default null,
  p_stopover  boolean default false,
  p_surge     numeric default null,
  p_kind      public.vehicle_kind default 'bike'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  z          public.pricing_zones;
  v_first    jsonb;
  v_leg1     numeric;
  v_leg2     numeric := 0;
  v_stop_add numeric := 0;
  v_kind_add numeric := 0;
  v_total    numeric;
  v_comm     numeric;
begin
  select * into z from public.pricing_zones where id = p_zone_id;
  if not found then
    raise exception 'المنطقة غير معروفة';
  end if;

  v_first := public.calculate_fare(p_zone_id, p_leg1_m, p_leg1_s, p_surge);
  v_leg1  := (v_first ->> 'total')::numeric;

  if coalesce(p_leg2_m, 0) > 0 then
    v_leg2 := (p_leg2_m / 1000.0) * z.per_km_iqd
              * (1 - z.second_leg_discount_pct / 100.0);
  end if;

  v_total := v_leg1 + v_leg2;

  if p_stopover then
    v_stop_add := v_total * z.stopover_surcharge_pct / 100.0;
    v_total := v_total + v_stop_add;
  end if;

  if p_kind = 'tuktuk' then
    v_kind_add := v_total * z.tuktuk_surcharge_pct / 100.0;
    v_total := v_total + v_kind_add;
  end if;

  v_total := round(v_total / 250) * 250;
  v_comm  := round(v_total * z.commission_rate, 2);

  return jsonb_build_object(
    'leg1_fare',      round(v_leg1, 2),
    'leg2_fare',      round(v_leg2, 2),
    'stopover_add',   round(v_stop_add, 2),
    'stopover',       p_stopover,
    'stopover_free_minutes', z.stopover_free_minutes,
    'vehicle_kind',   p_kind,
    'tuktuk_add',     round(v_kind_add, 2),
    'tuktuk_pct',     z.tuktuk_surcharge_pct,
    'total',          v_total,
    'commission',     v_comm,
    'driver_earning', v_total - v_comm,
    'surge_multiplier', (v_first ->> 'surge_multiplier')::numeric
  );
end;
$fn$;


create or replace function public.estimate_multi_trip(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_leg1_m     integer,
  p_leg1_s     integer,
  p_leg2_m     integer default null,
  p_leg2_s     integer default null,
  p_stopover   boolean default false,
  p_kind       public.vehicle_kind default 'bike'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_pickup geography;
  v_zone   uuid;
begin
  v_pickup := st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography;
  v_zone   := public.zone_for_point(v_pickup);

  if v_zone is null then
    return jsonb_build_object('available', false,
      'message', 'نقطة الانطلاق خارج نطاق الخدمة');
  end if;

  return public.calculate_multi_fare(
    v_zone, p_leg1_m, p_leg1_s, p_leg2_m, p_leg2_s, p_stopover, null, p_kind
  ) || jsonb_build_object('available', true);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) الطلب يحمل النوع
-- -----------------------------------------------------------------------------
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname = 'request_trip' and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

create or replace function public.request_trip(
  p_pickup_lat      double precision,
  p_pickup_lng      double precision,
  p_dropoff_lat     double precision,
  p_dropoff_lng     double precision,
  p_pickup_address  text,
  p_dropoff_address text,
  p_distance_m      integer,
  p_duration_s      integer,
  p_payment_method  public.payment_method default 'cash',
  p_note            text default null,
  p_coupon_code     text default null,
  p_stop2_lat       double precision default null,
  p_stop2_lng       double precision default null,
  p_stop2_address   text default null,
  p_leg2_m          integer default null,
  p_leg2_s          integer default null,
  p_stopover        boolean default false,
  p_vehicle_kind    public.vehicle_kind default 'bike'
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_rider    public.profiles;
  v_pickup   geography;
  v_dropoff  geography;
  v_stop2    geography;
  v_zone_id  uuid;
  v_fare     jsonb;
  v_trip     public.trips;
  v_coupon   jsonb;
  v_cid      uuid;
  v_disc     numeric(10,2) := 0;
  v_multi    boolean;
  v_final    geography;
  v_final_ad text;
begin
  select * into v_rider from public.profiles where id = auth.uid();
  if not found or v_rider.is_blocked then
    raise exception 'غير مصرّح لك بطلب رحلة' using errcode = 'insufficient_privilege';
  end if;

  v_pickup  := st_setsrid(st_makepoint(p_pickup_lng,  p_pickup_lat),  4326)::geography;
  v_dropoff := st_setsrid(st_makepoint(p_dropoff_lng, p_dropoff_lat), 4326)::geography;

  v_multi := p_stop2_lat is not null and p_stop2_lng is not null
             and coalesce(p_leg2_m, 0) > 0;
  if v_multi then
    v_stop2 := st_setsrid(st_makepoint(p_stop2_lng, p_stop2_lat), 4326)::geography;
  end if;

  v_zone_id := public.zone_for_point(v_pickup);
  if v_zone_id is null then
    raise exception 'نقطة الانطلاق خارج نطاق الخدمة';
  end if;

  v_fare := public.calculate_multi_fare(
    v_zone_id, p_distance_m, p_duration_s,
    case when v_multi then p_leg2_m else null end,
    case when v_multi then p_leg2_s else null end,
    coalesce(p_stopover, false), null, coalesce(p_vehicle_kind, 'bike')
  );

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    v_coupon := public.check_coupon(p_coupon_code, (v_fare ->> 'total')::numeric);
    v_cid    := (v_coupon ->> 'coupon_id')::uuid;
    v_disc   := (v_coupon ->> 'discount_iqd')::numeric;
  end if;

  v_final    := case when v_multi then v_stop2 else v_dropoff end;
  v_final_ad := case when v_multi then p_stop2_address else p_dropoff_address end;

  begin
    insert into public.trips (
      rider_id, pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note, coupon_id, discount_iqd,
      stop_count, current_leg, has_stopover, fare_locked_iqd, vehicle_kind
    ) values (
      auth.uid(), v_pickup, p_pickup_address,
      v_final, v_final_ad,
      p_distance_m + coalesce(case when v_multi then p_leg2_m end, 0),
      p_duration_s + coalesce(case when v_multi then p_leg2_s end, 0),
      (v_fare ->> 'total')::numeric,
      (v_fare ->> 'surge_multiplier')::numeric,
      v_fare,
      p_payment_method, p_note, v_cid, v_disc,
      case when v_multi then 2 else 1 end, 1,
      coalesce(p_stopover, false),
      (v_fare ->> 'total')::numeric,
      coalesce(p_vehicle_kind, 'bike')
    )
    returning * into v_trip;
  exception when unique_violation then
    raise exception 'لديك رحلة نشطة بالفعل' using errcode = 'unique_violation';
  end;

  insert into public.trip_stops
    (trip_id, seq, location, address, leg_distance_m, leg_duration_s, leg_fare_iqd)
  values
    (v_trip.id, 1, v_dropoff, p_dropoff_address,
     p_distance_m, p_duration_s, (v_fare ->> 'leg1_fare')::numeric);

  if v_multi then
    insert into public.trip_stops
      (trip_id, seq, location, address, leg_distance_m, leg_duration_s, leg_fare_iqd)
    values
      (v_trip.id, 2, v_stop2, p_stop2_address,
       p_leg2_m, p_leg2_s, (v_fare ->> 'leg2_fare')::numeric);
  end if;

  perform public.dispatch_next_offer(v_trip.id);

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) سائق التكتك يفتح طلبات الدراجات
-- -----------------------------------------------------------------------------
create or replace function public.set_accepts_bike_trips(p_value boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_kind public.vehicle_kind;
begin
  select vehicle_kind into v_kind from public.drivers where id = auth.uid();
  if not found then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  if v_kind <> 'tuktuk' then
    raise exception 'هذا الخيار لسائقي التكتك';
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.drivers set accepts_bike_trips = p_value where id = auth.uid();
  perform set_config('app.bypass_guards', 'off', true);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.find_nearby_drivers(
  geography, integer, integer, uuid[], public.vehicle_kind) from public, anon;
revoke all on function public.dispatch_next_offer(uuid) from public, anon;
revoke all on function public.set_accepts_bike_trips(boolean) from public, anon;

grant execute on function public.calculate_multi_fare(
  uuid, integer, integer, integer, integer, boolean, numeric,
  public.vehicle_kind) to authenticated;
grant execute on function public.estimate_multi_trip(
  double precision, double precision, integer, integer, integer, integer,
  boolean, public.vehicle_kind) to authenticated;
grant execute on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text,
  double precision, double precision, text, integer, integer, boolean,
  public.vehicle_kind) to authenticated;
grant execute on function public.set_accepts_bike_trips(boolean) to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  d.km || ' كم' as "المسافة",
  (public.calculate_multi_fare(z.id, (d.km*1000)::int, 0, null, null, false,
     null, 'bike') ->> 'total')::numeric   as "دراجة",
  (public.calculate_multi_fare(z.id, (d.km*1000)::int, 0, null, null, false,
     null, 'tuktuk') ->> 'total')::numeric as "تكتك"
from (values (3.0), (5.0), (8.0)) as d(km)
cross join (select id from public.pricing_zones where city_name = 'Nasiriyah') z
order by d.km;
