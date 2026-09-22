set search_path = public, extensions;

-- =============================================================================
-- 0014 — إحداثيات الرحلة كأعمدة قابلة للقراءة
-- =============================================================================
-- **المشكلة:** تطبيق السائق يحتاج إحداثيات نقطة الانطلاق والوجهة ليفتح
-- Waze عليها. لكن PostgREST يعيد عمود geography بصيغة WKB سداسية عشرية
-- (`0101000020E6100000...`) وهي غير قابلة للقراءة في التطبيق.
--
-- **الخيارات المرفوضة:**
--   - تفكيك WKB في التطبيق: كود هشّ يتعامل مع ترتيب البايتات ونظام
--     الإحداثيات، وأي خطأ فيه يرسل السائق إلى مكان خاطئ.
--   - دالة RPC لكل رحلة: نداء شبكة إضافي لبيانات موجودة أصلاً في الصف.
--
-- **الحل:** أعمدة محسوبة ومخزّنة. بوستغرس يحسبها مرة عند الإدراج ويعيدها
-- كأرقام عادية. لا كلفة استعلام، ولا كود تفكيك، ولا تعارض ممكن بينها
-- وبين العمود الأصلي لأنها مشتقة منه لا مكتوبة يدوياً.
--
-- **تذكير الترتيب:** st_y يعطي خط العرض (latitude) و st_x خط الطول
-- (longitude). PostGIS يخزّن (lng, lat) عكس ترتيب الخرائط الشائع، وهذا
-- مصدر أخطاء متكرر — لذلك نسمّي الأعمدة صراحةً.
-- =============================================================================

alter table public.trips
  add column if not exists pickup_lat double precision
    generated always as (st_y(pickup_location::geometry)) stored,
  add column if not exists pickup_lng double precision
    generated always as (st_x(pickup_location::geometry)) stored,
  add column if not exists dropoff_lat double precision
    generated always as (st_y(dropoff_location::geometry)) stored,
  add column if not exists dropoff_lng double precision
    generated always as (st_x(dropoff_location::geometry)) stored;

comment on column public.trips.pickup_lat is
  'خط العرض، مشتق آلياً من pickup_location. للقراءة من التطبيق.';
comment on column public.trips.dropoff_lat is
  'خط العرض، مشتق آلياً من dropoff_location. للقراءة من التطبيق.';

-- تحقّق: يجب أن تطابق الإحداثيات المستخرجة النقطة الأصلية
select
  trip_number as "رقم الرحلة",
  round(pickup_lat::numeric, 5)  as "انطلاق (عرض)",
  round(pickup_lng::numeric, 5)  as "انطلاق (طول)",
  round(dropoff_lat::numeric, 5) as "وجهة (عرض)",
  round(dropoff_lng::numeric, 5) as "وجهة (طول)"
from public.trips
order by requested_at desc
limit 5;
