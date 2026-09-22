-- =============================================================================
-- 0078 — الكوبون يخصم من التوصيل وحده
-- =============================================================================
-- **البضاعة تُدفع كاملةً دائماً.** ثمنها مالُ البقّال لا مالُنا: دفعه
-- السائق من جيبه، فأيّ خصمٍ عليه يخرج من خزينتنا نقداً — لا ورقةً
-- تُمحى كما هي حال خصم الأجرة.
--
-- والفرق ليس محاسبياً بحتاً: كوبون «خصم ٥٠٪» على طلبٍ بمئة ألف يعني
-- خمسين ألفاً نقداً في يد سائق. وكوبونٌ واحدٌ يُنشر في مجموعة واتساب
-- يفرّغ الخزينة في ساعة.
--
-- ------------------------------------------------------------------
-- وأمران في هذا الملف
-- ------------------------------------------------------------------
--   ١. **طلب التسوّق لم يكن يقبل كوبوناً أصلاً** — أغفلتُ تمريره في
--      0077. فنضيفه، ومحسوباً على الأجرة وحدها.
--
--   ٢. **وحارسٌ في القاعدة لا في الحساب.** الحساب اليوم سليم: الخصم
--      يُطرح من الأجرة و`greatest(0, …)` يمنع نزوله تحت الصفر. لكنّ
--      سلامته عرَضٌ لا ضمان — سطرٌ يُكتب غداً في مكانٍ آخر قد يكسره
--      بلا أن ينتبه أحد. فنثبّت القاعدة قيداً على الجدول.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) قيدٌ يمنع الخصم من تجاوز الأجرة
-- -----------------------------------------------------------------------------
-- **يحرس البضاعة بلا أن يذكرها.** ما دام الخصم لا يتجاوز الأجرة، فهو
-- لا يمسّ البضاعة أبداً مهما تغيّر ما فوقه من منطق.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'trips_discount_within_fare'
  ) then
    alter table public.trips
      add constraint trips_discount_within_fare
      check (
        coalesce(discount_iqd, 0) <=
        greatest(coalesce(fare_final_iqd, 0), coalesce(fare_estimated_iqd, 0))
      )
      not valid;   -- **لا نُدقّق القديم.** رحلاتٌ مضت لن تتغيّر،
                   -- وتدقيقها يقفل الجدول دقائق بلا فائدة.
  end if;
end $$;


