-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
set search_path = public, extensions;

-- =============================================================================
-- 0009 — إصلاح التكرار اللانهائي في سياسات الأمان
-- =============================================================================
-- **الخطأ:** infinite recursion detected in policy for relation "trips"
--
-- **السبب:** سياستان تستدعيان بعضهما في حلقة مغلقة:
--
--     سياسة trips        →  تستعلم من trip_offers (ليرى السائق عرضه)
--     سياسة trip_offers  →  تستعلم من trips       (ليتابع الراكب بحثه)
--     سياسة trips        →  ... إلى ما لا نهاية
--
-- بوستغرس يطبّق سياسات الجدول على أي استعلام يمسّه — بما فيه الاستعلام
-- الفرعي داخل سياسة أخرى. فحين تقرأ سياسةُ A جدولَ B وسياسةُ B تقرأ جدولَ A
-- تنشأ حلقة، ويرفض بوستغرس الاستعلام كله بدل الدوران للأبد.
--
-- **الحل:** نقل الاستعلامات الفرعية إلى دوال security definer. الدالة تعمل
-- بصلاحيات مالكها فتتجاوز RLS، فلا تُستدعى السياسة الأخرى ولا تنشأ حلقة.
--
-- هذا ليس ثغرة أمنية: كل دالة تتحقق بنفسها من auth.uid() ولا ترجع إلا
-- إجابة منطقية (نعم/لا) عن صف يخص المستدعي — لا تكشف أي بيانات.
--
-- **هذا الملف عديم الأثر عند التكرار (idempotent):** يحذف السياسات القديمة
-- إن وُجدت ثم يعيد إنشاءها، فيمكن تشغيله على قاعدة مطبَّقة أو جديدة.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- الدوال المساعدة — كاسرات الحلقة
-- -----------------------------------------------------------------------------

-- هل المستخدم الحالي طرف في هذه الرحلة (راكباً أو سائقاً)؟
create or replace function public.is_trip_participant(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.trips t
    where t.id = p_trip_id
      and (t.rider_id = auth.uid() or t.driver_id = auth.uid())
  );
$$;

-- هل للسائق الحالي عرض معلّق على هذه الرحلة؟
-- يسمح له برؤية تفاصيل الرحلة قبل أن يقبلها.
create or replace function public.driver_has_pending_offer(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.trip_offers o
    where o.trip_id = p_trip_id
      and o.driver_id = auth.uid()
      and o.status = 'pending'
  );
$$;

-- هل هذا السائق هو سائق رحلتي النشطة؟
-- يسمح للراكب برؤية موقع سائقه وتقييمه ومركبته أثناء الرحلة فقط.
create or replace function public.is_my_current_driver(p_driver_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.trips t
    where t.driver_id = p_driver_id
      and t.rider_id = auth.uid()
      and t.status in ('accepted', 'driver_arrived', 'in_progress')
  );
$$;

-- هل يحق للمستخدم الحالي تقييم هذا الشخص في هذه الرحلة؟
-- الشرط: رحلة مكتملة، والطرفان هما المستدعي والمُقيَّم.
create or replace function public.can_rate_trip(p_trip_id uuid, p_ratee uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.trips t
    where t.id = p_trip_id
      and t.status = 'completed'
      and (
        (t.rider_id  = auth.uid() and t.driver_id = p_ratee) or
        (t.driver_id = auth.uid() and t.rider_id  = p_ratee)
      )
  );
$$;

-- الدوال تُستدعى من داخل السياسات، فيحتاجها كل مستخدم مسجّل
grant execute on function public.is_trip_participant(uuid)        to authenticated;
grant execute on function public.driver_has_pending_offer(uuid)   to authenticated;
grant execute on function public.is_my_current_driver(uuid)       to authenticated;
grant execute on function public.can_rate_trip(uuid, uuid)        to authenticated;

-- =============================================================================
-- إعادة كتابة السياسات الخمس المصابة
-- =============================================================================

-- ١) drivers — الراكب يرى سائقه أثناء الرحلة
drop policy if exists "drivers: راكب الرحلة النشطة" on public.drivers;
create policy "drivers: راكب الرحلة النشطة"
  on public.drivers for select
  using (public.is_my_current_driver(drivers.id));

-- ٢) trips — السائق يرى الرحلة المعروضة عليه قبل قبولها
drop policy if exists "trips: السائق يرى العرض المُقدَّم له" on public.trips;
create policy "trips: السائق يرى العرض المُقدَّم له"
  on public.trips for select
  using (public.driver_has_pending_offer(trips.id));

-- ٣) trip_offers — الراكب يتابع تقدّم البحث عن سائق
drop policy if exists "offers: الراكب يتابع بحث رحلته" on public.trip_offers;
create policy "offers: الراكب يتابع بحث رحلته"
  on public.trip_offers for select
  using (public.is_trip_participant(trip_offers.trip_id));

-- ٤) trip_locations — طرفا الرحلة يريان أثر المسار
drop policy if exists "locations: طرفا الرحلة" on public.trip_locations;
create policy "locations: طرفا الرحلة"
  on public.trip_locations for select
  using (
    public.is_trip_participant(trip_locations.trip_id)
    or public.is_admin()
  );

-- ٥) ratings — التقييم بعد رحلة مكتملة
drop policy if exists "ratings: تقييم بعد رحلة مكتملة" on public.ratings;
create policy "ratings: تقييم بعد رحلة مكتملة"
  on public.ratings for insert
  with check (
    rater_id = auth.uid()
    and ratee_id <> auth.uid()
    and public.can_rate_trip(ratings.trip_id, ratings.ratee_id)
  );
