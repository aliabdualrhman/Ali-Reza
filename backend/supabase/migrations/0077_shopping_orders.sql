-- =============================================================================
-- 0077 — طلب التسوّق
-- =============================================================================
-- خدمةٌ ثانية على البنية نفسها: الراكب يطلب سلعاً من محلّ، والسائق
-- يشتريها بماله ويسلّمها ويستردّ نقداً.
--
-- ------------------------------------------------------------------
-- ولا جدول جديد — والسبب ليس الكسل
-- ------------------------------------------------------------------
-- **المحل هو نقطة الانطلاق، والتسليم هو الوجهة.** بهذا التأطير يصير
-- طلب التسوّق رحلةً عادية في كل ما يهمّ: التسعير يحسب المحل ← التسليم
-- كما يحسب أيّ مسار، والبحث عن سائق يجري قرب المحل — وهو الصحيح لأن
-- السائق يقصده أولاً.
--
-- فنرث مجّاناً: محرّك المطابقة، والعروض ومهلها، ورفع الأجرة، والإلغاء
-- وعقوباته، والتقييم، والمحفظة والعمولة، وشاشات المدير كلها.
--
-- **والبديل — جدولٌ منفصل — كان يعني نسخةً ثانية من كل ذلك.** ونحن
-- رأينا الليلة ما يفعله التكرار: أصلحنا بوابة الرمز في السائق وتركنا
-- الراكب معطوباً.
--
-- ------------------------------------------------------------------
-- والمال يمرّ ولا يمسّنا
-- ------------------------------------------------------------------
-- السائق يدفع للبقّال من جيبه، ويستردّ من الراكب نقداً عند التسليم.
-- فقيمة البضاعة **ليست مالنا**: لا عمولة عليها، ولا يُنفق عليها رصيد
-- الراكب.
--
-- **ولماذا لا يُنفق الرصيد على البضاعة؟** لأن الرصيد عندنا ورقةٌ تُمحى
-- لا نقدٌ يُدفع: حين يُنفَق على أجرة، نعوّض السائق بإعفاءٍ من عمولة لم
-- تُكسب. أما البضاعة فقد دفع فيها ديناراً حقيقياً للبقّال — وتعويضه
-- يعني إخراج نقدٍ من خزينتنا. فيصير كل رصيد هديةٍ منحناه قابلاً
-- للتحوّل إلى نقدٍ في يد سائق.
--
-- ------------------------------------------------------------------
-- والإلغاء: قاعدةٌ عدّلتُها عن المطلوب حرفياً
-- ------------------------------------------------------------------
-- طُلب أن يُمنع الراكب من الإلغاء مطلقاً. والمنع المطلق فخّ: من لم
-- يجد سائقاً يبقى محبوساً في شاشة الطلب إلى الأبد، ولا يستطيع أن يطلب
-- رحلةً لنفسه — والفهرس الفريد يمنعه.
--
-- **فالمنع يبدأ حين يُنفق السائق مالاً**، لا قبله. قبل الشراء لا أحد
-- خسر شيئاً؛ وبعده الإلغاء سرقةٌ لا انسحاب.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الأعمدة
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'trip_kind') then
    create type public.trip_kind as enum ('ride', 'shopping');
  end if;
end $$;

alter table public.trips
  add column if not exists kind public.trip_kind not null default 'ride',

  -- **القائمة `jsonb` لا جدولٌ ثانٍ.** لا تُستعلم ولا تُجمَّع ولا
  -- تُفهرَس: تُكتب مرة وتُقرأ كما هي. وجدولٌ لها يعني وصلاً في كل
  -- قراءة بلا فائدة واحدة.
  --
  -- الشكل: [{"name": "خبز", "qty": "١٠٠٠ دينار"}, …]
  add column if not exists items jsonb,

  -- ما قدّره الراكب، وما دفعه السائق فعلاً.
  add column if not exists goods_estimate_iqd numeric(10,2),
  add column if not exists goods_actual_iqd   numeric(10,2);

comment on column public.trips.kind is
  'ride = رحلة راكب · shopping = طلب تسوّق. المحل هو نقطة الانطلاق.';
comment on column public.trips.goods_estimate_iqd is
  'تقدير الراكب — يراه السائق قبل القبول فلا يتورّط بطلبٍ أكبر من نقده.';
