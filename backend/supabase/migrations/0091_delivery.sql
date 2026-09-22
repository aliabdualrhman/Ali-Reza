-- =============================================================================
-- 0091 — طلب المندوب: المتاجر، والطلب، والاتفاق، والمستحقات، ولوحة المدير
-- =============================================================================
-- **يتطلّب 0090 مطبَّقاً قبله** (قيمة `delivery` في نوع الطلب).
--
-- المواصفات المتفق عليها في docs/features/delivery.md — ما يخالفها هنا خطأ.
--
-- ------------------------------------------------------------------
-- لماذا نوعٌ ثالث في `trips` لا جدولٌ مستقل؟
-- ------------------------------------------------------------------
-- للسبب نفسه الذي كُتب في رأس 0077 للتسوّق: **المتجر نقطة الانطلاق**،
-- فنرث المطابقة والعروض ومهلها والإلغاء وعقوباته والعمولة والمحفظة
-- وشاشات المدير كلها. والجديد هنا ثلاثة أشياء لا غير:
--
--   ١) التاجر يحدّد سعر التوصيل بنفسه ← `fare_locked_iqd`، فتحسب
--      `complete_trip` العمولة عليه كما هي بلا تعديل.
--   ٢) اتفاق طريقة الدفع عند المتجر، والقاعدة تفرضه لا الواجهة.
--   ٣) مستحقات «يُعاد الثمن بعد التسليم»: المندوب يعلن، والتاجر يؤكّد.
--
-- ------------------------------------------------------------------
-- المستلم بلا دبوس
-- ------------------------------------------------------------------
-- `dropoff_location` إلزاميّ، ومعظم الشفرة تفترض وجوده. فحين لا يضع
-- التاجر دبوساً نحفظ نقطة المتجر مكانه مع `dropoff_pinned = false`،
-- والتطبيقان لا يرسمانها ولا يقيسان إليها. أسلم من جعل العمود اختيارياً
-- وتعقّب كل من يقرؤه.
-- =============================================================================

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) المتاجر
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'store_status') then
    create type public.store_status as enum
      ('pending', 'approved', 'rejected', 'suspended');
  end if;
end $$;

create table if not exists public.stores (
  id               uuid primary key default gen_random_uuid(),

  -- **متجرٌ واحد لكل حساب.** التاجر بمتجرين نادرٌ في مدينتنا، وتعدّد
  -- المتاجر يعني سؤالاً في كل طلب «من أيّ متجر؟» يدفع ثمنه الجميع.
  owner_id         uuid not null unique
                   references public.profiles(id) on delete cascade,

  name             text not null,
  phone            text not null,
  address          text not null,
  location         geography(Point, 4326) not null,

  -- للقراءة من التطبيق، كما في 0014 للرحلات.
  lat double precision generated always as (st_y(location::geometry)) stored,
  lng double precision generated always as (st_x(location::geometry)) stored,

  status           public.store_status not null default 'pending',
  rejection_reason text,
  reviewed_by      uuid references public.profiles(id) on delete set null,
  reviewed_at      timestamptz,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.stores is
  'متجر التاجر — شرطُ طلب المندوب، ويعتمده المدير. واحدٌ لكل حساب.';

alter table public.stores enable row level security;

-- **القراءة لصاحبه وللمدير، والكتابة عبر الدوال وحدها.** كتابةٌ مباشرة
-- تعني أن يعتمد التاجر متجره بنفسه بتعديل عمود `status`.
drop policy if exists stores_owner_read on public.stores;
create policy stores_owner_read on public.stores
  for select to authenticated
  using (owner_id = auth.uid() or public.is_admin());

drop trigger if exists stores_touch_updated_at on public.stores;
create trigger stores_touch_updated_at
  before update on public.stores
  for each row execute function public.touch_updated_at();


-- -----------------------------------------------------------------------------
-- ٢) أعمدة الطلب
-- -----------------------------------------------------------------------------
alter table public.trips
  add column if not exists store_id uuid
    references public.stores(id) on delete set null,

  -- **رقم المتجر محفوظاً على الطلب لا مقروءاً من المتجر.** التاجر قد
  -- يغيّر رقمه غداً، والمندوب الذي يراجع طلب الأمس يحتاج الرقم الذي
  -- اتصل به فعلاً.
  add column if not exists store_phone        text,
  add column if not exists recipient_phone    text,
  add column if not exists recipient_landmark text,
  add column if not exists dropoff_pinned     boolean not null default true,

  -- اتفاق الدفع: كلٌّ يختار، ويُثبَّت حين يتطابقان.
  --   prepay = المندوب يدفع الثمن للتاجر الآن ويأخذه من المستلم
  --   after  = المندوب يأخذ الثمن من المستلم ويعيده للتاجر بعد التسليم
  add column if not exists pay_choice_merchant text
    check (pay_choice_merchant in ('prepay', 'after')),
  add column if not exists pay_choice_driver text
    check (pay_choice_driver in ('prepay', 'after')),
  add column if not exists pay_mode text
    check (pay_mode in ('prepay', 'after')),
  add column if not exists pay_agreed_at timestamptz,

  add column if not exists delivery_failed_at   timestamptz,
  add column if not exists delivery_fail_reason text,
  add column if not exists delivery_outcome     text
    check (delivery_outcome in ('delivered', 'returned')),

  -- مستحقات «after»: open ← claimed (المندوب يقول أعدتُ) ← closed أو disputed
  add column if not exists settle_status text
    check (settle_status in ('open', 'claimed', 'closed', 'disputed')),
  add column if not exists settle_claimed_at timestamptz,
  add column if not exists settle_closed_at  timestamptz;

create index if not exists trips_store_idx
  on public.trips (store_id, requested_at desc)
  where store_id is not null;

create index if not exists trips_settle_idx
  on public.trips (settle_status)
  where settle_status is not null;


-- -----------------------------------------------------------------------------
-- ٣) مفتاحا السائق
-- -----------------------------------------------------------------------------
alter table public.drivers
  add column if not exists accepts_delivery boolean not null default false,

  -- **لسائق التكتك وحده، ومستقلٌّ عن `accepts_bike_trips`.** من يقبل
  -- ركّاب الدراجة قد لا يريد طرودها، والعكس.
  add column if not exists accepts_bike_deliveries boolean not null default false;

