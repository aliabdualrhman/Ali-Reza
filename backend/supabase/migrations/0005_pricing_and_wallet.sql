-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0005 — التسعير والمحفظة
-- =============================================================================

-- =============================================================================
-- إعدادات التسعير — صف واحد لكل مدينة
-- =============================================================================
-- نجعلها جدولاً لا ثوابت في الكود لسببين:
--   ١) الأسعار تتغير مع الوقود والتضخم، ولا يجوز أن يتطلب ذلك إصدار تطبيق جديد.
--   ٢) بغداد ليست البصرة — كل مدينة لها تسعيرتها.
-- =============================================================================
create table public.pricing_zones (
  id                 uuid primary key default gen_random_uuid(),
  city_name          text not null,
  city_name_ar       text not null,

  -- حدود المنطقة. الطلب خارج أي منطقة مفعّلة يُرفض.
  boundary           geography(Polygon, 4326) not null,

  -- ---------------------------------------------------------------------------
  -- مكوّنات الأجرة (بالدينار العراقي)
  --   الأجرة = أجرة_البداية + (كم × سعر_الكم) + (دقيقة × سعر_الدقيقة)
  --   ثم تُضرب بمعامل الذروة، ولا تنزل تحت الحد الأدنى.
  -- ---------------------------------------------------------------------------
  base_fare_iqd      numeric(10,2) not null default 1000,
  per_km_iqd         numeric(10,2) not null default 250,
  per_minute_iqd     numeric(10,2) not null default 25,
  minimum_fare_iqd   numeric(10,2) not null default 1500,

  -- رسوم الإلغاء بعد قبول السائق وتحركه نحو الراكب
  cancellation_fee_iqd numeric(10,2) not null default 1000,
  -- مهلة الإلغاء المجاني بالثواني بعد قبول السائق
  free_cancel_window_s integer not null default 120,

  -- نسبة عمولة المنصة من الأجرة (0.15 = ١٥٪)
  commission_rate    numeric(4,3) not null default 0.150,

  -- ---------------------------------------------------------------------------
  -- حدود المطابقة
  -- ---------------------------------------------------------------------------
  search_radius_m         integer not null default 3000,
  max_search_radius_m     integer not null default 7000,
  offer_timeout_s         integer not null default 15,
  max_offers_per_trip     smallint not null default 8,

  -- أقصى دين مسموح على السائق قبل فصله عن الشبكة (قيمة سالبة)
  min_wallet_balance_iqd  numeric(12,2) not null default -25000,

  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint pricing_commission_sane check (commission_rate between 0 and 0.5),
  constraint pricing_radius_order    check (max_search_radius_m >= search_radius_m)
);

create index pricing_zones_boundary_gist on public.pricing_zones using gist (boundary)
  where is_active;

create trigger pricing_zones_touch_updated_at
  before update on public.pricing_zones
  for each row execute function public.touch_updated_at();

-- =============================================================================
-- معاملات الذروة — رفع السعر وقت ازدحام الطلب
-- =============================================================================
-- يُحسب دورياً: عدد الطلبات النشطة ÷ عدد السائقين المتاحين في المنطقة.
-- نخزّنه بدل حسابه لحظياً حتى لا يتغير السعر بين شاشة التقدير وشاشة التأكيد.
-- =============================================================================
create table public.surge_state (
  zone_id     uuid primary key references public.pricing_zones(id) on delete cascade,
  multiplier  numeric(4,2) not null default 1.00 check (multiplier between 1.00 and 5.00),
  active_requests  integer not null default 0,
  available_drivers integer not null default 0,
  updated_at  timestamptz not null default now()
);

-- =============================================================================
-- حركات محفظة السائق — دفتر أستاذ لا يُعدَّل ولا يُحذف منه
-- =============================================================================
-- كل صف حركة واحدة، ونخزّن الرصيد بعدها (balance_after) لنستطيع تدقيق أي
-- خلاف مالي لاحقاً دون إعادة حساب التاريخ كله.
-- =============================================================================
create table public.wallet_transactions (
  id             uuid primary key default gen_random_uuid(),
  driver_id      uuid not null references public.drivers(id) on delete restrict,
  trip_id        uuid references public.trips(id) on delete set null,

  txn_type       public.wallet_txn_type not null,
  amount_iqd     numeric(12,2) not null,   -- موجب = إضافة، سالب = خصم
  balance_after_iqd numeric(12,2) not null,

  description    text,
  created_by     uuid references public.profiles(id),  -- للتسويات اليدوية
  created_at     timestamptz not null default now(),

  constraint wallet_amount_nonzero check (amount_iqd <> 0)
);

create index wallet_txn_driver_idx on public.wallet_transactions (driver_id, created_at desc);
create index wallet_txn_trip_idx   on public.wallet_transactions (trip_id);

