set search_path = public, extensions;

-- =============================================================================
-- 0027 — إعدادات عامة، ورصيد ترحيبي، وكوبونات الخصم
-- =============================================================================
-- ثلاث ميزات يجمعها أنها **بيانات يديرها المدير لا ثوابت في الكود**:
-- رقم شراء الرصيد، وقيمة الرصيد الترحيبي، وكوبونات الخصم بكل شروطها.
-- تغييرها لا يحتاج إعادة بناء تطبيق ولا نشر دالة.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) إعدادات عامة يقرؤها الجميع
-- -----------------------------------------------------------------------------
-- **لماذا جدول جديد ولا نستعمل `app_config`؟** لأن `app_config` يحمل
-- `service_role key` — مفتاحاً يتجاوز كل سياسات الأمان. جدوله بلا سياسات
-- قراءة عمداً، ولا يجوز أن نفتحه لأننا نحتاج رقم هاتف.
--
-- الفصل هنا ليس ترتيباً بل حماية: سرٌّ واحد في جدول مقروء يُسقط النظام كله.
create table if not exists public.public_settings (
  key         text primary key,
  value       text not null,
  label       text,                 -- اسم الإعداد كما يظهر في لوحة التحكم
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles(id)
);

alter table public.public_settings enable row level security;

drop policy if exists "settings: يقرأ الجميع" on public.public_settings;
create policy "settings: يقرأ الجميع"
  on public.public_settings for select to authenticated
  using (true);

drop policy if exists "settings: يكتب المشرف" on public.public_settings;
create policy "settings: يكتب المشرف"
  on public.public_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

comment on table public.public_settings is
  'إعدادات غير سرّية يقرؤها كل مستخدم مسجّل. لا تضع فيها مفاتيح إطلاقاً.';

insert into public.public_settings (key, value, label) values
  ('topup_whatsapp', '+9647801711922', 'رقم شراء الرصيد (واتساب)'),
  ('welcome_credit_iqd', '5000', 'الرصيد الترحيبي للسائق الجديد')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- ٢) الرصيد الترحيبي
-- -----------------------------------------------------------------------------
-- **مُشغّل على `drivers` لا داخل `handle_new_user`.** السائق قد يُنشأ من
-- مسار آخر لاحقاً (استيراد، إنشاء يدوي من اللوحة)، ومنطقٌ داخل دالة
-- التسجيل وحدها يفوته ذلك صامتاً.
create or replace function public.grant_welcome_credit()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_amount numeric;
begin
  select value::numeric into v_amount
  from public.public_settings where key = 'welcome_credit_iqd';

  if coalesce(v_amount, 0) > 0 then
    perform public.post_wallet_transaction(
      p_driver_id   => new.id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_amount,
      p_description => 'رصيد ترحيبي'
    );
  end if;

  return new;
end;
$fn$;

drop trigger if exists drivers_welcome_credit on public.drivers;
create trigger drivers_welcome_credit
  after insert on public.drivers
  for each row execute function public.grant_welcome_credit();