comment on column public.drivers.accepts_delivery is
  'يستقبل طلبات المندوب. مغلقٌ افتراضاً — قد يتطلّب دفع ثمن السلعة مقدّماً.';
comment on column public.drivers.accepts_bike_deliveries is
  'سائق تكتك يستقبل طلبات التوصيل بالدراجة أيضاً، بسعرها.';


-- -----------------------------------------------------------------------------
-- ٤) الإعدادات والصلاحيات — كلها في لوحة المدير
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('delivery_enabled',            '1',     'تفعيل طلب المندوب'),
  ('delivery_closed_msg',         'خدمة طلب المندوب متوقّفة مؤقّتاً.',
                                           'رسالة إيقاف طلب المندوب'),
  ('delivery_min_fee_bike_iqd',   '1000',  'طلب المندوب — أقل سعر توصيل بالدراجة'),
  ('delivery_min_fee_tuktuk_iqd', '3000',  'طلب المندوب — أقل سعر توصيل بالتكتك'),
  ('delivery_max_goods_iqd',      '50000', 'طلب المندوب — أقصى ثمن سلعة'),
  ('delivery_max_active',         '10',    'طلب المندوب — أقصى عدد طلبات نشطة للمتجر')
on conflict (key) do nothing;

insert into public.permission_catalog (code, label, sort_order) values
  ('stores.review',     'مراجعة المتاجر واعتمادها وإيقافها',   150),
  ('deliveries.settle', 'إغلاق مستحقات المتاجر والنزاعات',     160)
on conflict (code) do nothing;


-- -----------------------------------------------------------------------------
-- ٥) التاجر يطلب أكثر من مندوب في آن
-- -----------------------------------------------------------------------------
-- **القاعدة الواحدة تبقى للرحلة والتسوّق.** راكبٌ برحلتين نشطتين خطأٌ
-- دائماً؛ وتاجرٌ بطردين إلى زبونين يومٌ عاديّ. وسقف التوصيل في
-- `request_delivery` لا في فهرس.
drop index if exists public.trips_one_active_per_rider;
create unique index trips_one_active_per_rider
  on public.trips (rider_id)
  where status in ('searching', 'accepted', 'driver_arrived', 'in_progress')
    and kind <> 'delivery';


-- -----------------------------------------------------------------------------
-- ٦) فحص المسافة لا يشمل التوصيل
-- -----------------------------------------------------------------------------
-- بلا دبوس، الوجهة المحفوظة هي المتجر نفسه — مسافة صفر. ومع الدبوس قد
-- يكون الزبون في المحل المجاور فعلاً.
create or replace function public.validate_trip_distance()
returns trigger
language plpgsql
as $$
begin
  if new.kind = 'delivery' then
    return new;
  end if;

  if st_distance(new.pickup_location, new.dropoff_location) < 100 then
    raise exception 'المسافة بين نقطة الانطلاق والوجهة قصيرة جداً (أقل من ١٠٠ متر)'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;


-- -----------------------------------------------------------------------------
-- ٧) حالة الخدمات — الثالثة
-- -----------------------------------------------------------------------------
create or replace function public.service_status()
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select jsonb_build_object(
    'rides',        public.referral_setting('rides_enabled', 1) <> 0,
    'shopping',     public.referral_setting('shopping_enabled', 1) <> 0,
    'delivery',     public.referral_setting('delivery_enabled', 1) <> 0,
    'rides_msg',    coalesce(
      (select nullif(btrim(value), '') from public.public_settings
       where key = 'rides_closed_msg'),
      'خدمة نقل الركّاب متوقّفة مؤقّتاً.'),
    'shopping_msg', coalesce(
      (select nullif(btrim(value), '') from public.public_settings
       where key = 'shopping_closed_msg'),
      'خدمة التسوّق قريباً.'),
    'delivery_msg', coalesce(
      (select nullif(btrim(value), '') from public.public_settings
       where key = 'delivery_closed_msg'),
      'خدمة طلب المندوب متوقّفة مؤقّتاً.')
  );
$fn$;

create or replace function public.guard_service_open()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_key text;
  v_msg_key text;
  v_default text;
  v_msg text;
begin
  case new.kind
    when 'shopping' then
      v_key := 'shopping_enabled'; v_msg_key := 'shopping_closed_msg';
      v_default := 'خدمة التسوّق متوقّفة حالياً.';
    when 'delivery' then
      v_key := 'delivery_enabled'; v_msg_key := 'delivery_closed_msg';
      v_default := 'خدمة طلب المندوب متوقّفة حالياً.';
    else
      v_key := 'rides_enabled'; v_msg_key := 'rides_closed_msg';
      v_default := 'خدمة نقل الركّاب متوقّفة حالياً.';
  end case;

  if public.referral_setting(v_key, 1) = 0 then
    select nullif(btrim(value), '') into v_msg
    from public.public_settings where key = v_msg_key;
    raise exception '%', coalesce(v_msg, v_default);
  end if;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٨) السائق يفتح التوصيل ويغلقه