-- -----------------------------------------------------------------------------
-- ٢) الطلب يقبل كوبوناً — على الأجرة وحدها
-- -----------------------------------------------------------------------------
create or replace function public.request_shopping(
  p_shop_lat        double precision,
  p_shop_lng        double precision,
  p_shop_address    text,
  p_drop_lat        double precision,
  p_drop_lng        double precision,
  p_drop_address    text,
  p_distance_m      integer,
  p_duration_s      integer,
  p_items           jsonb,
  p_goods_estimate  numeric,
  p_note            text default null,
  p_coupon_code     text default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_rider   public.profiles;
  v_shop    geography;
  v_drop    geography;
  v_zone_id uuid;
  v_fare    jsonb;
  v_total   numeric(10,2);
  v_min     numeric(10,2);
  v_max     numeric(10,2);
  v_maxn    integer;
  v_coupon  jsonb;
  v_cid     uuid;
  v_disc    numeric(10,2) := 0;
  v_trip    public.trips;
begin
  select * into v_rider from public.profiles where id = auth.uid();
  if not found or v_rider.is_blocked then
    raise exception 'غير مصرّح لك بطلب تسوّق'
      using errcode = 'insufficient_privilege';
  end if;

  if public.referral_setting('shopping_enabled', 1) = 0 then
    raise exception 'خدمة التسوّق متوقّفة حالياً';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'اكتب سلعةً واحدة على الأقل';
  end if;

  v_maxn := public.referral_setting('shopping_max_items', 20)::integer;
  if jsonb_array_length(p_items) > v_maxn then
    raise exception 'أقصى عدد سلع في الطلب %', v_maxn;
  end if;

  v_max := public.referral_setting('shopping_max_goods_iqd', 50000);
  if coalesce(p_goods_estimate, 0) <= 0 then
    raise exception 'اكتب السعر التقريبي للطلب';
  end if;
  if p_goods_estimate > v_max then
    raise exception 'أقصى قيمة طلب % دينار', v_max::bigint;
  end if;

  v_shop := st_setsrid(st_makepoint(p_shop_lng, p_shop_lat), 4326)::geography;
  v_drop := st_setsrid(st_makepoint(p_drop_lng, p_drop_lat), 4326)::geography;

  v_zone_id := public.zone_for_point(v_shop);
  if v_zone_id is null then
    raise exception 'المحل خارج نطاق الخدمة';
  end if;

  v_fare := public.calculate_fare(v_zone_id, p_distance_m, p_duration_s, 1.0);

  v_min   := public.referral_setting('shopping_min_fare_iqd', 1500);
  v_total := greatest((v_fare ->> 'total')::numeric, v_min);

  -- ---- الكوبون: على `v_total` لا على `v_total + البضاعة` ----
  -- **الفرق هو كل شيء.** لو مرّرنا المجموع لصار الخصم يأكل من ثمن
  -- البضاعة — ومن جيبنا نقداً، لا من عمولةٍ لم تُكسب.
  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    v_coupon := public.check_coupon(p_coupon_code, v_total);
    v_cid    := (v_coupon ->> 'coupon_id')::uuid;
    v_disc   := least((v_coupon ->> 'discount_iqd')::numeric, v_total);
  end if;

  begin
    insert into public.trips (
      rider_id, kind,
      pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, fare_locked_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note,
      items, goods_estimate_iqd,
      coupon_id, discount_iqd,
      stop_count, current_leg, vehicle_kind
    ) values (
      auth.uid(), 'shopping',
      v_shop, p_shop_address,
      v_drop, p_drop_address,
      p_distance_m, p_duration_s,
      v_total, v_total, 1.0, v_fare,
      'cash', p_note,
      p_items, p_goods_estimate,
      v_cid, v_disc,
      1, 1, 'bike'
    )
    returning * into v_trip;
  exception when unique_violation then
    raise exception 'لديك طلب نشط بالفعل' using errcode = 'unique_violation';
  end;

  insert into public.trip_stops
    (trip_id, seq, location, address, leg_distance_m, leg_duration_s,
     leg_fare_iqd)
  values (v_trip.id, 1, v_drop, p_drop_address,
          p_distance_m, p_duration_s, v_total);

  perform public.dispatch_next_offer(v_trip.id);

  return v_trip;
end;
$fn$;

-- **النسخة القديمة تُحذف.** بقاؤها يجعل النداء بأحد عشر وسيطاً يصيب
-- دالةً بلا كوبون — وهو ما يفعله التطبيق القديم بالضبط.
drop function if exists public.request_shopping(
  double precision, double precision, text,
  double precision, double precision, text,
  integer, integer, jsonb, numeric, text);

revoke all on function public.request_shopping(
  double precision, double precision, text,
  double precision, double precision, text,
  integer, integer, jsonb, numeric, text, text) from public, anon;
grant execute on function public.request_shopping(
  double precision, double precision, text,
  double precision, double precision, text,
  integer, integer, jsonb, numeric, text, text) to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) وعند الإكمال أيضاً
-- -----------------------------------------------------------------------------
-- `complete_trip` تُعيد حساب الخصم على الأجرة النهائية وتحرسه بـ`least`
-- — فهو محروسٌ هناك أصلاً. ونثبّت هنا أن البضاعة لا تدخل ذلك الحساب
-- إطلاقاً: `goods_actual_iqd` عمودٌ مستقلّ لا يُجمع مع `fare_final`.
comment on column public.trips.goods_actual_iqd is
  'ثمن البضاعة كما دفعه السائق. **لا يدخل حساب العمولة ولا الخصم** — '
  'مال البقّال لا مالنا، ويُدفع كاملاً دائماً.';


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_proc
   where proname = 'request_shopping'
     and pronamespace = 'public'::regnamespace) as "نسخ الدالة (يجب ١)",
  exists (select 1 from pg_constraint
          where conname = 'trips_discount_within_fare') as "القيد مثبَّت";
