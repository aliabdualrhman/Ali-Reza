set search_path = public, extensions;

-- =============================================================================
-- 0028 — محطات متعددة، وتوقف في الطريق، وتغيير الوجهة أثناء الرحلة
-- =============================================================================
-- ثلاث ميزات تشترك في شيء واحد: **الرحلة لم تعد نقطتين.**
--
-- **قرار معماري يحكم الملف كله: لا حالات جديدة في `trip_status`.** كان
-- المغري إضافة `at_stop_1` و`at_stop_2`، لكن الحالة تدخل في المُشغّل
-- الحارس للانتقالات، وفي موجّهَي التطبيقين، وفي محرك المطابقة، وفي شاشة
-- التتبع، وفي كل استعلام يسأل "هل الرحلة نشطة؟". كل حالة جديدة تضرب في
-- خمسة مواضع.
--
-- البديل: **المحطات بيانات، والحالة تبقى خمساً.** جدول محطات مرتّب،
-- وعمود `current_leg` يقول أين نحن منها. الرحلة `in_progress` سواء كانت
-- في مرحلتها الأولى أو الثانية.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) ضوابط التسعير الجديدة
-- -----------------------------------------------------------------------------
alter table public.pricing_zones
  add column if not exists second_leg_discount_pct smallint not null default 10,
  add column if not exists stopover_surcharge_pct  smallint not null default 15,
  add column if not exists stopover_free_minutes   smallint not null default 10;

comment on column public.pricing_zones.second_leg_discount_pct is
  'خصم على المرحلة الثانية. تُسعَّر بالمسافة وحدها بلا أجرة بداية ولا حد '
  'أدنى، لأن السائق لم يأتِ من جديد ولم ينتظر راكباً آخر.';

comment on column public.pricing_zones.stopover_surcharge_pct is
  'زيادة التوقف في الطريق، تُحسب على مجموع الأجرة.';

comment on column public.pricing_zones.stopover_free_minutes is
  'كم دقيقة يشملها بدل التوقف. بلا حدٍّ يصير ١٥٪ ثمناً لانتظار نصف ساعة، '
  'والسائق سيرفض هذه الطلبات.';


-- -----------------------------------------------------------------------------
-- ٢) المحطات
-- -----------------------------------------------------------------------------
-- `seq = 1` هي الوجهة الأولى، و`seq = 2` الثانية. عمود `dropoff_location`
-- في `trips` يبقى **الوجهة الأخيرة**: عليه تعتمد شاشة التتبع وسجل الرحلات
-- والملاحة، وتغييره كان سيعيد كتابة نصف التطبيقين بلا مقابل.
create table if not exists public.trip_stops (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.trips(id) on delete cascade,
  seq         smallint not null check (seq >= 1),

  location    geography(Point, 4326) not null,
  address     text,

  -- مسافة وزمن **المرحلة المنتهية عند هذه المحطة**، لا من نقطة الانطلاق.
  leg_distance_m integer not null default 0,
  leg_duration_s integer not null default 0,
  leg_fare_iqd   numeric(10,2) not null default 0,

  arrived_at  timestamptz,

  unique (trip_id, seq)
);

create index if not exists trip_stops_trip_idx on public.trip_stops (trip_id, seq);

-- إحداثيات مسطّحة للقراءة من التطبيق: PostgREST يعيد عمود geography
-- بصيغة WKB سداسية عشرية لا يفهمها الهاتف. نفس نمط `trips` في 0014.
alter table public.trip_stops
  add column if not exists lat double precision
    generated always as (st_y(location::geometry)) stored,
  add column if not exists lng double precision
    generated always as (st_x(location::geometry)) stored;

alter table public.trip_stops enable row level security;

drop policy if exists "stops: طرفا الرحلة" on public.trip_stops;
create policy "stops: طرفا الرحلة"
  on public.trip_stops for select to authenticated
  using (public.is_trip_participant(trip_id) or public.is_admin());


alter table public.trips
  add column if not exists stop_count   smallint not null default 1,
  add column if not exists current_leg  smallint not null default 1,
  add column if not exists has_stopover boolean  not null default false,

  -- **الأجرة المجمَّدة.** حين تُحسب الأجرة من عناصر لا يستطيع
  -- `complete_trip` إعادة اشتقاقها — مراحل متعددة، أو تغيير وجهة في
  -- المنتصف — نخزّنها هنا ويحترمها الإنهاء بدل أن يعيد حسابها خطأً.
  add column if not exists fare_locked_iqd numeric(10,2);

comment on column public.trips.fare_locked_iqd is
  'أجرة نهائية محسوبة مسبقاً. حين تكون موجودة لا يعيد complete_trip الحساب.';