-- -----------------------------------------------------------------------------
create or replace function public.set_accepts_delivery(p_value boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not exists (select 1 from public.drivers where id = auth.uid()) then
    raise exception 'لست سائقاً';
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.drivers
  set accepts_delivery = coalesce(p_value, false)
  where id = auth.uid();
  perform set_config('app.bypass_guards', 'off', true);
end;
$fn$;

create or replace function public.set_accepts_bike_deliveries(p_value boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not exists (select 1 from public.drivers
                 where id = auth.uid() and vehicle_kind = 'tuktuk') then
    raise exception 'هذا الخيار لسائقي التكتك';
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.drivers
  set accepts_bike_deliveries = coalesce(p_value, false)
  where id = auth.uid();
  perform set_config('app.bypass_guards', 'off', true);
end;
$fn$;

revoke all on function public.set_accepts_delivery(boolean) from public, anon;
grant execute on function public.set_accepts_delivery(boolean) to authenticated;
revoke all on function public.set_accepts_bike_deliveries(boolean) from public, anon;
grant execute on function public.set_accepts_bike_deliveries(boolean) to authenticated;


-- -----------------------------------------------------------------------------
-- ٩) «متجري» — التسجيل والتعديل
-- -----------------------------------------------------------------------------
-- **التعديل بعد الاعتماد لا يُسقطه.** تاجرٌ غيّر رقمه ظهراً لا يجب أن
-- يتوقف عمله حتى يراجعه المدير مساءً. والمرفوض حين يعدّل يعود إلى
-- المراجعة — تعديله هو ردّه على سبب الرفض.
create or replace function public.save_my_store(
  p_name    text,
  p_phone   text,
  p_address text,
  p_lat     double precision,
  p_lng     double precision
)
returns public.stores
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_name  text := btrim(coalesce(p_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_addr  text := btrim(coalesce(p_address, ''));
  v_loc   geography;
  v_row   public.stores;
  v_new   boolean;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  if exists (select 1 from public.profiles where id = v_uid and is_blocked) then
    raise exception 'حسابك موقوف' using errcode = 'insufficient_privilege';
  end if;

  if length(v_name) < 2 or length(v_name) > 60 then
    raise exception 'اسم المتجر من حرفين إلى ٦٠ حرفاً';
  end if;
  if v_phone !~ '^\+?[0-9 ]{7,20}$' then
    raise exception 'رقم هاتف المتجر غير صحيح';
  end if;
  if length(v_addr) < 3 then
    raise exception 'اكتب عنوان المتجر';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'حدّد موقع المتجر على الخريطة';
  end if;

  v_loc := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  if public.zone_for_point(v_loc) is null then
    raise exception 'موقع المتجر خارج نطاق الخدمة';
  end if;

  select * into v_row from public.stores where owner_id = v_uid for update;
  v_new := not found;

  if v_new then
    insert into public.stores (owner_id, name, phone, address, location)
    values (v_uid, v_name, v_phone, v_addr, v_loc)
    returning * into v_row;
  else
    update public.stores
    set name     = v_name,
        phone    = v_phone,
        address  = v_addr,
        location = v_loc,
        status   = case when status = 'rejected'
                        then 'pending'::public.store_status else status end,
        rejection_reason = case when status = 'rejected'
                                then null else rejection_reason end
    where id = v_row.id
    returning * into v_row;
  end if;

  return v_row;
end;
$fn$;

revoke all on function public.save_my_store(text, text, text, double precision, double precision)
  from public, anon;
grant execute on function public.save_my_store(text, text, text, double precision, double precision)
  to authenticated;


-- -----------------------------------------------------------------------------
-- ١٠) الطلب
-- -----------------------------------------------------------------------------
create or replace function public.request_delivery(
  p_recipient_phone   text,
  p_recipient_address text,
  p_landmark          text,
  p_goods_price       numeric,
  p_fee               numeric,
  p_vehicle           text default 'bike',
  p_drop_lat          double precision default null,
  p_drop_lng          double precision default null,
  p_distance_m        integer default null,
  p_duration_s        integer default null,
  p_note              text default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid     uuid := auth.uid();
  v_store   public.stores;
  v_kind    public.vehicle_kind;
  v_min     numeric;
  v_max     numeric;
  v_limit   integer;
  v_active  integer;
  v_drop    geography;
  v_pinned  boolean;
  v_phone   text := btrim(coalesce(p_recipient_phone, ''));
  v_addr    text := btrim(coalesce(p_recipient_address, ''));
  v_trip    public.trips;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  if exists (select 1 from public.profiles where id = v_uid and is_blocked) then
    raise exception 'غير مصرّح لك بطلب مندوب'
      using errcode = 'insufficient_privilege';
  end if;

  -- ---- المتجر أولاً: موجود ومعتمد ----
  select * into v_store from public.stores where owner_id = v_uid;
  if not found then
    raise exception 'سجّل متجرك أولاً من «متجري»';
  end if;
  case v_store.status
    when 'pending' then
      raise exception 'متجرك بانتظار موافقة الإدارة';
    when 'rejected' then
      raise exception 'رُفض تسجيل متجرك: %',
        coalesce(v_store.rejection_reason, 'راجع الدعم');
    when 'suspended' then
      raise exception 'متجرك موقوف مؤقتاً. تواصل مع الدعم';
    else null;
  end case;

  -- ---- المستلم ----
  if v_phone !~ '^\+?[0-9 ]{7,20}$' then
    raise exception 'رقم المستلم غير صحيح';
  end if;
  if length(v_addr) < 3 then
    raise exception 'اكتب عنوان المستلم';
  end if;

  -- ---- المركبة ----
  v_kind := case lower(coalesce(p_vehicle, 'bike'))
    when 'bike'   then 'bike'::public.vehicle_kind
    when 'tuktuk' then 'tuktuk'::public.vehicle_kind
  end;
  if v_kind is null then raise exception 'نوع مركبة غير معروف'; end if;

  -- ---- الأسعار ----
  -- ثمن السلعة صفرٌ مسموح: طردٌ دُفع ثمنه سلفاً يوصَل بأجرته وحدها.
  if p_goods_price is null or p_goods_price < 0 then
    raise exception 'اكتب ثمن السلعة';
  end if;
  v_max := public.referral_setting('delivery_max_goods_iqd', 50000);
  if p_goods_price > v_max then
    raise exception 'أقصى ثمن سلعة % دينار', v_max::bigint;
  end if;

  -- **الحدّ الأدنى يحمي السائق.** التاجر يكتب السعر، وبلا حدٍّ يكتب
  -- بعضهم مئتين وخمسين — فيتجاهل السائقون الطلب ويظنّ التاجر أن
  -- التطبيق بلا مناديب.
  v_min := case v_kind
    when 'tuktuk' then public.referral_setting('delivery_min_fee_tuktuk_iqd', 3000)
    else public.referral_setting('delivery_min_fee_bike_iqd', 1000)
  end;
  if p_fee is null or p_fee < v_min then
    raise exception 'أقل سعر توصيل % دينار%', v_min::bigint,
      case when v_kind = 'tuktuk' then ' بالتكتك' else '' end;
  end if;
  if p_fee > 100000 then
    raise exception 'سعر التوصيل كبير جداً — راجع الرقم';
  end if;

  -- ---- السقف ----
  v_limit := public.referral_setting('delivery_max_active', 10)::integer;
  select count(*) into v_active
  from public.trips
  where rider_id = v_uid and kind = 'delivery'
    and status in ('searching', 'accepted', 'driver_arrived', 'in_progress');
  if v_active >= v_limit then
    raise exception 'لديك % طلبات نشطة — الحد الأقصى', v_active;
  end if;

  if public.zone_for_point(v_store.location) is null then
    raise exception 'متجرك خارج نطاق الخدمة';
  end if;

  -- ---- الوجهة ----
  if p_drop_lat is not null and p_drop_lng is not null then
    v_drop   := st_setsrid(st_makepoint(p_drop_lng, p_drop_lat), 4326)::geography;
    v_pinned := true;
  else
    v_drop   := v_store.location;   -- انظر رأس الملف
    v_pinned := false;
  end if;

  insert into public.trips (
    rider_id, kind,
    pickup_location, pickup_address,
    dropoff_location, dropoff_address,
    estimated_distance_m, estimated_duration_s,
    fare_estimated_iqd, fare_locked_iqd, surge_multiplier, fare_breakdown,
    payment_method, rider_note,
    goods_estimate_iqd, goods_actual_iqd,
    stop_count, current_leg, vehicle_kind,
    shop_name, store_id, store_phone,
    recipient_phone, recipient_landmark, dropoff_pinned
  ) values (
    v_uid, 'delivery',
    v_store.location, v_store.address,
    v_drop, v_addr,
    case when v_pinned then p_distance_m end,
    case when v_pinned then p_duration_s end,
    p_fee, p_fee, 1.0,
    jsonb_build_object('total', p_fee, 'set_by', 'merchant'),
    'cash', nullif(btrim(coalesce(p_note, '')), ''),
    -- **الثمن معروفٌ لا مقدَّر.** التاجر يبيعه بنفسه، فالعمودان واحد.
    p_goods_price, p_goods_price,
    1, 1, v_kind,
    v_store.name, v_store.id, v_store.phone,
    v_phone, nullif(btrim(coalesce(p_landmark, '')), ''), v_pinned
  )
  returning * into v_trip;

  insert into public.trip_stops
    (trip_id, seq, location, address, leg_distance_m, leg_duration_s,
     leg_fare_iqd)
  values (v_trip.id, 1, v_drop, v_addr,
          coalesce(v_trip.estimated_distance_m, 0),
          coalesce(v_trip.estimated_duration_s, 0), p_fee);

  perform public.dispatch_next_offer(v_trip.id);

  return v_trip;
end;
$fn$;

revoke all on function public.request_delivery(
  text, text, text, numeric, numeric, text,
  double precision, double precision, integer, integer, text) from public, anon;
grant execute on function public.request_delivery(
  text, text, text, numeric, numeric, text,
  double precision, double precision, integer, integer, text) to authenticated;


-- -----------------------------------------------------------------------------
-- ١١) العرض يذهب لمن يقبل التوصيل
-- -----------------------------------------------------------------------------
-- منسوخةٌ من 0080 كما هي، والمضاف فرع `v_delivery` وحده.
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
  v_shopping  boolean;
  v_kind      public.vehicle_kind;
  v_delivery  boolean;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;
  end if;

  -- ---- الإضافة الوحيدة على منطق 0033 ----
  -- **طلب التسوّق لا يُرشَّح بالمركبة.** دراجةً كان السائق أو تكتكاً،
  -- ما دام فتح مفتاح التسوّق — والسعر سعر الدراجة في الحالين.
  v_shopping := (v_trip.kind = 'shopping');
  v_delivery := (v_trip.kind = 'delivery');

  -- **التوصيل: التكتك يُطلب بعينه، والدراجة تصل للجميع ممن يقبلها.**
  -- طلبٌ بتكتك يُحصر في سائقي التكتك (شحنة كبيرة). وطلبٌ بدراجة يصل
  -- لسائقي الدراجة ولسائقي التكتك الذين فعّلوا «طلبات الدراجة» في قسم
  -- التوصيل — وهو خيارٌ مستقلّ عن خيار الرحلات، فنبحث بلا نوعٍ ونرشّح
  -- في الحلقة أدناه.
  v_kind := case
    when v_shopping then null
    when v_delivery then
      case when v_trip.vehicle_kind = 'tuktuk'
           then 'tuktuk'::public.vehicle_kind end
    else v_trip.vehicle_kind
  end;

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
    -- **الترشيح بالوصل لا داخل الدالة.** تغيير بصمة
    -- `find_nearby_drivers` يكسر كل من يستدعيها.
    select c.*
    from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried, v_kind
    ) c
    join public.drivers d on d.id = c.driver_id
    where case
      when v_shopping then d.accepts_shopping
      when v_delivery then d.accepts_delivery
        and (v_trip.vehicle_kind = 'tuktuk'
             or d.vehicle_kind = 'bike'
             or d.accepts_bike_deliveries)
      else d.accepts_rides
    end
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
-- ١٢) اتفاق طريقة الدفع — عند المتجر
-- -----------------------------------------------------------------------------
-- **كلٌّ يختار، ولا يُثبَّت الاتفاق إلا حين يتطابق الاختياران.** زرٌّ
-- واحد يضغطه أحدهما عن الآخر هو ما ينتهي بخلافٍ على المال عند الباب:
-- «قلتَ إنك ستدفع» — «لم أقل».
create or replace function public.choose_delivery_payment(
  p_trip_id uuid,
  p_mode    text
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_trip public.trips;
begin
  if p_mode not in ('prepay', 'after') then
    raise exception 'خيار دفع غير معروف';
  end if;

  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.kind <> 'delivery' then
    raise exception 'الطلب غير موجود';
  end if;
  if v_trip.status <> 'driver_arrived' then
    raise exception 'الاتفاق على الدفع يكون بعد وصول المندوب إلى المتجر وقبل استلام الطلب';
  end if;

  if v_uid = v_trip.rider_id then
    update public.trips set pay_choice_merchant = p_mode where id = p_trip_id;
  elsif v_uid = v_trip.driver_id then
    update public.trips set pay_choice_driver = p_mode where id = p_trip_id;
  else
    raise exception 'هذا ليس طلبك' using errcode = 'insufficient_privilege';
  end if;

  update public.trips
  set pay_mode = case when pay_choice_merchant = pay_choice_driver
                      then pay_choice_merchant end,
      pay_agreed_at = case when pay_choice_merchant = pay_choice_driver
                           then now() end
  where id = p_trip_id
  returning * into v_trip;

  return v_trip;
end;
$fn$;

revoke all on function public.choose_delivery_payment(uuid, text) from public, anon;
grant execute on function public.choose_delivery_payment(uuid, text) to authenticated;


-- -----------------------------------------------------------------------------
-- ١٣) حارس الانتقالات — القاعدة تفرض ما قد تنساه الواجهة
-- -----------------------------------------------------------------------------
create or replace function public.guard_delivery_transition()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if old.kind <> 'delivery' or new.status = old.status then
    return new;
  end if;

  -- **لا يبدأ التوصيل بلا اتفاق.** النسخة القديمة من التطبيق، أو ضغطةٌ
  -- قبل أن تصل حالة الاتفاق إلى الشاشة، لا تتجاوز هذا.
  if new.status = 'in_progress' and new.pay_mode is null then
    raise exception 'اتفقا على طريقة الدفع أولاً — يختار كلٌّ منكما الخيار نفسه';
  end if;

  if new.status = 'cancelled' then
    if public.is_admin() then
      perform public.log_action(
        'delivery.admin_cancel', 'trips', new.id::text,
        format('ألغى المدير طلب مندوب في حالة %s', old.status));
      return new;
    end if;

    -- **بعد الاستلام لا إلغاء.** الطرد في يد المندوب؛ الإلغاء حينها
    -- يترك مال التاجر وبضاعته في الشارع. يبقى «تعذّر التسليم».
    if old.status = 'in_progress'
       and coalesce(current_setting('app.bypass_guards', true), 'off') <> 'on'
    then
      raise exception
        'استُلم الطلب — لا يمكن الإلغاء الآن. إن تعذّر التسليم فأعد الطرد إلى المتجر';
    end if;
  end if;

  return new;
