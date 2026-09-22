set search_path = public, extensions;

-- =============================================================================
-- 0019 — طرفا الرحلة يتعارفان: صورة، ولوحة، ولون
-- =============================================================================
-- الأساس الأمني كان مبنياً منذ 0007: العرض `trip_party_info` يكشف الحقول
-- الآمنة وحدها، والهاتف أثناء الرحلة النشطة فقط. لكن ثلاثة أشياء كانت
-- ناقصة **من الجذر لا من الواجهة**:
--
--   ١) `profiles.avatar_url` عمود موجود، والعرض يكشفه، والشاشات تتجاهله —
--      **ولا سطر في المشروع يكتب فيه قيمة.** الصورة الحية تُخزَّن وثيقةَ
--      هوية في مخزن خاص، ولا أحد يربطها بالملف الشخصي.
--
--   ٢) اللوحة واللون أعمدة فارغة في كل صف. كتبنا في 0003 أن "المدير
--      يملؤها وقت المراجعة"، ولم نبنِ له مكاناً يملؤها فيه. فسطر اللوحة
--      في شاشة الراكب كود ميت لا يظهر أبداً.
--
--   ٣) `vehicle_type` — الحقل الوحيد المجموع فعلاً — ليس في العرض أصلاً.
--
-- القرار: السائق يكتب اللوحة واللون عند التسجيل، والمدير يتحقق منهما
-- مقابل صور الدراجة عند الاعتماد. أدقّ من ترك المدير يقرأ كل لوحة من
-- صورة، وأسرع من انتظاره.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) التسجيل يلتقط اللوحة واللون
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  requested_role public.user_role;
  v_full_name text;
  v_phone     text;
  v_address   text;
  v_dob       date;
  v_age       integer;
begin
  requested_role := coalesce(
    nullif(new.raw_user_meta_data ->> 'role', '')::public.user_role,
    'rider'
  );

  v_full_name := btrim(new.raw_user_meta_data ->> 'full_name');
  v_phone     := nullif(btrim(new.raw_user_meta_data ->> 'phone'), '');
  v_address   := nullif(btrim(new.raw_user_meta_data ->> 'address'), '');
  v_dob       := (nullif(new.raw_user_meta_data ->> 'date_of_birth', ''))::date;

  if v_full_name is null or v_full_name = '' then
    raise exception 'الاسم الكامل مطلوب للتسجيل';
  end if;

  if array_length(regexp_split_to_array(v_full_name, '\s+'), 1) < 3 then
    raise exception 'الاسم الثلاثي مطلوب: الاسم واسم الأب واسم الجد';
  end if;

  if v_phone is null then
    raise exception 'رقم الهاتف مطلوب للتسجيل';
  end if;

  if v_address is null then
    raise exception 'العنوان مطلوب للتسجيل';
  end if;

  if v_dob is null then
    raise exception 'تاريخ الميلاد مطلوب للتسجيل';
  end if;

  v_age := extract(year from age(current_date, v_dob))::integer;
  if requested_role = 'driver' and v_age < 18 then
    raise exception 'العمر الأدنى لتسجيل السائق ١٨ سنة';
  elsif v_age < 16 then
    raise exception 'العمر الأدنى للتسجيل ١٦ سنة';
  end if;

  if exists (select 1 from public.profiles where phone = v_phone) then
    raise exception 'رقم الهاتف مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;
  if exists (select 1 from public.profiles where full_name = v_full_name) then
    raise exception 'الاسم مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;

  insert into public.profiles (
    id, full_name, email, date_of_birth, address, phone, role, locale
  )
  values (
    new.id,
    v_full_name,
    new.email,
    v_dob,
    v_address,
    v_phone,
    requested_role,
    coalesce(nullif(new.raw_user_meta_data ->> 'locale', ''), 'ar')
  );

  -- **التغيير:** اللوحة واللون معهما. يبقيان اختياريين في المخطط —
  -- غيابهما لا يمنع الاعتماد، والمدير يصحّحهما من صور الدراجة.
  if requested_role = 'driver' then
    insert into public.drivers (id, vehicle_type, vehicle_plate, vehicle_color)
    values (
      new.id,
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_type'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_plate'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_color'), '')
    );
  end if;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الصورة الحية تصير صورة الملف الشخصي