-- -----------------------------------------------------------------------------
-- ٣) الكوبونات
-- -----------------------------------------------------------------------------
create table if not exists public.coupons (
  id            uuid primary key default gen_random_uuid(),

  -- نخزّنه كما يكتبه المدير ونقارن بلا حساسية لحالة الأحرف: الراكب يكتب
  -- الرمز بيده على هاتف، و"ZANBOUR" و"zanbour" شيء واحد عنده.
  code          text not null unique,

  discount_pct  smallint not null check (discount_pct between 1 and 100),

  -- الجمهور. اليوم قيمة واحدة، والعمود موجود ليتوسّع بلا تغيير مخطط:
  -- ركّاب جدد، مدينة بعينها، من لم يركب منذ شهر…
  audience      text not null default 'all_riders',

  -- كم مرة يستعمله **الراكب الواحد**، لا الكوبون كله.
  max_uses_per_rider smallint not null default 1 check (max_uses_per_rider > 0),

  valid_from    timestamptz not null default now(),
  valid_until   timestamptz,          -- فارغ = بلا انتهاء
  is_active     boolean not null default true,

  note          text,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

create index if not exists coupons_active_idx
  on public.coupons (created_at desc) where is_active;

comment on table public.coupons is
  'كوبونات خصم بنسبة مئوية. الخصم يتحمّله المنصة ويُعوَّض للسائق كاملاً.';


create table if not exists public.coupon_redemptions (
  id           uuid primary key default gen_random_uuid(),
  coupon_id    uuid not null references public.coupons(id) on delete cascade,
  rider_id     uuid not null references public.profiles(id) on delete cascade,
  trip_id      uuid not null references public.trips(id) on delete cascade,
  discount_iqd numeric(10,2) not null default 0,
  created_at   timestamptz not null default now(),

  -- استعمال واحد لكل رحلة مهما تكرر الطلب
  unique (trip_id)
);

create index if not exists coupon_redemptions_rider_idx
  on public.coupon_redemptions (coupon_id, rider_id);


-- الرحلة تحمل أثر الكوبون: بلا ذلك لا نعرف عند الإنهاء كم نخصم ولمن نعوّض
alter table public.trips
  add column if not exists coupon_id    uuid references public.coupons(id),
  add column if not exists discount_iqd numeric(10,2) not null default 0;

comment on column public.trips.discount_iqd is
  'ما خُصم عن الراكب. يدفعه المنصة للسائق تعويضاً عند الإنهاء.';


alter table public.coupons            enable row level security;
alter table public.coupon_redemptions enable row level security;

-- **الراكب لا يقرأ جدول الكوبونات.** قراءته تعني تصفّح الرموز الصالحة
-- كلها. التحقق يمرّ بدالة تأخذ رمزاً وتردّ نعم أو لا.
drop policy if exists "coupons: للمشرف وحده" on public.coupons;
create policy "coupons: للمشرف وحده"
  on public.coupons for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "redemptions: يقرأ صاحبها والمشرف" on public.coupon_redemptions;
create policy "redemptions: يقرأ صاحبها والمشرف"
  on public.coupon_redemptions for select to authenticated
  using (rider_id = auth.uid() or public.is_admin());


-- -----------------------------------------------------------------------------
-- ٤) التحقق من كوبون — يستدعيه الراكب قبل الطلب
-- -----------------------------------------------------------------------------
-- تعيد نسبة الخصم وقيمته والأجرة بعده، أو ترفع خطأً بالعربية يشرح السبب.
create or replace function public.check_coupon(p_code text, p_fare numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_c    public.coupons;
  v_used integer;
  v_disc numeric(10,2);
begin
  if auth.uid() is null then
    raise exception 'سجّل دخولك أولاً' using errcode = 'insufficient_privilege';
  end if;

  select * into v_c from public.coupons
  where lower(code) = lower(btrim(coalesce(p_code, '')));

  if not found then
    raise exception 'رمز غير صحيح';
  end if;

  if not v_c.is_active then
    raise exception 'هذا الكوبون موقوف';
  end if;

  if now() < v_c.valid_from then
    raise exception 'هذا الكوبون لم يبدأ بعد';
  end if;

  if v_c.valid_until is not null and now() > v_c.valid_until then
    raise exception 'انتهت صلاحية هذا الكوبون';
  end if;

  select count(*) into v_used
  from public.coupon_redemptions r
  where r.coupon_id = v_c.id and r.rider_id = auth.uid();

  if v_used >= v_c.max_uses_per_rider then
    raise exception 'استعملت هذا الكوبون % مرة', v_c.max_uses_per_rider;
  end if;

  -- التقريب لأقرب ٢٥٠ كما في الأجرة نفسها: نقود العراق لا تعرف الوحدات
  -- الصغيرة، وخصم ١٨٧ ديناراً لا يُدفع في الشارع.
  v_disc := round((p_fare * v_c.discount_pct / 100.0) / 250) * 250;

  return jsonb_build_object(
    'coupon_id',    v_c.id,
    'code',         v_c.code,
    'discount_pct', v_c.discount_pct,
    'discount_iqd', v_disc,
    'fare_after',   greatest(p_fare - v_disc, 0),
    'uses_left',    v_c.max_uses_per_rider - v_used
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) طلب الرحلة يقبل كوبوناً
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
  p_coupon_code     text default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_rider   public.profiles;
  v_pickup  geography;
  v_dropoff geography;
  v_zone_id uuid;
  v_fare    jsonb;
  v_trip    public.trips;
  v_coupon  jsonb;
  v_cid     uuid;
  v_disc    numeric(10,2) := 0;
begin
  select * into v_rider from public.profiles where id = auth.uid();
  if not found or v_rider.is_blocked then
    raise exception 'غير مصرّح لك بطلب رحلة' using errcode = 'insufficient_privilege';
  end if;

  v_pickup  := st_setsrid(st_makepoint(p_pickup_lng,  p_pickup_lat),  4326)::geography;
  v_dropoff := st_setsrid(st_makepoint(p_dropoff_lng, p_dropoff_lat), 4326)::geography;

  v_zone_id := public.zone_for_point(v_pickup);
  if v_zone_id is null then
    raise exception 'نقطة الانطلاق خارج نطاق الخدمة';
  end if;

  v_fare := public.calculate_fare(v_zone_id, p_distance_m, p_duration_s);

  -- **نتحقق من الكوبون هنا ثانيةً وإن تحقق التطبيق منه.** ما يُفحص على
  -- الهاتف يُتجاوز بتطبيق معدَّل، والخصم مالٌ حقيقي يخرج من جيبنا.
  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    v_coupon := public.check_coupon(p_coupon_code, (v_fare ->> 'total')::numeric);
    v_cid    := (v_coupon ->> 'coupon_id')::uuid;
    v_disc   := (v_coupon ->> 'discount_iqd')::numeric;
  end if;

  begin
    insert into public.trips (
      rider_id, pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note, coupon_id, discount_iqd
    ) values (
      auth.uid(), v_pickup, p_pickup_address,
      v_dropoff, p_dropoff_address,
      p_distance_m, p_duration_s,
      (v_fare ->> 'total')::numeric,
      (v_fare ->> 'surge_multiplier')::numeric,
      v_fare,
      p_payment_method, p_note, v_cid, v_disc
    )
    returning * into v_trip;
  exception when unique_violation then
    raise exception 'لديك رحلة نشطة بالفعل' using errcode = 'unique_violation';
  end;

  perform public.dispatch_next_offer(v_trip.id);

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) الإنهاء: الراكب يدفع أقل، والسائق يُعوَّض كاملاً
-- -----------------------------------------------------------------------------
-- **العمولة تُحسب على الأجرة الكاملة لا على المدفوع نقداً.** الخصم حملة
-- تسويقية نتحمّلها نحن، لا تخفيضٌ لحصة السائق. فحساب رحلة بألف وخصم ٢٥٪:
--
--   الراكب يدفع نقداً        750
--   عمولتنا (١٥٪ من 1000)    150  ← دَين على السائق كالعادة
--   تعويض الخصم             +250  ← يدخل محفظته
--   ──────────────────────────────
--   صافي ما ناله السائق      850  = تماماً كرحلة بلا كوبون
--
-- وتكلفة الحملة علينا ٢٥٠ ديناراً، وهي رقم نعرفه ونقيسه.
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

  v_dist := coalesce(p_actual_distance_m, v_trip.estimated_distance_m);
  v_dur  := coalesce(
    p_actual_duration_s,
    extract(epoch from (now() - v_trip.started_at))::integer,
    v_trip.estimated_duration_s
  );

  v_zone := public.zone_for_point(v_trip.pickup_location);
  v_fare := public.calculate_fare(v_zone, v_dist, v_dur, v_trip.surge_multiplier);

  -- الخصم محسوب على تقدير الطلب. **لا نعيد حسابه على الأجرة النهائية:**
  -- الراكب رأى رقماً ووافق عليه، وتغييره بعد الركوب خيانة للتوقّع.
  -- ونحرسه من تجاوز الأجرة كي لا يصير الراكب دائناً لنا.
  v_disc := least(coalesce(v_trip.discount_iqd, 0),
                  (v_fare ->> 'total')::numeric);

  update public.trips
  set status             = 'completed',
      actual_distance_m  = v_dist,
      actual_duration_s  = v_dur,
      fare_final_iqd     = (v_fare ->> 'total')::numeric,
      commission_iqd     = (v_fare ->> 'commission')::numeric,
      driver_earning_iqd = (v_fare ->> 'driver_earning')::numeric,
      discount_iqd       = v_disc,
      fare_breakdown     = v_fare,
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

  -- قيد العمولة كدين على السائق (سالب)
  perform public.post_wallet_transaction(
    p_driver_id   => v_trip.driver_id,
    p_txn_type    => 'commission',
    p_amount_iqd  => -v_trip.commission_iqd,
    p_trip_id     => v_trip.id,
    p_description => format('عمولة الرحلة رقم %s', v_trip.trip_number)
  );

  -- تعويض الخصم: ما لم يقبضه السائق نقداً يدخل محفظته
  if v_disc > 0 then
    perform public.post_wallet_transaction(
      p_driver_id   => v_trip.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_disc,
      p_trip_id     => v_trip.id,
      p_description => format('تعويض خصم كوبون — رحلة %s', v_trip.trip_number)
    );

    -- نسجّل الاستعمال بعد نجاح الرحلة لا عند الطلب: رحلة أُلغيت لا تستهلك
    -- كوبوناً، والراكب الذي ألغى مرة لا يُعاقب بضياع خصمه.
    insert into public.coupon_redemptions
      (coupon_id, rider_id, trip_id, discount_iqd)
    values (v_trip.coupon_id, v_trip.rider_id, v_trip.id, v_disc)
    on conflict (trip_id) do nothing;
  end if;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.check_coupon(text, numeric) from public, anon;
revoke all on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text
) from public, anon;
revoke all on function public.complete_trip(uuid, integer, integer)
  from public, anon;

grant execute on function public.check_coupon(text, numeric) to authenticated;
grant execute on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text
) to authenticated;
grant execute on function public.complete_trip(uuid, integer, integer)
  to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select key as "الإعداد", value as "القيمة", label as "الاسم"
from public.public_settings
order by key;
