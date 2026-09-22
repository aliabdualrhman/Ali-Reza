-- =============================================================================
-- 0037 — وضع المراجعة: الخدمة متاحة في كل مكان مؤقتاً
-- =============================================================================
-- **المشكلة التي يحلّها.** مناطق الخدمة مضلّعات جغرافية حول مدن عراقية،
-- و`zone_for_point` تردّ فارغاً لأي نقطة خارجها — فيرى صاحبها «الخدمة غير
-- متوفرة هنا» ولا يستطيع طلب رحلة.
--
-- ومراجع جوجل وآبل يفتح التطبيق من مكتبه في كاليفورنيا أو دبلن. فيرى
-- تطبيقاً لا يعمل، ويرفضه. ولا ينفع تفعيلُ كل المناطق العراقية: مكتبه
-- خارجها كلها.
--
-- **الحل: مفتاح واحد يجعل كل نقطة على الأرض تقع في منطقة.** يُشغَّل يوم
-- الإرسال، ويُطفأ يوم القبول.
--
-- ولماذا في `zone_for_point` وحدها؟ لأنها نقطة الاختناق: التسعير والبثّ
-- والسياج الجغرافي وحساب الأجرة، كلها تمرّ بها. تعديلٌ هنا يسري على
-- المسار كله بلا لمس دالة أخرى.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) المفتاح
-- -----------------------------------------------------------------------------
-- **`off` افتراضاً.** إعداد خطر يبدأ مطفأً؛ من يحتاجه يشعله بيده ويعرف
-- لماذا.
insert into public.public_settings (key, value, label) values
  ('review_mode', 'off', 'وضع المراجعة — الخدمة متاحة في كل العالم')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- ٢) المنطقة التي تُستعمل خارج التغطية
-- -----------------------------------------------------------------------------
-- تسعيرة المنطقة الاحتياطية هي ما يُحسب به في وضع المراجعة. نختار أول
-- منطقة مفعّلة — وهي الناصرية في وضعنا الحالي — فيرى المراجع أسعاراً
-- حقيقية لا أرقاماً مخترعة.
create or replace function public.fallback_zone()
returns uuid
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select id from public.pricing_zones
  where is_active
  order by city_name
  limit 1;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) هل وضع المراجعة مشتغل؟
-- -----------------------------------------------------------------------------
create or replace function public.review_mode_on()
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select coalesce(
    (select lower(btrim(value)) in ('on','true','1','yes')
     from public.public_settings where key = 'review_mode'),
    false);
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) zone_for_point — بالاحتياط
-- -----------------------------------------------------------------------------
-- **الترتيب مقصود:** نبحث عن المنطقة الحقيقية أولاً دائماً. فحتى ووضع
-- المراجعة مشتغل، يبقى راكب الناصرية على تسعيرة الناصرية، ولا يتغيّر
-- شيء لمن هم داخل التغطية. الاحتياط لا يُستعمل إلا حين لا توجد منطقة —
-- وهي الحالة التي كانت تردّ فارغاً.
create or replace function public.zone_for_point(p_point geography)
returns uuid
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(
    (select id
     from public.pricing_zones
     where is_active
       and st_contains(boundary::geometry, p_point::geometry)
     limit 1),
    case when public.review_mode_on() then public.fallback_zone() end
  );
$$;


-- -----------------------------------------------------------------------------
-- ٥) تبديل المفتاح من اللوحة
-- -----------------------------------------------------------------------------
-- **دالة لا تحديث مباشر.** هذا مفتاح يفتح الخدمة للعالم كله، فيمرّ بفحص
-- صلاحية ويُسجَّل في سجلّ التدقيق باسم من أداره ووقته. مفتاحٌ بهذا الأثر
-- يجب أن يُعرف من تركه مشتغلاً.
create or replace function public.set_review_mode(p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.has_perm('settings.manage') then
    raise exception 'لا تملك صلاحية تغيير الإعدادات'
      using errcode = 'insufficient_privilege';
  end if;

  update public.public_settings
  set value = case when p_on then 'on' else 'off' end,
      updated_at = now(),
      updated_by = auth.uid()
  where key = 'review_mode';

  perform public.log_action(
    case when p_on then 'review_mode.on' else 'review_mode.off' end,
    'setting', 'review_mode',
    case when p_on
      then 'شغّل وضع المراجعة — الخدمة صارت متاحة في كل العالم'
      else 'أطفأ وضع المراجعة — عادت الخدمة إلى المناطق المفعّلة'
    end
  );

  return p_on;
end;
$fn$;


revoke all on function public.set_review_mode(boolean) from public, anon;
revoke all on function public.review_mode_on()         from public, anon;
revoke all on function public.fallback_zone()          from public, anon;

grant execute on function public.set_review_mode(boolean) to authenticated;
grant execute on function public.review_mode_on()         to authenticated;
grant execute on function public.fallback_zone()          to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select value from public.public_settings where key = 'review_mode')
    as "وضع المراجعة",
  public.review_mode_on()                       as "مشتغل؟",
  (select city_name_ar from public.pricing_zones
   where id = public.fallback_zone())           as "المنطقة الاحتياطية";
