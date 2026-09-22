-- =============================================================================
-- 0059 — رقمٌ في مكانين، وقائمةٌ تُنسخ في كل ترحيل
-- =============================================================================
-- مراجعةٌ للمشروع كشفت عطلين بنيويّين. لا ينهار بهما شيء اليوم، وكلاهما
-- ينفجر عند أول تعديل.
--
-- ------------------------------------------------------------------
-- ١) حدُّ التحذير مكتوبٌ مرتين
-- ------------------------------------------------------------------
--     active_trip_screen.dart:21   const _dropoffWarnRadius = 400
--     pricing_zones.dropoff_warn_radius_m = 400        (0053)
--
-- **والقيمتان تفترقان لحظة تغيير إحداهما.** لو رفع المدير حدّ المنطقة
-- إلى ٦٠٠، حذّر التطبيق عند ٤٠٠ وحكمت القاعدة بـ٦٠٠:
--
--   • رحلةٌ على بُعد ٥٠٠م: يُحذَّر السائق، ويقبل، **وتُحتسب** له.
--   • ورحلةٌ على بُعد ٧٠٠م: يُحذَّر، ويقبل، **ولا تُحتسب**.
--
-- تحذيرٌ واحد ونتيجتان — ولا شيء يفسّر الفرق لا للسائق ولا للمدير.
-- والحكم يبقى في القاعدة كما هو، لكنّ التطبيق يسأل عن الرقم بدل أن
-- يحفظه.
--
-- ------------------------------------------------------------------
-- ٢) `known_permissions` نُسخت سبع مرات
-- ------------------------------------------------------------------
-- دالةٌ تُعيد قائمة صلاحيات ثابتة، وكل ترحيلٍ يضيف صلاحية **ينسخ
-- القائمة كاملةً** ويُلحق سطراً. سبع نسخ حتى الآن.
--
-- ونسيانُ سطرٍ في النسخ **يحذف صلاحية بصمت**: تختفي من اللوحة، ويظنّ
-- المدير أنها لم تُبنَ، بينما `has_perm` ما زالت تفحصها. عطلٌ لا يُنتج
-- خطأً بل صمتاً.
--
-- فتصير جدولاً: الصلاحية الجديدة سطرُ `insert` لا نسخةُ قائمة.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) التطبيق يسأل عن حدّ التحذير
-- -----------------------------------------------------------------------------
-- **لكل رحلة لا لكل منطقة.** السائق قد يعمل في منطقتين، والحدّ يخصّ
-- منطقة انطلاق الرحلة لا موقعه الحالي — وهي التي يحكم بها
-- `mark_completion_distance`. فنسأل بنفس المفتاح الذي يحكم به.
create or replace function public.trip_dropoff_warn_radius(p_trip_id uuid)
returns integer
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select coalesce(
    (select z.dropoff_warn_radius_m
     from public.trips t
     join public.pricing_zones z
       on z.id = public.zone_for_point(t.pickup_location)
     where t.id = p_trip_id
       -- **طرفا الرحلة وحدهما.** الرقم غير حسّاس، لكنّ فتحه لكل مستخدم
       -- يكشف إعدادات مناطقنا لمن يجمعها.
       and (t.driver_id = auth.uid() or t.rider_id = auth.uid())),
    400);
$fn$;

revoke all on function public.trip_dropoff_warn_radius(uuid) from public, anon;
grant execute on function public.trip_dropoff_warn_radius(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- ٢) الصلاحيات جدولاً لا دالةً تُنسخ
-- -----------------------------------------------------------------------------
create table if not exists public.permission_catalog (
  code       text primary key,
  label      text not null,
  sort_order smallint not null default 100
);

alter table public.permission_catalog enable row level security;

-- تُقرأ من اللوحة لعرض مربّعات الاختيار. ولا يكتبها أحد من التطبيق —
-- الصلاحيات تُضاف بترحيل لا بضغطة.
drop policy if exists permission_catalog_read on public.permission_catalog;
create policy permission_catalog_read on public.permission_catalog
  for select to authenticated using (true);

comment on table public.permission_catalog is
  'قائمة الصلاحيات المعروفة. صلاحيةٌ جديدة = سطر insert، لا نسخُ قائمة.';

insert into public.permission_catalog (code, label, sort_order) values
  ('drivers.review',  'مراجعة السائقين واعتمادهم',      10),
  ('drivers.view',    'عرض السائقين وأرصدتهم',           20),
  ('riders.view',     'عرض الركّاب وبياناتهم',            30),
  ('profiles.edit',   'تعديل بيانات المستخدمين مباشرةً',  40),
  ('accounts.create', 'إنشاء حسابات جديدة من اللوحة',    50),
  ('accounts.delete', 'حذف حسابات المستخدمين',           60),
  ('wallets.adjust',  'إضافة الأرصدة وخصمها',            70),
  ('trips.view',      'عرض الرحلات',                     80),
  ('trips.cancel',    'إلغاء رحلة جارية',                90),
  ('topups.generate', 'توليد رموز التعبئة',             100),
  ('topups.view',     'عرض رموز التعبئة',               110),
  ('payouts.process', 'معالجة طلبات السحب',             120),
  ('coupons.manage',  'إنشاء الكوبونات وإيقافها',       130),
  ('settings.manage', 'تعديل الإعدادات العامة',         140)
on conflict (code) do update
  set label = excluded.label, sort_order = excluded.sort_order;


-- **الدالة تبقى ويتبدّل مصدرها.** اللوحة تستدعيها اليوم، وتغييرُ
-- الاسم يكسرها بلا داعٍ. تقرأ الجدول الآن، فلن تُنسخ مرة أخرى.
create or replace function public.known_permissions()
returns table (code text, label text)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select code, label
  from public.permission_catalog
  order by sort_order, code;
$fn$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.permission_catalog) as "صلاحيات مسجَّلة",
  (select count(*) from public.known_permissions()) as "تعيدها الدالة";
