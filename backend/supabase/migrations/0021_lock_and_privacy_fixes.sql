set search_path = public, extensions;

-- =============================================================================
-- 0021 — العامل الدوري كان يقفل الرحلات دقيقةً كاملة
-- =============================================================================
-- **رمز الخطأ 57014 هو `query_canceled` — انتهاء مهلة الاستعلام.** ظهر
-- للراكب حين حاول إلغاء طلبه، وللسائق حين حاول القبول. ولم يكن سببه
-- بطء الشبكة ولا ضعف الخادم، بل قفلٌ نضعه نحن.
--
-- **السبب:** `dispatch_minute` تدور اثنتي عشرة مرة مع `pg_sleep(5)` بينها،
-- وكل ذلك **داخل معاملة واحدة**. و`dispatch_next_offer` تبدأ بـ
-- `select * from trips ... for update`. فقفل صفّ الرحلة يبقى محجوزاً
-- **حتى نهاية الدقيقة كلها** لا حتى نهاية النبضة.
--
-- فأي محاولة من الراكب أو السائق لتعديل تلك الرحلة تصطف خلف القفل، وحدّ
-- المهلة في Supabase ثماني ثوانٍ، فتُقتل ويظهر 57014.
--
-- كتبتُ في 0017 تعليقاً يقول إن `pg_sleep` هنا "لا تحجب أحداً". كان خطأً
-- صريحاً: هي لا تحجب اتصالاً آخر، لكنها تُبقي معاملةً مفتوحة تحمل أقفالاً.
--
-- **الحل:** إجراء (procedure) لا دالة. الإجراء وحده يستطيع `commit` في
-- منتصفه، فينتهي القفل مع كل نبضة بدل أن يمتدّ دقيقة.
-- =============================================================================

-- الدالة القديمة تُحذف: لا يجوز بقاء نسخة تُستدعى سهواً.
drop function if exists public.dispatch_minute();

create or replace procedure public.dispatch_minute()
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  i integer;
begin
  for i in 1..12 loop
    perform public.dispatch_tick();

    -- **هنا الإصلاح.** الإفلات من المعاملة يُطلق كل أقفال هذه النبضة،
    -- فيجد الراكبُ رحلته حرّةً ليلغيها والسائقُ ليقبلها.
    commit;

    if i < 12 then perform pg_sleep(5); end if;
  end loop;
end;
$fn$;

-- pg_cron ينفّذ نصاً حرفياً، و`call` هي ما يسمح للإجراء بأن يعمل خارج
-- معاملة محيطة — و`select` لا تفعل. تغيير الجدولة جزء من الإصلاح لا
-- تفصيل شكلي.
select cron.unschedule('zanbour-dispatch')
where exists (select 1 from cron.job where jobname = 'zanbour-dispatch');

select cron.schedule(
  'zanbour-dispatch',
  '* * * * *',
  $cron$ call public.dispatch_minute(); $cron$
);


-- -----------------------------------------------------------------------------
-- ٢) رسائل القبول تقول الحقيقة
-- -----------------------------------------------------------------------------
-- كانت كل حالة ليست `searching` تُترجم إلى "سبقك سائق آخر". فالرحلة التي
-- ألغاها الراكب، والتي استسلم البحث فيها بعد عشر دقائق، تُنسَبان إلى سائق
-- وهمي لم يوجد. السائق يظن أن المنافسة شرسة وأنه بطيء، والحقيقة غير ذلك.
create or replace function public.accept_trip_offer(p_offer_id uuid)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_offer public.trip_offers;
  v_trip  public.trips;
