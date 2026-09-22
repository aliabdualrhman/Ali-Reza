-- =============================================================================
-- 0050 — الخطأ 57014 في شاشة البحث
-- =============================================================================
-- **العَرَض.** كان يظهر للراكب أثناء البحث عن سائق:
--
--     PostgrestException ... code: 57014
--
-- و`57014` هو `query_canceled` — أي أن الاستعلام تجاوز `statement_timeout`
-- فأوقفته القاعدة. ليس خطأً في التطبيق ولا في الشبكة: **استعلامٌ بطيء.**
--
-- **والبطء في `trip_party_info`، وسببه سطرٌ واحد:**
--
--     join public.profiles p
--       on p.id = t.rider_id or p.id = t.driver_id
--
-- **`or` في شرط الوصل يُعطّل الفهرس.** بوستغرس يستطيع أن يقفز إلى صفٍّ
-- بمفتاحه، ولا يستطيع أن يقفز إلى «هذا **أو** ذاك» — فيتخلّى عن الفهرس
-- ويمسح `profiles` كاملاً لكل رحلة. ومع `security_barrier` لا يُدفع
-- شرط `where` إلى ما قبل الوصل، فيصير المسح على كل الرحلات لا على
-- رحلة الراكب وحدها.
--
-- **ولهذا كان يظهر ويختفي.** بعشرين ملفاً وخمسين رحلة لا يُلاحظ؛ ومع
-- النمو يتجاوز المهلة فجأةً. وهو يسوء بالتربيع لا بالتناسب — أي أنه
-- كان سيصير دائماً بعد الإطلاق لا متقطّعاً.
--
-- **الحل: فرعان مفهرسان بدل وصلٍ واحد أعمى.** كل فرع يصل بمساواةٍ
-- بسيطة يقرؤها المخطِّط، ويجمعهما `union all` بلا تكرار — فالراكب ليس
-- سائق رحلته أبداً.
--
-- **ونفس النتيجة بالضبط**: الأعمدة والترتيب والصلاحيات كما هي، ولا
-- يحتاج التطبيق تعديلاً.

set search_path = public, extensions;


drop view if exists public.trip_party_info;

create view public.trip_party_info
with (security_barrier = true)
as
-- ---------------------------------------------------------------------------
-- طرف الراكب
-- ---------------------------------------------------------------------------
select
  t.id   as trip_id,
  p.id   as person_id,
  'rider'::text as party,

  p.full_name,
  p.avatar_url,

  -- الهاتف يُكشف أثناء الرحلة النشطة فقط. بعد انتهائها لا يبقى سبب
  -- لبقاء رقم الراكب في يد السائق.
  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end as phone,

  -- الراكب ليس سائقاً: أعمدة المركبة فارغة في هذا الفرع.
  null::numeric as rating_avg,
  null::text    as vehicle_type,
  null::text    as vehicle_plate,
  null::text    as vehicle_make,
  null::text    as vehicle_model,
  null::text    as vehicle_color

from public.trips t
join public.profiles p on p.id = t.rider_id
where t.rider_id = auth.uid() or t.driver_id = auth.uid()

union all

-- ---------------------------------------------------------------------------
-- طرف السائق
-- ---------------------------------------------------------------------------
select
  t.id,
  p.id,
  'driver'::text,

  p.full_name,
  p.avatar_url,

  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end,

  d.rating_avg,
  d.vehicle_type,
  d.vehicle_plate,
  d.vehicle_make,
  d.vehicle_model,
  d.vehicle_color

from public.trips t
join public.profiles p on p.id = t.driver_id
left join public.drivers d on d.id = p.id
where t.rider_id = auth.uid() or t.driver_id = auth.uid();

comment on view public.trip_party_info is
  'الحقول الآمنة فقط عن طرفي الرحلة. لا يكشف رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;


-- -----------------------------------------------------------------------------
-- ٢) فهارس الوصل
-- -----------------------------------------------------------------------------
-- **الفرعان لا ينفعان بلا فهرس يقرآنه.** `rider_id` و`driver_id` مفتاحان
-- أجنبيان، وبوستغرس لا يُنشئ فهرساً للمفتاح الأجنبي تلقائياً — يُنشئه
-- للمفتاح الأساسي وحده. وهو ما جعل كل استعلام على رحلات مستخدمٍ يمسح
-- الجدول.
create index if not exists trips_rider_idx  on public.trips (rider_id);
create index if not exists trips_driver_idx on public.trips (driver_id);

-- استعلام العروض في شاشة البحث يفلتر بالرحلة، وهو الاستعلام الذي كان
-- يتجاوز المهلة معه.
create index if not exists trip_offers_trip_idx on public.trip_offers (trip_id);


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — يجب ألا يظهر Seq Scan على profiles
-- -----------------------------------------------------------------------------
select
  indexname as "الفهرس",
  tablename as "الجدول"
from pg_indexes
where schemaname = 'public'
  and indexname in
      ('trips_rider_idx','trips_driver_idx','trip_offers_trip_idx')
order by tablename, indexname;