-- -----------------------------------------------------------------------------
-- الدالة الوحيدة المسموح لها تعديل رصيد المحفظة.
--
-- لماذا دالة واحدة؟ لأن تحديث الرصيد وتسجيل الحركة يجب أن يحدثا معاً أو
-- لا يحدثا إطلاقاً. لو سمحنا بتحديث drivers.wallet_balance_iqd مباشرة من
-- أماكن متفرقة لانحرف الرصيد عن مجموع الحركات وضاعت إمكانية التدقيق.
--
-- for update: يقفل صف السائق حتى نهاية المعاملة، فلا تتداخل حركتان متزامنتان.
-- -----------------------------------------------------------------------------
create or replace function public.post_wallet_transaction(
  p_driver_id   uuid,
  p_txn_type    public.wallet_txn_type,
  p_amount_iqd  numeric,
  p_trip_id     uuid default null,
  p_description text default null,
  p_created_by  uuid default null
)
returns public.wallet_transactions
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_new_balance numeric(12,2);
  v_txn public.wallet_transactions;
begin
  if p_amount_iqd = 0 then
    raise exception 'لا يمكن تسجيل حركة محفظة بقيمة صفر';
  end if;

  -- القفل يمنع تسابق حركتين على نفس المحفظة
  select wallet_balance_iqd + p_amount_iqd
  into v_new_balance
  from public.drivers
  where id = p_driver_id
  for update;

  if not found then
    raise exception 'السائق % غير موجود', p_driver_id;
  end if;

  -- نرفع علم تجاوز الحُرّاس: هذا تعديل نظامي موثوق، لا من المستخدم.
  perform set_config('app.bypass_guards', 'on', true);

  update public.drivers
  set wallet_balance_iqd = v_new_balance
  where id = p_driver_id;

  perform set_config('app.bypass_guards', 'off', true);


  insert into public.wallet_transactions
    (driver_id, trip_id, txn_type, amount_iqd, balance_after_iqd, description, created_by)
  values
    (p_driver_id, p_trip_id, p_txn_type, p_amount_iqd, v_new_balance, p_description, p_created_by)
  returning * into v_txn;

  return v_txn;
end;
$$;

-- منع الكتابة المباشرة على الرصيد من خارج الدالة أعلاه — طبقتان:
--   ١) سحب صلاحية UPDATE على العمود من مستخدمي التطبيق (هنا).
--   ٢) المُشغّل drivers_guard_columns في 0007 يرفض أي تغيير للرصيد ما لم
--      يكن العلم app.bypass_guards مرفوعاً، وهو ما لا تفعله إلا هذه الدالة.
-- الطبقة الأولى وحدها لا تكفي: الدوال security definer تعمل بصلاحيات المالك
-- وتتجاوز منح الصلاحيات، فلولا المُشغّل لاستطاعت أي دالة منها تعديل الرصيد.
revoke update (wallet_balance_iqd) on public.drivers from authenticated, anon;

-- =============================================================================
-- حساب الأجرة
-- =============================================================================
-- ترجع jsonb لا رقماً مفرداً: نحتاج تفصيل المكوّنات لعرضه للراكب ولتجميده
-- داخل الرحلة (fare_breakdown). الشفافية تقلّل نزاعات الأجرة كثيراً.
-- =============================================================================
create or replace function public.calculate_fare(
  p_zone_id     uuid,
  p_distance_m  integer,
  p_duration_s  integer,
  p_surge       numeric default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  z public.pricing_zones;
  v_surge     numeric(4,2);
  v_distance  numeric;
  v_time      numeric;
  v_subtotal  numeric;
  v_total     numeric;
  v_commission numeric;
begin
  select * into z from public.pricing_zones where id = p_zone_id and is_active;
  if not found then
    raise exception 'منطقة تسعير غير معروفة أو غير مفعّلة: %', p_zone_id;
  end if;

  v_surge := coalesce(
    p_surge,
    (select multiplier from public.surge_state where zone_id = p_zone_id),
    1.00
  );

  v_distance := (p_distance_m::numeric / 1000) * z.per_km_iqd;
  v_time     := (p_duration_s::numeric / 60)   * z.per_minute_iqd;
  v_subtotal := z.base_fare_iqd + v_distance + v_time;
  v_total    := greatest(v_subtotal * v_surge, z.minimum_fare_iqd);

  -- التقريب لأقرب ٢٥٠ دينار: أصغر فئة نقدية متداولة عملياً في العراق،
  -- ويجنّب السائق والراكب مشكلة "ما عندي فراطة".
  v_total := round(v_total / 250) * 250;

  v_commission := round(v_total * z.commission_rate, 2);

  return jsonb_build_object(
    'currency',        'IQD',
    'base_fare',       z.base_fare_iqd,
    'distance_m',      p_distance_m,
    'distance_charge', round(v_distance, 2),
    'duration_s',      p_duration_s,
    'time_charge',     round(v_time, 2),
    'subtotal',        round(v_subtotal, 2),
    'surge_multiplier', v_surge,
    'minimum_fare',    z.minimum_fare_iqd,
    'total',           v_total,
    'commission_rate', z.commission_rate,
    'commission',      v_commission,
    'driver_earning',  v_total - v_commission,
    'calculated_at',   now()
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- تحديد منطقة التسعير من نقطة جغرافية.
-- st_contains يستفيد من الفهرس المكاني على boundary.
-- -----------------------------------------------------------------------------
create or replace function public.zone_for_point(p_point geography)
returns uuid
language sql
stable
security definer
set search_path = public, extensions
as $$
  select id
  from public.pricing_zones
  where is_active
    and st_contains(boundary::geometry, p_point::geometry)
  limit 1;
$$;