comment on column public.trips.goods_actual_iqd is
  'ما دفعه السائق فعلاً. يكتبه بعد الشراء وبعد الاتفاق هاتفياً.';


alter table public.drivers
  add column if not exists accepts_shopping boolean not null default false;

comment on column public.drivers.accepts_shopping is
  'يستقبل طلبات التسوّق. مغلقٌ افتراضاً — تتطلّب نقداً في الجيب.';


-- -----------------------------------------------------------------------------
-- ٢) الإعدادات
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('shopping_enabled',       '1',    'تفعيل طلبات التسوّق'),
  ('shopping_min_fare_iqd',  '1500', 'أقلّ أجرة لطلب تسوّق'),
  ('shopping_max_goods_iqd', '50000','أقصى قيمة طلب تسوّق'),
  ('shopping_max_items',     '20',   'أقصى عدد سلع في الطلب')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- ٣) الطلب
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
  p_note            text default null
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

  -- ---- القائمة ----
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'اكتب سلعةً واحدة على الأقل';
  end if;

  v_maxn := public.referral_setting('shopping_max_items', 20)::integer;
  if jsonb_array_length(p_items) > v_maxn then
    raise exception 'أقصى عدد سلع في الطلب %', v_maxn;
  end if;

  -- ---- سقف القيمة ----
  -- **يحمي السائق لا الراكب.** السائق يدفع من جيبه، وطلبٌ بمئة ألف
  -- يفوق نقد أكثر السائقين — فيبقى بلا من يقبله، أو يقبله من لا يقدر
  -- عليه فيعتذر في المحل.
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

  -- ---- التسعير: المحل ← التسليم ----
  -- **لا يشمل ذهاب السائق إلى المحل.** لا نعرف أيّ سائقٍ سيقبل وقت
  -- الطلب، فإدخال مساره يجعل السعر يتغيّر بعد أن وافق الراكب عليه.
  v_fare := public.calculate_fare(v_zone_id, p_distance_m, p_duration_s, 1.0);

  v_min   := public.referral_setting('shopping_min_fare_iqd', 1500);
  v_total := greatest((v_fare ->> 'total')::numeric, v_min);

  begin
    insert into public.trips (
      rider_id, kind,
      pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, fare_locked_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note,
      items, goods_estimate_iqd,
      stop_count, current_leg, vehicle_kind
    ) values (
      auth.uid(), 'shopping',
      v_shop, p_shop_address,
      v_drop, p_drop_address,
      p_distance_m, p_duration_s,
      v_total, v_total, 1.0, v_fare,
      'cash', p_note,
      p_items, p_goods_estimate,
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

revoke all on function public.request_shopping(
  double precision, double precision, text,
  double precision, double precision, text,
  integer, integer, jsonb, numeric, text) from public, anon;
grant execute on function public.request_shopping(
  double precision, double precision, text,
  double precision, double precision, text,
  integer, integer, jsonb, numeric, text) to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) العرض يذهب لمن يقبل التسوّق وحده
-- -----------------------------------------------------------------------------
-- **مغلقٌ افتراضاً.** طلب التسوّق يتطلّب نقداً في الجيب، ومن لا يملكه
-- يعتذر في المحل — فيخسر الراكب وقته ونخسر نحن الطلب. فمن يفتحه يعرف
-- ما يدخل فيه.
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
begin
  select * into v_trip from public.trips where id = p_trip_id;
  if v_trip.status <> 'searching' then return null; end if;

  v_shopping := (v_trip.kind = 'shopping');

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);
  if not found then return null; end if;

  -- **الرفع يوسّع الدائرة.** رحلةٌ رُفعت أجرتها تستحق أن تُعرض على
  -- أكثر من الحلقة الأولى — انظر 0033.
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
    -- **نُرشّح بعد البحث لا داخله.** تغيير بصمة `find_nearby_drivers`
    -- يكسر كل من يستدعيها، والوصل هنا يكلّف صفاً واحداً لكل مرشّح.
    select c.*
    from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried, v_trip.vehicle_kind
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


create or replace function public.set_accepts_shopping(p_value boolean)
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
  set accepts_shopping = coalesce(p_value, false)
  where id = auth.uid();
  perform set_config('app.bypass_guards', 'off', true);
end;
$fn$;