end;
$fn$;

drop trigger if exists trips_guard_delivery on public.trips;
create trigger trips_guard_delivery
  before update of status on public.trips
  for each row execute function public.guard_delivery_transition();


-- -----------------------------------------------------------------------------
-- ١٤) تعذّر التسليم
-- -----------------------------------------------------------------------------
create or replace function public.report_delivery_failed(
  p_trip_id uuid,
  p_reason  text
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip   public.trips;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_name   text;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;
  if not found or v_trip.kind <> 'delivery' then
    raise exception 'الطلب غير موجود أو ليس لك';
  end if;
  if v_trip.status <> 'in_progress' then
    raise exception 'لم تستلم الطلب بعد';
  end if;
  if v_trip.delivery_failed_at is not null then
    raise exception 'سُجّل تعذّر التسليم من قبل';
  end if;
  if length(v_reason) < 2 then
    raise exception 'اكتب سبب تعذّر التسليم';
  end if;

  update public.trips
  set delivery_failed_at   = now(),
      delivery_fail_reason = left(v_reason, 200)
  where id = p_trip_id
  returning * into v_trip;

  select split_part(full_name, ' ', 1) into v_name
  from public.profiles where id = auth.uid();

  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (
    v_trip.rider_id,
    'تعذّر تسليم الطلب',
    format('المندوب %s يعيد الطرد إلى متجرك — السبب: %s. الطلب رقم %s.',
           coalesce(v_name, ''), v_trip.delivery_fail_reason, v_trip.trip_number),
    'direct',
    auth.uid()
  );

  return v_trip;
end;
$fn$;

revoke all on function public.report_delivery_failed(uuid, text) from public, anon;
grant execute on function public.report_delivery_failed(uuid, text) to authenticated;


-- -----------------------------------------------------------------------------
-- ١٥) الإنهاء — تسليمٌ أو إعادة
-- -----------------------------------------------------------------------------
-- **يمرّ بـ`complete_trip` لا ينسخها.** العمولة وحالة السائق والعدّاد
-- وقيد المحفظة كلها هناك؛ نسخُها يعني أن يُصلَح أحدهما وينسى الآخر.
-- نكتب النتيجة قبلها لأن مُشغّلات الإكمال تقرؤها.
create or replace function public.complete_delivery(
  p_trip_id    uuid,
  p_distance_m integer default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip    public.trips;
  v_outcome text;
  v_zone    public.pricing_zones;
  v_loc     geography;
  v_age     integer;
  v_dist    integer;
  v_radius  integer;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;
  if not found or v_trip.kind <> 'delivery' then
    raise exception 'الطلب غير موجود أو ليس لك';
  end if;
  if v_trip.status <> 'in_progress' then
    raise exception 'لا يمكن إنهاء طلب حالته %', v_trip.status;
  end if;

  if v_trip.delivery_failed_at is not null then
    v_outcome := 'returned';

    -- **الإعادة تُثبَت بالمكان.** المتجر نقطةٌ معروفة، و«أعدتُ الطرد»
    -- من بعيد يعني طرداً ضائعاً ومالاً يُطالَب به التاجر.
    select z.* into v_zone from public.pricing_zones z
    where z.id = public.zone_for_point(v_trip.pickup_location);
    v_radius := coalesce(v_zone.arrival_radius_m, 200);

    select d.current_location,
           round(extract(epoch from (now() - d.location_updated_at)))::integer
    into v_loc, v_age
    from public.drivers d where d.id = auth.uid();

    if v_loc is null or v_age is null or v_age > 120 then
      raise exception 'تعذّر تحديد موقعك. تأكد أن خدمة الموقع تعمل ثم أعد المحاولة';
    end if;

    v_dist := st_distance(v_loc, v_trip.pickup_location)::integer;
    if v_dist > v_radius then
      raise exception 'أنت على بعد % متر من المتجر. أعد الطرد إليه أولاً', v_dist;
    end if;
  else
    v_outcome := 'delivered';
  end if;

  update public.trips
  set delivery_outcome = v_outcome,
      settle_status = case
        when v_outcome = 'delivered' and pay_mode = 'after'
             and coalesce(goods_actual_iqd, 0) > 0
          then 'open'
      end
  where id = p_trip_id;

  perform public.complete_trip(p_trip_id, p_distance_m, null);

  select * into v_trip from public.trips where id = p_trip_id;
  return v_trip;
end;
$fn$;

revoke all on function public.complete_delivery(uuid, integer) from public, anon;
grant execute on function public.complete_delivery(uuid, integer) to authenticated;


-- -----------------------------------------------------------------------------
-- ١٦) المستحقّ النقدي — منسوخةٌ من 0077 وأُضيف فرع التوصيل في رأسها
-- -----------------------------------------------------------------------------
create or replace function public.settle_rider_credit()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_due    numeric(12,2);
  v_goods  numeric(12,2) := coalesce(new.goods_actual_iqd,
                                     new.goods_estimate_iqd, 0);
  v_bonus  numeric(12,2);
  v_real   numeric(12,2);
  v_use_b  numeric(12,2);
  v_use_r  numeric(12,2);
  v_total  numeric(12,2);
  v_spend  jsonb;