begin
  select * into v_offer from public.trip_offers where id = p_offer_id;
  if not found then
    raise exception 'العرض غير موجود';
  end if;

  if v_offer.driver_id <> auth.uid() then
    raise exception 'هذا العرض ليس لك' using errcode = 'insufficient_privilege';
  end if;

  if v_offer.status <> 'pending' then
    raise exception 'انتهت صلاحية هذا العرض';
  end if;

  if v_offer.expires_at < now() then
    update public.trip_offers set status = 'expired', responded_at = now()
    where id = p_offer_id;
    raise exception 'انتهت مهلة العرض';
  end if;

  -- القفل — من هنا يصطف المتنافسون
  select * into v_trip from public.trips where id = v_offer.trip_id for update;

  if v_trip.status <> 'searching' then
    update public.trip_offers set status = 'cancelled', responded_at = now()
    where id = p_offer_id;

    raise exception '%', case v_trip.status
      when 'cancelled'  then 'ألغى الراكب هذا الطلب'
      when 'no_drivers' then 'انتهت مدة البحث وأُغلق هذا الطلب'
      else 'سبقك سائق آخر لهذه الرحلة'
    end;
  end if;

  update public.trips
  set status = 'accepted', driver_id = v_offer.driver_id
  where id = v_trip.id
  returning * into v_trip;

  update public.drivers set status = 'on_trip' where id = v_offer.driver_id;

  update public.trip_offers set status = 'accepted', responded_at = now()
  where id = p_offer_id;

  -- إبطال كل العروض الأخرى المعلّقة لهذه الرحلة
  update public.trip_offers set status = 'cancelled', responded_at = now()
  where trip_id = v_trip.id and status = 'pending' and id <> p_offer_id;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) السائق لا يرى صورة الراكب — بقرار من المستخدم
-- -----------------------------------------------------------------------------
-- **نحجبها في العرض لا في الشاشة.** حذفُها من واجهة التطبيق يترك الصورة
-- تُرسَل إلى الجهاز ثم لا تُعرض — فمن يفتح استجابة الشبكة يراها. الحجب
-- هنا يعني أنها لا تغادر الخادم أصلاً.
--
-- الراكب يرى صورة سائقه: يركب خلف رجل لا يعرفه ويحتاج أن يتأكد أنه هو.
-- والسائق لا يحتاج مثل ذلك — يكفيه الاسم والهاتف.
drop view if exists public.trip_party_info;

create view public.trip_party_info
with (security_barrier = true)
as
select
  t.id   as trip_id,
  p.id   as person_id,
  case when p.id = t.driver_id then 'driver' else 'rider' end as party,

  p.full_name,

  -- صورة السائق فقط. صف الراكب يحمل null دائماً.
  case when p.id = t.driver_id then p.avatar_url else null end as avatar_url,

  -- الهاتف يُكشف أثناء الرحلة النشطة فقط. بعد انتهائها لا يبقى سبب
  -- لبقاء رقم الراكب في يد السائق.
  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end as phone,

  d.rating_avg,
  d.vehicle_type,
  d.vehicle_plate,
  d.vehicle_make,
  d.vehicle_model,
  d.vehicle_color

from public.trips t
join public.profiles p
  on p.id = t.rider_id or p.id = t.driver_id
left join public.drivers d on d.id = p.id
-- الفلتر الأمني: لا تُرجع إلا رحلات المستدعي نفسه
where t.rider_id = auth.uid() or t.driver_id = auth.uid();

comment on view public.trip_party_info is
  'الحقول الآمنة فقط عن طرفي الرحلة. صورة السائق دون الراكب، ولا يكشف '
  'رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;


-- سياسة التخزين تُضيَّق معها: الراكب يقرأ صورة سائقه، والسائق لا يقرأ
-- صورة راكبه. بلا هذا يبقى الملف نفسه قابلاً للتوقيع من طرف السائق.
drop policy if exists "documents: صورة الطرف الآخر أثناء الرحلة" on storage.objects;
create policy "documents: الراكب يرى صورة سائقه"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documents'
    and name like '%/live_selfie_%'
    and exists (
      select 1 from public.trips t
      where t.status in ('accepted', 'driver_arrived', 'in_progress')
        and t.rider_id = auth.uid()
        and t.driver_id::text = (storage.foldername(name))[1]
    )
  );


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  j.jobname   as "المهمة",
  j.schedule  as "الجدولة",
  j.command   as "الأمر"
from cron.job j
where j.jobname = 'zanbour-dispatch';