-- -----------------------------------------------------------------------------
-- **لماذا مُشغّل لا كتابة من التطبيق؟** لأن الصورة تُرفع من ثلاثة مسارات
-- (تسجيل الراكب، تسجيل السائق، إعادة رفع وثيقة مرفوضة)، ونسيان أحدها
-- يترك مستخدمين بلا صورة بلا سبب ظاهر. المُشغّل يلتقطها من مصدر واحد.
--
-- نخزّن **المسار** لا رابطاً كاملاً: المخزن خاص، والقراءة برابط موقّع
-- قصير الأجل يُولّده التطبيق عند العرض.
create or replace function public.sync_avatar_from_selfie()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.doc_type = 'live_selfie' then
    update public.profiles
    set avatar_url = new.storage_path
    where id = new.user_id;
  end if;
  return new;
end;
$fn$;

drop trigger if exists user_documents_sync_avatar on public.user_documents;
create trigger user_documents_sync_avatar
  after insert or update of storage_path on public.user_documents
  for each row execute function public.sync_avatar_from_selfie();

-- من سجّل قبل اليوم له صورة حية ولا `avatar_url`. نملؤها بأحدث صورة له.
update public.profiles p
set avatar_url = d.storage_path
from (
  select distinct on (user_id) user_id, storage_path
  from public.user_documents
  where doc_type = 'live_selfie'
  order by user_id, created_at desc
) d
where d.user_id = p.id and p.avatar_url is null;


-- -----------------------------------------------------------------------------
-- ٣) الطرف الآخر يقرأ صورتك أثناء الرحلة النشطة وحدها
-- -----------------------------------------------------------------------------
-- كتبنا في 0010: "لا أحد غيرهما — حتى طرفا الرحلة لا يريان صور بعضهما".
-- كان ذلك صحيحاً حين كانت الوثائق كلها سواء. الآن نفتح **الصورة الحية
-- وحدها**، **لطرف الرحلة وحده**، **أثناء نشاطها وحده**. البطاقة الوطنية
-- وصور الدراجة تبقى محجوبة كما كانت.
--
-- شرط `like '%/live_selfie_%'` يحصر السياسة بنوع واحد من الملفات، واصطلاح
-- المسار من 0010 يضمن أن الجزء الأول هو معرّف صاحب الصورة.
drop policy if exists "documents: صورة الطرف الآخر أثناء الرحلة" on storage.objects;
create policy "documents: صورة الطرف الآخر أثناء الرحلة"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documents'
    and name like '%/live_selfie_%'
    and exists (
      select 1 from public.trips t
      where t.status in ('accepted', 'driver_arrived', 'in_progress')
        and (
          (t.rider_id  = auth.uid()
             and t.driver_id::text = (storage.foldername(name))[1])
          or
          (t.driver_id = auth.uid()
             and t.rider_id::text  = (storage.foldername(name))[1])
        )
    )
  );


-- -----------------------------------------------------------------------------
-- ٤) العرض يكشف نوع الدراجة كذلك
-- -----------------------------------------------------------------------------
-- **نحذف قبل الإنشاء لا `create or replace`:** الأخير لا يقبل إلا إضافة
-- أعمدة في النهاية، ونحن ندسّ `vehicle_type` بين الأعمدة القائمة ليقرأ
-- التعريف مرتّباً. الحذف يُسقط الصلاحيات معه، فنعيد منحها أدناه.
drop view if exists public.trip_party_info;

create view public.trip_party_info
with (security_barrier = true)
as
select
  t.id   as trip_id,
  p.id   as person_id,
  case when p.id = t.driver_id then 'driver' else 'rider' end as party,

  p.full_name,
  p.avatar_url,

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
  'الحقول الآمنة فقط عن طرفي الرحلة. لا يكشف رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.profiles where avatar_url is not null)
    as "ملفات لها صورة",
  (select count(*) from public.profiles) as "مجموع الملفات",
  (select count(*) from public.drivers where vehicle_plate is not null)
    as "سائقون لهم لوحة";