-- -----------------------------------------------------------------------------
-- ٣) حساب أجرة رحلة متعددة المراحل
-- -----------------------------------------------------------------------------
-- المرحلة الأولى تُسعَّر كرحلة كاملة (أجرة بداية + مسافة + حد أدنى).
-- والثانية **بالمسافة وحدها** ثم خصم، ثم تُضاف الزيادة إن كان هناك توقف.
create or replace function public.calculate_multi_fare(
  p_zone_id   uuid,
  p_leg1_m    integer,
  p_leg1_s    integer,
  p_leg2_m    integer default null,
  p_leg2_s    integer default null,
  p_stopover  boolean default false,
  p_surge     numeric default null
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

  -- التقريب لأقرب ٢٥٠ كما في الأجرة العادية: نقود العراق لا تعرف ما دونها.
  v_total := round(v_total / 250) * 250;
  v_comm  := round(v_total * z.commission_rate, 2);

  return jsonb_build_object(
    'leg1_fare',      round(v_leg1, 2),
    'leg2_fare',      round(v_leg2, 2),
    'stopover_add',   round(v_stop_add, 2),
    'stopover',       p_stopover,
    'stopover_free_minutes', z.stopover_free_minutes,
    'total',          v_total,
    'commission',     v_comm,
    'driver_earning', v_total - v_comm,
    'surge_multiplier', (v_first ->> 'surge_multiplier')::numeric
  );
end;
$fn$;


-- تقدير يستدعيه الراكب قبل الطلب — يعيد الأجرة وتفصيلها بلا إنشاء رحلة.
create or replace function public.estimate_multi_trip(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_leg1_m     integer,
  p_leg1_s     integer,
  p_leg2_m     integer default null,
  p_leg2_s     integer default null,
  p_stopover   boolean default false
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
    return jsonb_build_object(
      'available', false,
      'message', 'نقطة الانطلاق خارج نطاق الخدمة'
    );
  end if;

  return public.calculate_multi_fare(
    v_zone, p_leg1_m, p_leg1_s, p_leg2_m, p_leg2_s, p_stopover
  ) || jsonb_build_object('available', true);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) طلب الرحلة يقبل محطة ثانية وتوقفاً
-- -----------------------------------------------------------------------------
-- **نحذف كل نسخ الدالة لا نسخةً بعينها.** `create or replace` لا يستبدل
-- دالة إن اختلف عدد معاملاتها بل يُنشئ نسخة ثانية بجانبها، فتتراكم
-- النسخ ويصير كل نداء بالاسم المجرّد غامضاً — وهو ما فشل به هذا الملف
-- في أول تشغيل. الحلقة تمسح ما وُجد أياً كان توقيعه.
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
  -- المحطة الثانية، إن وُجدت. `p_leg2_m` مسافة المرحلة من الوجهة الأولى
  -- إليها لا من نقطة الانطلاق.
  p_stop2_lat       double precision default null,
  p_stop2_lng       double precision default null,
  p_stop2_address   text default null,
  p_leg2_m          integer default null,
  p_leg2_s          integer default null,
  p_stopover        boolean default false
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
    coalesce(p_stopover, false)
  );

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    v_coupon := public.check_coupon(p_coupon_code, (v_fare ->> 'total')::numeric);
    v_cid    := (v_coupon ->> 'coupon_id')::uuid;
    v_disc   := (v_coupon ->> 'discount_iqd')::numeric;
  end if;

  -- **`dropoff` يحمل الوجهة الأخيرة** لا الأولى: شاشة التتبع وسجل
  -- الرحلات والملاحة كلها تقرؤه، ووضع الوجهة الأولى فيه يجعل الراكب
  -- يرى رحلته منتهية عند منتصفها.
  v_final    := case when v_multi then v_stop2 else v_dropoff end;
  v_final_ad := case when v_multi then p_stop2_address else p_dropoff_address end;

  begin
    insert into public.trips (
      rider_id, pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note, coupon_id, discount_iqd,
      stop_count, current_leg, has_stopover, fare_locked_iqd
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
      (v_fare ->> 'total')::numeric
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
-- ٥) الوصول إلى محطة وسيطة
-- -----------------------------------------------------------------------------
-- **زر مستقل عن الإنهاء عمداً.** لو تركنا زر "إنهاء الرحلة" وحده لضغطه
-- السائق عند الوجهة الأولى بحكم العادة، فتُقفل الرحلة وتضيع المرحلة
-- الثانية وأجرتها.
create or replace function public.arrive_at_stop(p_trip_id uuid)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip public.trips;
  v_stop public.trip_stops;
  v_loc  geography;
  v_age  integer;
  v_dist integer;
  v_rad  integer;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك'
      using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status <> 'in_progress' then
    raise exception 'الرحلة لم تبدأ بعد';
  end if;

  if v_trip.current_leg >= v_trip.stop_count then
    raise exception 'هذه آخر محطة — استعمل زر الإنهاء';
  end if;

  select * into v_stop from public.trip_stops
  where trip_id = p_trip_id and seq = v_trip.current_leg;

  -- الحارس نفسه المستعمل في "وصلت إلى الراكب": ما يُفحص على الهاتف
  -- يُتجاوز بتطبيق معدَّل.
  select round(z.arrival_radius_m * 1.5)::integer into v_rad
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  select d.current_location,
         round(extract(epoch from (now() - d.location_updated_at)))::integer
  into v_loc, v_age
  from public.drivers d where d.id = auth.uid();

  if v_loc is null or v_age is null or v_age > 120 then
    raise exception 'تعذّر تحديد موقعك. تأكد أن خدمة الموقع تعمل';
  end if;

  v_dist := st_distance(v_loc, v_stop.location)::integer;
  if v_dist > coalesce(v_rad, 300) then
    raise exception 'أنت على بعد % متر من المحطة. اقترب إلى أقل من % متر',
      v_dist, coalesce(v_rad, 300);
  end if;

  update public.trip_stops set arrived_at = now()
  where trip_id = p_trip_id and seq = v_trip.current_leg;

  update public.trips set current_leg = current_leg + 1
  where id = p_trip_id
  returning * into v_trip;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) تغيير الوجهة أثناء الرحلة
