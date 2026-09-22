-- =============================================================================
-- 0088 — أرباح السائق لفترة: يوم، أسبوع، شهر، أو من تاريخ إلى تاريخ
-- =============================================================================
-- **لماذا دالة في القاعدة لا جمعٌ في التطبيق؟**
--
-- واجهة Supabase لا تعيد أكثر من ألف صف في الطلب الواحد. سائقٌ نشط يُكمل
-- ثلاثين رحلة يومياً يتجاوزها في شهرٍ وبعض الشهر، فيجمع التطبيق أول ألف
-- ويعرض المجموع ناقصاً — رقمٌ خاطئ بلا أي تحذير، في الشاشة التي يقارن
-- فيها السائق ما في جيبه بما نقول إنه كسبه.
--
-- **ما يدخل:** الرحلات المكتملة وحدها، بتاريخ إكمالها لا طلبها — رحلة
-- طُلبت قبل منتصف الليل بدقيقة وانتهت بعده تُحسب لليوم الذي قُبض فيه
-- المال.
--
-- **ما لا يدخل:** ثمن بضاعة التسوّق. هو في `goods_actual_iqd` مستقلاً،
-- مالُ الراكب يمرّ بيد السائق ولا يبقى له منه شيء.
-- =============================================================================

create or replace function public.my_earnings(
  p_from timestamptz,
  p_to   timestamptz
)
returns table (
  trip_count       integer,
  gross_iqd        numeric,   -- مجموع الأجور
  commission_total numeric,   -- حصة الشركة
  net_iqd          numeric    -- ما بقي للسائق
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    count(*)::integer,
    coalesce(sum(t.fare_final_iqd), 0),
    coalesce(sum(t.commission_iqd), 0),
    coalesce(sum(t.fare_final_iqd - coalesce(t.commission_iqd, 0)), 0)
  from public.trips t
  where t.driver_id    = auth.uid()   -- لا معامل للسائق: لا يقرأ غيرَ نفسه
    and t.status       = 'completed'
    and t.completed_at >= p_from
    and t.completed_at <  p_to;
$fn$;

revoke all on function public.my_earnings(timestamptz, timestamptz)
  from public, anon;
grant execute on function public.my_earnings(timestamptz, timestamptz)
  to authenticated;

-- الفترة الطويلة تمسح رحلات السائق كلها بلا فهرس
create index if not exists trips_driver_completed_idx
  on public.trips (driver_id, completed_at)
  where status = 'completed';
