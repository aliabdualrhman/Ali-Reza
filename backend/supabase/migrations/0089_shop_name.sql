-- =============================================================================
-- 0089 — اسم المحل في طلب التسوّق (اختياري)
-- =============================================================================
-- الراكب يحدّد المحل بنقطة على الخريطة، والنقطة في سوقٍ مزدحم تقع بين
-- عشرة محلات. يصل السائق فيقف أمام صفٍّ من الأبواب لا يدري أيّها، فيتصل
-- بالراكب ويسأل — أو يدخل المحل الخطأ.
--
-- **عمودٌ مستقل لا سطرٌ يُلصق بالعنوان.** العنوان يأتي من خدمة الخرائط،
-- والاسم يكتبه الراكب؛ خلطُهما يُفسد العنوان في كل مكان يُعرض فيه، ويمنع
-- التطبيق من إبراز الاسم وهو أول ما يبحث عنه السائق بعينه.
-- =============================================================================

alter table public.trips add column if not exists shop_name text;

comment on column public.trips.shop_name is
  'اسم المحل في طلب التسوّق كما كتبه الراكب — اختياري.';


-- **كل النسخ السابقة تُحذف قبل الإنشاء.** إضافة وسيطٍ تُنشئ دالةً ثانية
-- بالاسم نفسه بدل أن تستبدل الأولى، فيصير النداء «غير فريد» ويفشل
-- (وقع هذا في 0027).
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname = 'request_shopping' and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

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
  p_coupon_code     text default null,
  p_shop_name       text default null
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
  v_name    text := nullif(btrim(p_shop_name), '');
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

  if length(v_name) > 60 then
    raise exception 'اسم المحل طويل — ٦٠ حرفاً على الأكثر';
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
      stop_count, current_leg, vehicle_kind,
      shop_name
    ) values (
      auth.uid(), 'shopping',
      v_shop, p_shop_address,
      v_drop, p_drop_address,
      p_distance_m, p_duration_s,
      v_total, v_total, 1.0, v_fare,
      'cash', p_note,
      p_items, p_goods_estimate,
      v_cid, v_disc,
      1, 1, 'bike',
      v_name
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

-- الوسيط الجديد في الآخر وبقيمة افتراضية: التطبيق القديم يرسل اثني عشر
-- وسيطاً بأسمائها فيصيب هذه الدالة نفسها، والاسم يبقى فارغاً.
revoke all on function public.request_shopping(
  double precision, double precision, text,
  double precision, double precision, text,
  integer, integer, jsonb, numeric, text, text, text) from public, anon;
grant execute on function public.request_shopping(
  double precision, double precision, text,
  double precision, double precision, text,
  integer, integer, jsonb, numeric, text, text, text) to authenticated;