-- -----------------------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from pg_type where typname = 'change_status') then
    create type public.change_status as enum ('pending', 'approved', 'rejected');
  end if;
end
$do$;

create table if not exists public.trip_change_requests (
  id           uuid primary key default gen_random_uuid(),
  trip_id      uuid not null references public.trips(id) on delete cascade,

  new_location geography(Point, 4326) not null,
  new_address  text,

  -- ما قطعه السائق فعلاً حتى لحظة الطلب، ومسار الوجهة الجديدة من هناك.
  travelled_m  integer not null,
  new_leg_m    integer not null,
  new_leg_s    integer not null,

  -- الأجرة المقترحة كاملةً بعد التغيير. الراكب يراها قبل أن يطلب،
  -- والسائق يراها قبل أن يوافق — لا مفاجآت عند التسليم.
  quoted_fare_iqd numeric(10,2) not null,

  status       public.change_status not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz
);

create index if not exists change_requests_trip_idx
  on public.trip_change_requests (trip_id, created_at desc);

create unique index if not exists change_requests_one_pending_idx
  on public.trip_change_requests (trip_id) where status = 'pending';

alter table public.trip_change_requests enable row level security;

drop policy if exists "changes: طرفا الرحلة" on public.trip_change_requests;
create policy "changes: طرفا الرحلة"
  on public.trip_change_requests for select to authenticated
  using (public.is_trip_participant(trip_id) or public.is_admin());


-- الراكب يطلب التغيير
create or replace function public.request_destination_change(
  p_trip_id     uuid,
  p_new_lat     double precision,
  p_new_lng     double precision,
  p_new_address text,
  p_travelled_m integer,
  p_new_leg_m   integer,
  p_new_leg_s   integer
)
returns public.trip_change_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip   public.trips;
  v_zone   uuid;
  v_earned jsonb;
  v_extra  numeric;
  v_quote  numeric;
  v_row    public.trip_change_requests;
  z        public.pricing_zones;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and rider_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك'
      using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status <> 'in_progress' then
    raise exception 'تغيير الوجهة متاح أثناء الرحلة فقط';
  end if;

  if exists (select 1 from public.trip_change_requests
             where trip_id = p_trip_id and status = 'pending') then
    raise exception 'لديك طلب تغيير بانتظار ردّ السائق';
  end if;

  v_zone := public.zone_for_point(v_trip.pickup_location);
  select * into z from public.pricing_zones where id = v_zone;

  -- **المستحق حتى نقطة التغيير يُسعَّر كرحلة كاملة**: أجرة بداية وحد
  -- أدنى. السائق أتى من مكانه وانتظر وحمل الراكب — كل ذلك حدث فعلاً
  -- ولا يُلغيه تغيير الوجهة.
  v_earned := public.calculate_fare(v_zone, greatest(p_travelled_m, 0), 0,
                                    v_trip.surge_multiplier);

  -- **والمسار الجديد بالمسافة وحدها**: لا أجرة بداية ثانية، فالسائق لم
  -- يبدأ رحلة جديدة بل واصل واحدة. وبلا خصم المرحلة الثانية أيضاً —
  -- ذلك الخصم مقابل التخطيط المسبق، والتغيير المفاجئ عكسه.
  v_extra := (greatest(p_new_leg_m, 0) / 1000.0) * z.per_km_iqd;

  v_quote := (v_earned ->> 'total')::numeric + v_extra;
  if v_trip.has_stopover then
    v_quote := v_quote * (1 + z.stopover_surcharge_pct / 100.0);
  end if;
  v_quote := round(v_quote / 250) * 250;

  insert into public.trip_change_requests (
    trip_id, new_location, new_address,
    travelled_m, new_leg_m, new_leg_s, quoted_fare_iqd
  ) values (
    p_trip_id,
    st_setsrid(st_makepoint(p_new_lng, p_new_lat), 4326)::geography,
    p_new_address,
    greatest(p_travelled_m, 0), greatest(p_new_leg_m, 0),
    greatest(p_new_leg_s, 0), v_quote
  )
  returning * into v_row;

  return v_row;
