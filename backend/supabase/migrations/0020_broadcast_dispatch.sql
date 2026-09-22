set search_path = public, extensions;

-- =============================================================================
-- 0020 — البثّ المتوازي: خمسة سائقين معاً، وأولهم قبولاً يفوز
-- =============================================================================
-- المحرك حتى الآن **تسلسلي**: عرض واحد لسائق واحد، وانتظار ردّه قبل
-- الانتقال للتالي. مع مهلة ٤٥ ثانية يعني هذا أن ثالث أقرب سائق لا يرى
-- الطلب قبل دقيقة ونصف — والراكب واقف ينتظر.
--
-- الجديد: **بثّ متوازي** للأقرب فالأقرب. خمسة يرون الطلب معاً، وأولهم
-- قبولاً يأخذه، ومن يرفض يُستبدل فوراً بالسادس فيبقى العدد خمسة.
--
-- =============================================================================
-- **ثغرة كُشفت أثناء كتابة هذا الملف: `unique (trip_id, driver_id)`.**
--
-- القيد كُتب في 0004 بتعليق "لا نعرض نفس الرحلة على نفس السائق مرتين"،
-- وكان صحيحاً حينها. ثم كتبنا في 0017 منطق **الجولات المتكررة** — يعيد
-- العرض على من رفض بعد مدة — دون أن ننتبه أن القيد يمنعه.
--
-- الأثر: محاولة إعادة العرض ترفع `unique_violation`، فتُجهض حلقة
-- `dispatch_tick` كلها. أي أن الجولة الثانية **لم تعمل يوماً**، وما ظننّاه
-- "بحثاً مستمراً" كان جولة واحدة ثم صمت حتى تنتهي العشر دقائق.
--
-- البديل: فهرس فريد **جزئي** يمنع عرضين معلّقين في آنٍ واحد على السائق
-- نفسه لنفس الرحلة، ويسمح بعرض جديد بعد أن يُحسم الأول.
-- =============================================================================

alter table public.trip_offers
  drop constraint if exists trip_offers_trip_id_driver_id_key;

drop index if exists public.trip_offers_one_pending_idx;
create unique index trip_offers_one_pending_idx
  on public.trip_offers (trip_id, driver_id)
  where status = 'pending';


-- -----------------------------------------------------------------------------
-- ١) ضوابط البثّ — في المنطقة لا في الكود
-- -----------------------------------------------------------------------------
alter table public.pricing_zones
  add column if not exists max_concurrent_offers smallint not null default 5,
  add column if not exists offer_round_seconds   integer  not null default 60;

comment on column public.pricing_zones.max_concurrent_offers is
  'كم سائقاً يرى الطلب في آنٍ واحد. أولهم قبولاً يفوز.';

comment on column public.pricing_zones.offer_round_seconds is
  'بعد كم ثانية يُعاد عرض الرحلة على سائق رفضها أو أهملها.';


-- -----------------------------------------------------------------------------
-- ٢) الإرسال: نملأ المقاعد الخمسة بدل مقعد واحد
-- -----------------------------------------------------------------------------
-- نُبقي الاسم `dispatch_next_offer` لأن `reject_trip_offer` تستدعيه —
-- فرفض السائق يملأ مقعده فوراً بالسادس دون انتظار النبضة التالية.
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
  v_sent      integer;      -- كم عرضاً أُرسل لهذه الرحلة إجمالاً (لتوسيع النطاق)
  v_live      integer;      -- كم عرضاً معلّقاً الآن
  v_need      integer;      -- كم مقعداً شاغراً
  v_radius    integer;
  v_candidate record;
  v_offer     public.trip_offers;
  v_elapsed   integer;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;   -- الرحلة قُبلت أو أُلغيت بينما كنا نبحث
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  -- هل تجاوزنا مهلة البحث الكلية؟
  v_elapsed := extract(epoch from (now() - v_trip.requested_at))::integer;
  if v_elapsed > v_zone.max_search_seconds then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  -- المقاعد المشغولة الآن
  select count(*) into v_live
  from public.trip_offers
  where trip_id = p_trip_id and status = 'pending' and expires_at > now();

  v_need := v_zone.max_concurrent_offers - v_live;
  if v_need <= 0 then
    return null;   -- الخمسة ممتلئة — ننتظر ردّاً أو انتهاء مهلة
  end if;

  -- السائقون المستبعدون **في الجولة الحالية**: من عُرضت عليه الرحلة خلال
  -- آخر `offer_round_seconds`. بعدها يعود إلى المنافسة — قد يكون فرغ،
  -- أو اقترب.
  select coalesce(array_agg(driver_id), array[]::uuid[])
  into v_tried
  from public.trip_offers
  where trip_id = p_trip_id
    and sent_at > now() - make_interval(secs => v_zone.offer_round_seconds);

  select count(*) into v_sent
  from public.trip_offers where trip_id = p_trip_id;

  -- توسيع النطاق تدريجياً كلما طال البحث
  v_radius := least(
    v_zone.search_radius_m * (1 + (v_sent / 5)),
    v_zone.max_search_radius_m
  );

  -- **الأقرب فالأقرب:** find_nearby_drivers ترتّب بالمسافة، فأول من نُدخله
  -- هو الأقرب. مع البثّ المتوازي يبقى الترتيب مهماً في `rank` وحده —
  -- الخمسة يرون الطلب في اللحظة نفسها.
  for v_candidate in
    select * from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried
    )
  loop
    insert into public.trip_offers
      (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
    values (
      p_trip_id,
      v_candidate.driver_id,
      v_sent + 1,
      v_candidate.distance_m,
      (v_candidate.distance_m / 6.9)::integer,
      now() + make_interval(secs => v_zone.offer_timeout_s)
    )
    -- سباق: نبضتان متزامنتان قد تختاران السائق نفسه. الفهرس الجزئي
    -- يمنع التكرار، وهذا يمنع الاستثناء من إجهاض الحلقة.
    on conflict do nothing
    returning * into v_offer;

    v_sent := v_sent + 1;
  end loop;

  return v_offer;   -- آخر عرض أُنشئ، أو null إن لم يوجد مرشّح
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) العامل الدوري يبقى كما هو منطقاً، ونعيد تعريفه للتوثيق فقط
-- -----------------------------------------------------------------------------
-- لا تغيير في جسده: ينهي المنتهي، ويفصل السائق الشبح، ويستدعي الإرسال
-- لكل رحلة تبحث. الفرق أن الاستدعاء صار يملأ خمسة مقاعد لا مقعداً.


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar             as "المنطقة",
  max_concurrent_offers    as "عروض متزامنة",
  offer_timeout_s          as "مهلة العرض (ث)",
  offer_round_seconds      as "العودة بعد (ث)"
from public.pricing_zones
order by city_name_ar;