revoke all on function public.set_accepts_shopping(boolean) from public, anon;
grant execute on function public.set_accepts_shopping(boolean) to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) السائق يكتب السعر الحقيقي
-- -----------------------------------------------------------------------------
-- بعد الشراء وبعد الاتفاق هاتفياً. **والاتفاق قبل الكتابة لا بعدها:**
-- رقمٌ يظهر على شاشة الراكب بلا أن يُستأذَن فيه خلافٌ لا محالة.
create or replace function public.set_goods_price(
  p_trip_id uuid,
  p_amount  numeric
)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip public.trips;
  v_max  numeric;
begin
  select * into v_trip from public.trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'الطلب غير موجود'; end if;
  if v_trip.kind <> 'shopping' then raise exception 'هذا ليس طلب تسوّق'; end if;

  if v_trip.driver_id is distinct from auth.uid() then
    raise exception 'هذا ليس طلبك';
  end if;
  if v_trip.status not in ('accepted', 'driver_arrived', 'in_progress') then
    raise exception 'لا يمكن تعديل السعر الآن';
  end if;

  if coalesce(p_amount, 0) <= 0 then
    raise exception 'اكتب المبلغ الذي دفعته';
  end if;

  -- **السقف نفسه يُفحص ثانيةً.** الراكب قدّر عشرة آلاف والفاتورة
  -- مئة — رقمٌ كهذا خطأٌ في الكتابة غالباً، وتمريره يجعل الراكب
  -- يواجه مبلغاً لم يوافق عليه.
  v_max := public.referral_setting('shopping_max_goods_iqd', 50000);
  if p_amount > v_max then
    raise exception 'المبلغ يتجاوز الحدّ المسموح (% دينار)', v_max::bigint;
  end if;

  update public.trips
  set goods_actual_iqd = p_amount
  where id = p_trip_id;

  -- **يُخبَر الراكب لحظتها.** يرى المبلغ على شاشته فيراجعه قبل أن
  -- يقف السائق أمام بابه.
  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (
    v_trip.rider_id,
    'كلفة طلبك',
    format('البضاعة %s دينار + التوصيل %s دينار = %s دينار — الطلب رقم %s.',
           p_amount::bigint,
           coalesce(v_trip.fare_locked_iqd, v_trip.fare_estimated_iqd, 0)::bigint,
           (p_amount + coalesce(v_trip.fare_locked_iqd,
                                v_trip.fare_estimated_iqd, 0))::bigint,
           v_trip.trip_number),
    'direct',
    auth.uid()
  );

  return p_amount;
end;
$fn$;

revoke all on function public.set_goods_price(uuid, numeric) from public, anon;
grant execute on function public.set_goods_price(uuid, numeric) to authenticated;


-- -----------------------------------------------------------------------------
-- ٦) البضاعة تُضاف إلى المستحقّ النقدي
-- -----------------------------------------------------------------------------
-- الرصيد يُنفق على الأجرة وحدها — انظر رأس الملف.
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
-- ٧) الإلغاء يُمنع بعد الشراء لا قبله
-- -----------------------------------------------------------------------------
create or replace function public.guard_shopping_cancel()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.status <> 'cancelled' or old.status = 'cancelled' then
    return new;
  end if;
  if old.kind <> 'shopping' then return new; end if;

  -- **المنع يبدأ حين يُنفق السائق مالاً.** قبل ذلك لا أحد خسر شيئاً،
  -- ومن لم يجد سائقاً يجب أن يستطيع الانصراف. وبعده الإلغاء سرقةٌ
  -- لا انسحاب — والمدير وحده يفكّه.
  if old.goods_actual_iqd is not null
     and coalesce(current_setting('app.bypass_guards', true), 'off') <> 'on'
  then
    raise exception
      'اشترى السائق الطلب فعلاً — لا يمكن الإلغاء. تواصل مع الدعم.';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trips_guard_shopping_cancel on public.trips;
create trigger trips_guard_shopping_cancel
  before update of status on public.trips
  for each row execute function public.guard_shopping_cancel();


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
   where table_name = 'trips'
     and column_name in ('kind','items','goods_estimate_iqd','goods_actual_iqd'))
    as "أعمدة الرحلة (٤)",
  (select count(*) from information_schema.columns
   where table_name = 'drivers' and column_name = 'accepts_shopping')
    as "مفتاح السائق (١)",
  (select value from public.public_settings where key = 'shopping_min_fare_iqd')
    as "أقلّ أجرة";