begin
  -- **التوصيل لا يمسّ رصيد التاجر.** التاجر لا يدفع شيئاً؛ المستلم
  -- يدفع للمندوب نقداً، وليس له حسابٌ عندنا. فلا إنفاق رصيد ولا تعويض.
  --
  -- والمستحقّ النقديّ: ثمن السلعة + التوصيل — إلا طرداً أُعيد وكان
  -- الاتفاق «يُعاد الثمن بعد التسليم»: المندوب لم يقبض ثمناً أصلاً،
  -- فلا يأخذ من التاجر إلا أجرته.
  if new.kind = 'delivery' then
    update public.trips
    set cash_due_iqd = coalesce(new.fare_final_iqd, 0)
      + case
          when new.delivery_outcome = 'returned' and new.pay_mode = 'after'
            then 0
          else coalesce(new.goods_actual_iqd, 0)
        end
    where id = new.id;
    return new;
  end if;

  v_due := coalesce(new.fare_final_iqd, 0) - coalesce(new.discount_iqd, 0);

  if v_due <= 0 then
    -- **البضاعة تبقى مستحقّة ولو كانت الأجرة صفراً.** السائق دفعها.
    if v_goods > 0 then
      update public.trips set cash_due_iqd = v_goods where id = new.id;
    end if;
    return new;
  end if;

  v_spend := public.rider_spendable(new.rider_id);
  if v_spend is null then
    if v_goods > 0 then
      update public.trips
      set cash_due_iqd = v_due + v_goods where id = new.id;
    end if;
    return new;
  end if;

  v_bonus := (v_spend ->> 'bonus')::numeric;
  v_real  := (v_spend ->> 'real')::numeric;

  -- **الهدية أولاً.** لأنها تنتهي وماله لا ينتهي.
  v_use_b := least(v_bonus, v_due);
  v_use_r := least(v_real, v_due - v_use_b);
  v_total := v_use_b + v_use_r;

  if v_total <= 0 then
    if v_goods > 0 then
      update public.trips
      set cash_due_iqd = v_due + v_goods where id = new.id;
    end if;
    return new;
  end if;

  update public.rider_wallets
  set bonus_balance_iqd = bonus_balance_iqd - v_use_b,
      real_balance_iqd  = real_balance_iqd  - v_use_r,
      updated_at        = now()
  where id = new.rider_id;

  if v_use_b > 0 then
    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, trip_id, note)
    values (new.rider_id, 'bonus', -v_use_b, 'trip', new.id,
            format('رصيد هدية على الرحلة رقم %s', new.trip_number));
  end if;

  if v_use_r > 0 then
    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, trip_id, note)
    values (new.rider_id, 'real', -v_use_r, 'trip', new.id,
            format('رصيد على الرحلة رقم %s', new.trip_number));
  end if;

  -- **البضاعة تُضاف بعد الرصيد لا قبله.** فلا يُخصم منها شيء.
  update public.trips
  set credit_used_iqd = v_total,
      cash_due_iqd    = greatest(0, v_due - v_total) + v_goods
  where id = new.id;

  -- تعويض السائق عمّا استُهلك من رصيد الراكب — أجرةً لا بضاعة.
  if new.driver_id is not null then
    perform public.post_wallet_transaction(
      p_driver_id   => new.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_total,
      p_trip_id     => new.id,
      p_description => format('تعويض رصيد الراكب — الرحلة رقم %s',
                              new.trip_number)
    );

    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, trip_id, note)
    values (new.driver_id, 'real', v_total, 'trip', new.id,
            format('تعويض رصيد الراكب — الرحلة رقم %s', new.trip_number));
  end if;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ١٧) مستحقات «يُعاد الثمن بعد التسليم»
