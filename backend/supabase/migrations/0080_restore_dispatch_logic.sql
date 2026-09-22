-- =============================================================================
-- 0080 — استعادة منطق التوزيع، ومفتاحٌ لطلبات الركّاب
-- =============================================================================
-- ملفٌّ فيه أمران: إصلاح عطلٍ أحدثتُه، ومفتاحٌ جديد.
--
-- ------------------------------------------------------------------
-- الجديد: `accepts_rides`
-- ------------------------------------------------------------------
-- كان «الاتصال» يعني قبول الركّاب ضمناً، ثم أضفنا التسوّق فصار المعنى
-- ملتبساً: زرٌّ كبير مكتوبٌ عليه «ابدأ الاستقبال» لا يقول أيّ استقبال،
-- ومفتاحٌ صغير للتسوّق تحته — فيظنّ السائق أن الكبير يحكم الصغير.
--
-- **فصارا مفتاحين متساويين، والاتصال نتيجتهما لا سببهما:** من فتح
-- واحداً منهما فهو متصل، ومن أغلقهما فهو غير متصل. لا زرَّ ثالثاً
-- يحكمهما.
--
-- ------------------------------------------------------------------
-- والإصلاح
-- ------------------------------------------------------------------
-- **خطأٌ خطير مني في 0077 ثم 0079.** أردتُ إضافة سطرٍ واحد إلى
-- `dispatch_next_offer` (ترشيح من يقبل التسوّق)، فأعدتُ كتابة الدالة
-- كلها من الذاكرة بدل أن أقرأ أصلها في 0033. فضاع منها أربعة أشياء:
--
--   ١. **`for update`** — القفل الذي يمنع عرضَين متوازيين على الرحلة
--      نفسها حين يعمل `dispatch_tick` والراكب يطلب في اللحظة ذاتها.
--
--   ٢. **`max_search_seconds`** — الرحلة التي طال بحثها تُعلَّم
--      `no_drivers`. وبلا هذا تبقى «تبحث» إلى الأبد، والراكب ينتظر
--      شاشةً لا تنتهي ولا يستطيع طلب غيرها.
--
--   ٣. **حساب المقاعد** — العدد المطلوب هو `المقاعد − العروض الحيّة`،
--      لا رقمٌ ثابت. كتبتُ `5` و`10` من رأسي، فصار كل نداءٍ يفتح خمسة
--      عروضٍ جديدة فوق القائمة — وسائقٌ واحد قد يتلقّى الطلب مرّاتٍ.
--
--   ٤. **`offer_round_seconds`** — نافذة «من جُرّب في هذه الجولة».
--      استبدلتُها بـ`requested_at`، فصار من رُفض عليه العرض مرةً لا
--      يُعرض عليه أبداً ولو مرّت جولات.
--
--   وفوق ذلك: `fare_boost_iqd` **عمودٌ لا وجود له** — اسمه
--   `fare_boost_pct`. وهو ما أنتج `42703` وأوقف طلبات التسوّق كلها.
--
-- **والدرس مكتوبٌ هنا لا في رأسي:** من يعدّل دالةً قائمة يقرؤها كاملةً
-- أولاً. و`create or replace` لا تشتكي حين تُسقط نصف المنطق.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) مفتاح طلبات الركّاب
-- -----------------------------------------------------------------------------
-- **مفتوحٌ افتراضاً، بخلاف التسوّق.** نقل الركّاب هو العمل الأصلي وكل
-- سائقٍ مسجَّلٌ من أجله؛ وإغلاقه افتراضاً كان يقطع الرزق عن الجميع في
-- لحظة الترحيل.
alter table public.drivers
  add column if not exists accepts_rides boolean not null default true;

comment on column public.drivers.accepts_rides is
  'يستقبل طلبات نقل الركّاب. مفتوحٌ افتراضاً — وهو العمل الأصلي.';


create or replace function public.set_accepts_rides(p_value boolean)
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
  set accepts_rides = coalesce(p_value, false)
  where id = auth.uid();
  perform set_config('app.bypass_guards', 'off', true);
end;
$fn$;

revoke all on function public.set_accepts_rides(boolean) from public, anon;
grant execute on function public.set_accepts_rides(boolean) to authenticated;


-- -----------------------------------------------------------------------------
-- ٢) التوزيع — الأصل كما هو، ومرشّحان
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
  v_seats     integer;
  v_radius    integer;
  v_since     timestamptz;
  v_candidate record;
  v_offer     public.trip_offers;
  v_elapsed   integer;
  v_shopping  boolean;
  v_kind      public.vehicle_kind;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;
  end if;

  -- ---- الإضافة الوحيدة على منطق 0033 ----
  -- **طلب التسوّق لا يُرشَّح بالمركبة.** دراجةً كان السائق أو تكتكاً،
  -- ما دام فتح مفتاح التسوّق — والسعر سعر الدراجة في الحالين.
  v_shopping := (v_trip.kind = 'shopping');
  v_kind := case when v_shopping then null else v_trip.vehicle_kind end;

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
    where case when v_shopping then d.accepts_shopping else d.accepts_rides end
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
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
-- يجب أن تعود صفراً: لا ذكر لعمودٍ لا وجود له.
select
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'dispatch_next_offer'
     and prosrc like '%fare_boost_iqd%')      as "إشارات وهمية (يجب ٠)",
  (select count(*) from information_schema.columns
   where table_name = 'drivers'
     and column_name in ('accepts_rides', 'accepts_shopping'))
                                              as "مفاتيح السائق (يجب ٢)";
