-- =============================================================================
-- 0041 — البحث يتبع منطقة صاحبه لا المنطقة الاحتياطية
-- =============================================================================
-- **العَرَض.** وضع المراجعة مشتغل — أي أن الخدمة متاحة في كل العالم —
-- ومع ذلك يبحث المراجع في كاليفورنيا فلا يجد إلا أماكن الناصرية. فتحنا
-- له العالم في التسعير وأغلقناه في البحث.
--
-- **السبب.** `zone_bbox` تمرّ بـ`zone_for_point`، وتلك تردّ المنطقة
-- **الاحتياطية** لمن هو خارج كل تغطية ما دام وضع المراجعة مشتغلاً
-- (0037). وذلك صواب لغرضه: المراجع يحتاج تسعيرةً حقيقية ليطلب رحلة.
-- لكنه خطأ لغرضنا: حدود الناصرية ليست حدود بحثه.
--
-- **التمييز الذي كان ناقصاً:** «أي منطقة تُسعّر رحلته؟» سؤال، و«أين
-- يبحث عن العناوين؟» سؤال آخر. أجبنا الثاني بجواب الأول.
--
-- **الحل: نميّز المطابقة الحقيقية من الاحتياطية.**
--
--   ١) نقطة داخل منطقة مفعّلة  ← حدودها. راكب بغداد يبحث في بغداد،
--      وراكب الناصرية في الناصرية. **لا يتغيّر شيء لمن هم داخل التغطية.**
--   ٢) خارج التغطية ووضع المراجعة مشتغل ← `unrestricted = true`،
--      فيبحث التطبيق في العالم كله بلا قيد.
--   ٣) خارج التغطية والوضع مطفأ ← لا صفوف، فيعود التطبيق إلى العراق.
--
-- ولا نقرأ `zone_for_point` هنا إطلاقاً: نبحث عن الاحتواء الحقيقي
-- بأنفسنا. فالدالتان تجيبان سؤالين مختلفين، وخلطهما هو العطل نفسه.

set search_path = public, extensions;


drop function if exists public.zone_bbox(geography);

create function public.zone_bbox(p_point geography)
returns table (
  min_lon      double precision,
  min_lat      double precision,
  max_lon      double precision,
  max_lat      double precision,
  city_name_ar text,
  unrestricted boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  -- **الأقواس إلزامية.** `limit` على فرعٍ من `union` بلا أقواس خطأ
  -- نحوي في PostgreSQL — يقرؤها كأنها تحدّ الاتحاد كله.
  (
    -- ١) المنطقة التي تحتوي النقطة فعلاً
    select
      st_xmin(b.box), st_ymin(b.box), st_xmax(b.box), st_ymax(b.box),
      z.city_name_ar,
      false
    from public.pricing_zones z
    cross join lateral (select z.boundary::geometry::box2d as box) b
    where z.is_active
      and st_contains(z.boundary::geometry, p_point::geometry)
    limit 1
  )

  union all

  (
    -- ٢) لا منطقة، ووضع المراجعة مشتغل ← العالم كله
    --
    -- **الشرط `not exists` ضروري:** بدونه يعود صفّان حين تكون النقطة
    -- داخل منطقة والوضع مشتغل، فيقرأ التطبيق أوّلهما صدفةً.
    select null::double precision, null::double precision,
           null::double precision, null::double precision,
           null::text, true
    where public.review_mode_on()
      and not exists (
        select 1 from public.pricing_zones z
        where z.is_active
          and st_contains(z.boundary::geometry, p_point::geometry)
      )
  );
$fn$;


revoke all on function public.zone_bbox(geography) from public, anon;
grant execute on function public.zone_bbox(geography) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — الحالات الثلاث
-- -----------------------------------------------------------------------------
select 'الناصرية'   as "الحالة", * from public.zone_bbox(
  st_setsrid(st_makepoint(46.2570, 31.0440), 4326)::geography)
union all
select 'بغداد',      * from public.zone_bbox(
  st_setsrid(st_makepoint(44.3661, 33.3152), 4326)::geography)
union all
select 'كاليفورنيا', * from public.zone_bbox(
  st_setsrid(st_makepoint(-122.4194, 37.7749), 4326)::geography);
