set search_path = public, extensions;

-- =============================================================================
-- 0030 — أرقام الدعم، وحصر العمل بالناصرية
-- =============================================================================
-- تعديلان قبل الإطلاق:
--
--   ١) **رقما دعم منفصلان** للسائقين وللركّاب. سؤال السائق عن عمولة أو
--      رمز تعبئة لا يشبه سؤال الراكب عن أجرة أو سائق تأخّر، وخلطهما في
--      رقم واحد يجعل الرد على الاثنين أبطأ.
--
--   ٢) **العمل في الناصرية وحدها.** المحافظات الثماني عشرة كلها معرّفة
--      في القاعدة لكن **معطّلة**، ولكلٍّ منها مفتاح تفعيل في اللوحة.
--
-- **لماذا نعرّفها كلها ونعطّلها بدل حذفها؟** لأن التوسّع حينها قرارٌ
-- بضغطة لا ترحيلٌ جديد. ولأن الحدود مرسومة ومراجَعة الآن، لا في يومٍ
-- نكون فيه مستعجلين.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) أرقام الدعم
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('support_whatsapp_driver', '', 'رقم دعم السائقين (واتساب)'),
  ('support_whatsapp_rider',  '', 'رقم دعم الركّاب (واتساب)')
on conflict (key) do nothing;

-- **فارغان عمداً لا مملوءان برقمك.** زرُّ دعم يفتح رقماً خاطئاً أسوأ من
-- غياب الزر: الراكب يظن أنه راسل الدعم ويبقى ينتظر رداً لا يأتي.
-- التطبيقان يخفيان الزر ما دام الرقم فارغاً.


-- -----------------------------------------------------------------------------
-- ٢) المحافظات الأربع الناقصة
-- -----------------------------------------------------------------------------
-- كانت أربع عشرة. هذه تكمل الثماني عشرة.
--
-- **مستطيلات كما في 0012 لا مضلعات دقيقة.** والقيد نفسه قائم: تغطّي
-- المدينة وشيئاً من الصحراء حولها. مقبول لمنطقة **معطّلة** — وقبل تفعيل
-- أيٍّ منها ارسم لها مضلعاً حقيقياً على geojson.io.
insert into public.pricing_zones (
  city_name, city_name_ar, boundary,
  base_fare_iqd, per_km_iqd, per_minute_iqd, minimum_fare_iqd,
  cancellation_fee_iqd, commission_rate,
  search_radius_m, max_search_radius_m, is_active
) values
  ('Duhok', 'دهوك',
   st_geogfromtext('POLYGON((42.79 36.66, 43.19 36.66, 43.19 37.08, 42.79 37.08, 42.79 36.66))'),
   500, 250, 0, 1000, 0, 0.150, 4000, 10000, false),
  ('Baquba', 'بعقوبة',
   st_geogfromtext('POLYGON((44.44 33.54, 44.84 33.54, 44.84 33.96, 44.44 33.96, 44.44 33.54))'),
   500, 250, 0, 1000, 0, 0.150, 4000, 10000, false),
  ('Ramadi', 'الرمادي',
   st_geogfromtext('POLYGON((43.11 33.21, 43.51 33.21, 43.51 33.63, 43.11 33.63, 43.11 33.21))'),
   500, 250, 0, 1000, 0, 0.150, 4000, 10000, false),
  ('Tikrit', 'تكريت',
   st_geogfromtext('POLYGON((43.48 34.40, 43.88 34.40, 43.88 34.82, 43.48 34.82, 43.48 34.40))'),
   500, 250, 0, 1000, 0, 0.150, 4000, 10000, false)
on conflict do nothing;


-- -----------------------------------------------------------------------------
-- ٣) الناصرية وحدها تعمل
-- -----------------------------------------------------------------------------
-- **التركيز قرار لا قصور.** مشكلة الدجاجة والبيضة تُحلّ بحيٍّ مكتظ فيه
-- عشرون سائقاً، لا بثماني عشرة محافظة فيها سائق أو اثنان. وراكبٌ في
-- بغداد يطلب فلا يجد أحداً لا يعود أبداً.
update public.pricing_zones
set is_active = (city_name = 'Nasiriyah');


-- -----------------------------------------------------------------------------
-- ٤) تفعيل منطقة من اللوحة
-- -----------------------------------------------------------------------------
-- دالة لا تحديث مباشر: التفعيل قرار له أثر تجاري، فيمرّ بفحص صلاحية
-- ويُسجَّل في سجلّ التدقيق كغيره من الأفعال.
create or replace function public.set_zone_active(p_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_name text;
begin
  if not public.has_perm('settings.manage') then
    raise exception 'لا تملك صلاحية تعديل المناطق'
      using errcode = 'insufficient_privilege';
  end if;

  update public.pricing_zones set is_active = p_active
  where id = p_id
  returning city_name_ar into v_name;

  if v_name is null then
    raise exception 'المنطقة غير موجودة';
  end if;

  perform public.log_action(
    case when p_active then 'zone.enable' else 'zone.disable' end,
    'zone', p_id::text,
    format('%s منطقة %s', case when p_active then 'فعّل' else 'عطّل' end, v_name));
end;
$fn$;

revoke all on function public.set_zone_active from public, anon;
grant execute on function public.set_zone_active(uuid, boolean) to authenticated;


-- اللوحة تحتاج قراءة المناطق. الجدول محميّ بـ RLS منذ 0007، ولا سياسة
-- قراءة عليه للمشرف — فنضيفها هنا بدل أن تعود الصفحة فارغة بلا خطأ.
drop policy if exists "zones: يقرأ المشرف" on public.pricing_zones;
create policy "zones: يقرأ المشرف"
  on public.pricing_zones for select to authenticated
  using (public.is_admin());


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar as "المحافظة",
  case when is_active then 'تعمل' else 'معطّلة' end as "الحالة"
from public.pricing_zones
order by is_active desc, city_name_ar;