-- -----------------------------------------------------------------------------
-- **المندوب يعلن والتاجر يؤكّد.** إعلان المندوب وحده يُغلق ديناً بشهادة
-- المدين؛ وانتظار التاجر وحده يترك المندوب بلا طريقٍ ليقول «أعطيتُه».
create or replace function public.claim_delivery_settled(p_trip_id uuid)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip public.trips;
  v_name text;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;
  if not found or v_trip.kind <> 'delivery' then
    raise exception 'الطلب غير موجود أو ليس لك';
  end if;

  case v_trip.settle_status
    when 'claimed' then raise exception 'بانتظار تأكيد المتجر';
    when 'closed'  then raise exception 'أُغلقت مستحقات هذا الطلب من قبل';
    when 'open', 'disputed' then null;
    else raise exception 'لا مستحقات على هذا الطلب';
  end case;

  update public.trips
  set settle_status = 'claimed', settle_claimed_at = now()
  where id = p_trip_id
  returning * into v_trip;

  select split_part(full_name, ' ', 1) into v_name
  from public.profiles where id = auth.uid();

  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (
    v_trip.rider_id,
    'هل وصلك ثمن الطلب؟',
    format('يقول المندوب %s إنه أعاد لك %s دينار — الطلب رقم %s. افتح «طلبات المندوب» وأكّد.',
           coalesce(v_name, ''), coalesce(v_trip.goods_actual_iqd, 0)::bigint,
           v_trip.trip_number),
    'direct',
    auth.uid()
  );

  return v_trip;