end;
$fn$;


-- السائق يردّ
create or replace function public.respond_destination_change(
  p_id     uuid,
  p_accept boolean
)
returns public.trip_change_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row  public.trip_change_requests;
  v_trip public.trips;
begin
  select * into v_row from public.trip_change_requests
  where id = p_id and status = 'pending'
  for update;

  if not found then
    raise exception 'الطلب غير موجود أو رُدّ عليه';
  end if;

  select * into v_trip from public.trips
  where id = v_row.trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'هذه الرحلة ليست لك' using errcode = 'insufficient_privilege';
  end if;

  if not p_accept then
    update public.trip_change_requests
    set status = 'rejected', responded_at = now()
    where id = p_id
    returning * into v_row;
    -- **الرحلة تمضي كما هي.** لا رسوم ولا إلغاء: الراكب طلب واعتذر
    -- السائق، وهذا ليس خطأً من أحد.
    return v_row;
  end if;

  update public.trip_change_requests
  set status = 'approved', responded_at = now()
  where id = p_id
  returning * into v_row;

  -- الوجهة الجديدة تحلّ محل القديمة، والأجرة تُجمَّد على ما وافق عليه
  -- الطرفان. `arrive_at_stop` لا يعود له معنى بعدها — المحطة واحدة.
  update public.trips
  set dropoff_location     = v_row.new_location,
      dropoff_address      = v_row.new_address,
      estimated_distance_m = v_row.travelled_m + v_row.new_leg_m,
      fare_estimated_iqd   = v_row.quoted_fare_iqd,
      fare_locked_iqd      = v_row.quoted_fare_iqd,
      stop_count           = 1,
      current_leg          = 1
  where id = v_row.trip_id;

  -- المحطات القديمة لم تعد تصف الرحلة. نحذف ما لم يُوصَل إليه ونُبقي
  -- ما وصله السائق فعلاً — سجلٌّ صادق لما جرى.
  delete from public.trip_stops
  where trip_id = v_row.trip_id and arrived_at is null;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الإنهاء يحترم الأجرة المجمَّدة