end;
$fn$;

create or replace function public.confirm_delivery_settled(
  p_trip_id  uuid,
  p_received boolean
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip public.trips;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and rider_id = auth.uid()
  for update;
  if not found or v_trip.kind <> 'delivery' then
    raise exception 'الطلب غير موجود أو ليس لك';
  end if;
  if v_trip.settle_status is distinct from 'claimed' then
    raise exception 'لا يوجد ما تؤكّده على هذا الطلب';
  end if;

  if p_received then
    update public.trips
    set settle_status = 'closed', settle_closed_at = now()
    where id = p_trip_id
    returning * into v_trip;
  else
    -- **«لا» تفتح نزاعاً ولا تُعيد الدين كما كان.** المدير يراه في
    -- قائمته ويتصل بالطرفين؛ والمندوب يستطيع أن يعلن ثانيةً.
    update public.trips
    set settle_status = 'disputed'
    where id = p_trip_id
    returning * into v_trip;
  end if;

  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (
    v_trip.driver_id,
    case when p_received then 'أكّد المتجر استلام المبلغ'
         else 'المتجر يقول إن المبلغ لم يصله' end,
    case when p_received
      then format('أُغلقت مستحقات الطلب رقم %s (%s دينار).',
                  v_trip.trip_number, coalesce(v_trip.goods_actual_iqd, 0)::bigint)
      else format('الطلب رقم %s — تواصل مع المتجر، والإدارة تتابع.',
                  v_trip.trip_number)
    end,
    'direct',
    auth.uid()
  );

  return v_trip;
end;
$fn$;

revoke all on function public.claim_delivery_settled(uuid) from public, anon;
grant execute on function public.claim_delivery_settled(uuid) to authenticated;
revoke all on function public.confirm_delivery_settled(uuid, boolean) from public, anon;
grant execute on function public.confirm_delivery_settled(uuid, boolean) to authenticated;


-- -----------------------------------------------------------------------------
-- ١٨) المدير — المتاجر
-- -----------------------------------------------------------------------------
create or replace function public.admin_list_stores(
  p_status text default null,
  p_search text default null
)
returns table (
  id               uuid,
  owner_id         uuid,
  name             text,
  phone            text,
  address          text,
  lat              double precision,
  lng              double precision,
  status           public.store_status,
  rejection_reason text,
  created_at       timestamptz,
  updated_at       timestamptz,
  reviewed_at      timestamptz,
  owner_name       text,
  owner_phone      text,
  owner_email      text,
  deliveries_total  bigint,
  deliveries_active bigint,
  open_settlements  bigint,
  open_amount_iqd   numeric
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not public.has_perm('stores.review') then
    raise exception 'لا تملك صلاحية مراجعة المتاجر'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select s.id, s.owner_id, s.name, s.phone, s.address, s.lat, s.lng,
         s.status, s.rejection_reason, s.created_at, s.updated_at,
         s.reviewed_at,
         p.full_name, p.phone, p.email,
         (select count(*) from public.trips t where t.store_id = s.id),
         (select count(*) from public.trips t where t.store_id = s.id
            and t.status in ('searching','accepted','driver_arrived','in_progress')),
         (select count(*) from public.trips t where t.store_id = s.id
            and t.settle_status in ('open','claimed','disputed')),
         (select coalesce(sum(t.goods_actual_iqd), 0) from public.trips t
            where t.store_id = s.id
              and t.settle_status in ('open','claimed','disputed'))
  from public.stores s
  join public.profiles p on p.id = s.owner_id
  where (p_status is null or s.status::text = p_status)
    and (v_q is null
         or s.name ilike '%' || v_q || '%'
         or s.phone ilike '%' || v_q || '%'
         or p.full_name ilike '%' || v_q || '%'
         or p.phone ilike '%' || v_q || '%')
  -- المنتظرة أولاً: هي ما يحتاج المدير أن يفعل فيه شيئاً
  order by (s.status = 'pending') desc, s.created_at desc;
end;
$fn$;

create or replace function public.admin_set_store_status(
  p_store_id uuid,
  p_status   public.store_status,
  p_reason   text default null
)
returns public.stores
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row    public.stores;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_perm('stores.review') then
    raise exception 'لا تملك صلاحية مراجعة المتاجر'
      using errcode = 'insufficient_privilege';
  end if;

  if p_status = 'rejected' and v_reason is null then
    raise exception 'اكتب سبب الرفض — يراه التاجر';
  end if;

  update public.stores
  set status           = p_status,
      rejection_reason = case when p_status = 'rejected' then v_reason end,
      reviewed_by      = auth.uid(),
      reviewed_at      = now()
  where id = p_store_id
  returning * into v_row;

  if not found then raise exception 'المتجر غير موجود'; end if;

  perform public.log_action(
    'stores.set_status', 'stores', p_store_id::text,
    format('%s ← %s%s', v_row.name, p_status,
           case when v_reason is not null then ' — ' || v_reason else '' end));

  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (
    v_row.owner_id,
    case p_status
      when 'approved'  then 'اعتُمد متجرك'
      when 'rejected'  then 'لم يُعتمد متجرك'
      when 'suspended' then 'أُوقف متجرك مؤقتاً'
      else 'متجرك قيد المراجعة'
    end,
    case p_status
      when 'approved'  then format('متجر «%s» معتمد — تستطيع الآن طلب مندوب.', v_row.name)
      when 'rejected'  then format('السبب: %s. عدّل بيانات المتجر ليُراجَع من جديد.', v_reason)
      when 'suspended' then format('متجر «%s» موقوف مؤقتاً عن طلب المناديب. تواصل مع الدعم.', v_row.name)
      else format('متجر «%s» بانتظار المراجعة.', v_row.name)
    end,
    'direct',
    auth.uid()
  );

  return v_row;
end;
$fn$;

create or replace function public.admin_delete_store(p_store_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.stores;
begin
  if not public.has_perm('stores.review') then
    raise exception 'لا تملك صلاحية مراجعة المتاجر'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.stores where id = p_store_id for update;
  if not found then raise exception 'المتجر غير موجود'; end if;

  -- **لا حذف ومندوبٌ في الطريق.** الطلب يبقى، لكن التاجر يفقد شاشته
  -- ولا يعرف أين طرده.
  if exists (select 1 from public.trips
             where store_id = p_store_id
               and status in ('searching','accepted','driver_arrived','in_progress')) then
    raise exception 'للمتجر طلبات جارية — انتظر انتهاءها أو ألغها أولاً';
  end if;

  delete from public.stores where id = p_store_id;

  perform public.log_action(
    'stores.delete', 'stores', p_store_id::text,
    format('حذف متجر «%s»', v_row.name));

  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (v_row.owner_id, 'حُذف متجرك',
          format('حُذف متجر «%s» من زنبور. تستطيع تسجيله من جديد من «متجري».', v_row.name),
          'direct', auth.uid());
end;
$fn$;

revoke all on function public.admin_list_stores(text, text) from public, anon;
grant execute on function public.admin_list_stores(text, text) to authenticated;
revoke all on function public.admin_set_store_status(uuid, public.store_status, text) from public, anon;
grant execute on function public.admin_set_store_status(uuid, public.store_status, text) to authenticated;
revoke all on function public.admin_delete_store(uuid) from public, anon;
grant execute on function public.admin_delete_store(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- ١٩) المدير — المستحقات
-- -----------------------------------------------------------------------------
create or replace function public.admin_delivery_settlements(
  p_status text default null
)
returns table (
  trip_id        uuid,
  trip_number    bigint,
  completed_at   timestamptz,
  store_name     text,
  store_phone    text,
  driver_id      uuid,
  driver_name    text,
  driver_phone   text,
  amount_iqd     numeric,
  settle_status  text,
  claimed_at     timestamptz,
  closed_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.has_perm('deliveries.settle') then
    raise exception 'لا تملك صلاحية المستحقات'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select t.id, t.trip_number::bigint, t.completed_at,
         t.shop_name, t.store_phone,
         t.driver_id, p.full_name, p.phone,
         t.goods_actual_iqd, t.settle_status,
         t.settle_claimed_at, t.settle_closed_at
  from public.trips t
  left join public.profiles p on p.id = t.driver_id
  where t.kind = 'delivery'
    and t.settle_status is not null
    and (p_status is null or t.settle_status = p_status)
  -- النزاعات أولاً ثم الأقدم: ما طال انتظاره أحقّ بالمتابعة
  order by (t.settle_status = 'disputed') desc, t.completed_at asc;
end;
$fn$;

create or replace function public.admin_close_settlement(
  p_trip_id uuid,
  p_note    text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip public.trips;
begin
  if not public.has_perm('deliveries.settle') then
    raise exception 'لا تملك صلاحية المستحقات'
      using errcode = 'insufficient_privilege';
  end if;

  update public.trips
  set settle_status = 'closed', settle_closed_at = now()
  where id = p_trip_id and kind = 'delivery' and settle_status is not null
  returning * into v_trip;
  if not found then raise exception 'لا مستحقات على هذا الطلب'; end if;

  perform public.log_action(
    'deliveries.close_settlement', 'trips', p_trip_id::text,
    format('أُغلقت مستحقات الطلب %s%s', v_trip.trip_number,
           coalesce(' — ' || nullif(btrim(p_note), ''), '')));

  insert into public.notifications (user_id, title, body, kind, sent_by)
  select u, 'أغلقت الإدارة المستحقات',
         format('أُغلقت مستحقات الطلب رقم %s.', v_trip.trip_number),
         'direct', auth.uid()
  from unnest(array[v_trip.rider_id, v_trip.driver_id]) as u
  where u is not null;
end;
$fn$;

revoke all on function public.admin_delivery_settlements(text) from public, anon;
grant execute on function public.admin_delivery_settlements(text) to authenticated;
revoke all on function public.admin_close_settlement(uuid, text) from public, anon;
grant execute on function public.admin_close_settlement(uuid, text) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — كل الأرقام يجب أن تطابق ما بين القوسين
-- -----------------------------------------------------------------------------
select
  (select count(*) from information_schema.tables
   where table_schema = 'public' and table_name = 'stores')          as "جدول المتاجر (١)",
  (select count(*) from information_schema.columns
   where table_name = 'trips' and column_name in
     ('store_id','recipient_phone','pay_mode','delivery_outcome','settle_status'))
                                                                     as "أعمدة الطلب (٥)",
  (select count(*) from information_schema.columns
   where table_name = 'drivers'
     and column_name in ('accepts_delivery','accepts_bike_deliveries')) as "مفتاحا السائق (٢)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('save_my_store','request_delivery','choose_delivery_payment',
                     'report_delivery_failed','complete_delivery',
                     'claim_delivery_settled','confirm_delivery_settled',
                     'admin_list_stores','admin_set_store_status',
                     'admin_delete_store','admin_delivery_settlements',
                     'admin_close_settlement','set_accepts_delivery',
                     'set_accepts_bike_deliveries'))                  as "الدوال (١٤)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname = 'dispatch_next_offer' and prosrc like '%v_delivery%')  as "التوزيع يعرف التوصيل (١)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname = 'settle_rider_credit' and prosrc like '%delivery_outcome%') as "الرصيد لا يُمسّ (١)",
  public.service_status() ? 'delivery'                                as "حالة الخدمة (true)";