-- -----------------------------------------------------------------------------
create or replace function public.complete_trip(
  p_trip_id          uuid,
  p_actual_distance_m integer default null,
  p_actual_duration_s integer default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip  public.trips;
  v_zone  uuid;
  v_fare  jsonb;
  v_dist  integer;
  v_dur   integer;
  v_disc  numeric(10,2);
  v_total numeric(10,2);
  v_comm  numeric(10,2);
  v_rate  numeric;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك' using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status <> 'in_progress' then
    raise exception 'لا يمكن إنهاء رحلة حالتها %', v_trip.status;
  end if;

  -- **لا إنهاء قبل بلوغ المحطة الأخيرة.** بلا هذا يُقفل السائق رحلةً
  -- متعددة المحطات عند أولاها فتضيع مرحلة كاملة وأجرتها.
  if v_trip.current_leg < v_trip.stop_count then
    raise exception 'بقيت محطة أخرى. اضغط "وصلت إلى المحطة" أولاً';
  end if;

  v_dist := coalesce(p_actual_distance_m, v_trip.estimated_distance_m);
  v_dur  := coalesce(
    p_actual_duration_s,
    extract(epoch from (now() - v_trip.started_at))::integer,
    v_trip.estimated_duration_s
  );

  v_zone := public.zone_for_point(v_trip.pickup_location);
  v_fare := public.calculate_fare(v_zone, v_dist, v_dur, v_trip.surge_multiplier);

  -- **الأجرة المجمَّدة تسبق إعادة الحساب.** رحلة بمرحلتين أو غُيّرت
  -- وجهتها لا يستطيع هذا السطر اشتقاق سعرها من المسافة الكلية: خصمُ
  -- المرحلة الثانية وزيادةُ التوقف والمستحقُّ قبل التغيير كلها عناصر
  -- حُسبت مرة ووافق عليها الطرفان.
  if v_trip.fare_locked_iqd is not null then
    select commission_rate into v_rate
    from public.pricing_zones where id = v_zone;

    v_total := v_trip.fare_locked_iqd;
    v_comm  := round(v_total * coalesce(v_rate, 0.15), 2);
  else
    v_total := (v_fare ->> 'total')::numeric;
    v_comm  := (v_fare ->> 'commission')::numeric;
  end if;

  v_disc := least(coalesce(v_trip.discount_iqd, 0), v_total);

  update public.trips
  set status             = 'completed',
      actual_distance_m  = v_dist,
      actual_duration_s  = v_dur,
      fare_final_iqd     = v_total,
      commission_iqd     = v_comm,
      driver_earning_iqd = v_total - v_comm,
      discount_iqd       = v_disc,
      fare_breakdown     = coalesce(v_trip.fare_breakdown, v_fare),
      payment_status     = case when v_trip.payment_method = 'cash'
                                then 'paid'::public.payment_status
                                else 'pending'::public.payment_status end
  where id = p_trip_id
  returning * into v_trip;

  perform set_config('app.bypass_guards', 'on', true);

  update public.drivers
  set status          = 'online',
      trips_completed = trips_completed + 1
  where id = v_trip.driver_id;

  perform set_config('app.bypass_guards', 'off', true);

  perform public.post_wallet_transaction(
    p_driver_id   => v_trip.driver_id,
    p_txn_type    => 'commission',
    p_amount_iqd  => -v_trip.commission_iqd,
    p_trip_id     => v_trip.id,
    p_description => format('عمولة الرحلة رقم %s', v_trip.trip_number)
  );

  if v_disc > 0 then
    perform public.post_wallet_transaction(
      p_driver_id   => v_trip.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_disc,
      p_trip_id     => v_trip.id,
      p_description => format('تعويض خصم كوبون — رحلة %s', v_trip.trip_number)
    );

    insert into public.coupon_redemptions
      (coupon_id, rider_id, trip_id, discount_iqd)
    values (v_trip.coupon_id, v_trip.rider_id, v_trip.id, v_disc)
    on conflict (trip_id) do nothing;
  end if;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٨) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.calculate_multi_fare(
  uuid, integer, integer, integer, integer, boolean, numeric) from public, anon;
revoke all on function public.estimate_multi_trip(double precision, double precision, integer, integer, integer, integer, boolean)
  from public, anon;
revoke all on function public.arrive_at_stop(uuid) from public, anon;
revoke all on function public.request_destination_change(uuid, double precision, double precision, text, integer, integer, integer)
  from public, anon;
revoke all on function public.respond_destination_change(uuid, boolean)
  from public, anon;
revoke all on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text,
  double precision, double precision, text, integer, integer, boolean
) from public, anon;
revoke all on function public.complete_trip(uuid, integer, integer)
  from public, anon;

grant execute on function public.calculate_multi_fare(
  uuid, integer, integer, integer, integer, boolean, numeric) to authenticated;
grant execute on function public.estimate_multi_trip(
  double precision, double precision, integer, integer, integer, integer, boolean)
  to authenticated;
grant execute on function public.arrive_at_stop(uuid) to authenticated;
grant execute on function public.request_destination_change(
  uuid, double precision, double precision, text, integer, integer, integer)
  to authenticated;
grant execute on function public.respond_destination_change(uuid, boolean)
  to authenticated;
grant execute on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text,
  double precision, double precision, text, integer, integer, boolean
) to authenticated;
grant execute on function public.complete_trip(uuid, integer, integer)
  to authenticated;

-- البثّ اللحظي لطلبات التغيير: السائق يجب أن يراها فور إرسالها
do $do$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'trip_change_requests'
  ) then
    alter publication supabase_realtime add table public.trip_change_requests;
  end if;
end
$do$;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar             as "المنطقة",
  second_leg_discount_pct  as "خصم المرحلة ٢",
  stopover_surcharge_pct   as "زيادة التوقف",
  stopover_free_minutes    as "دقائق التوقف"
from public.pricing_zones
order by city_name_ar
limit 3;
