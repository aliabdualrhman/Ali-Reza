set search_path = public, extensions;

-- =============================================================================
-- 0015 — تتبع السائق، ورسوم الإلغاء، وملاحظة الراكب
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ١) إحداثيات السائق كأعمدة قابلة للقراءة
-- -----------------------------------------------------------------------------
-- نفس مشكلة 0014: عمود geography يعود بصيغة WKB ثنائية لا يفهمها التطبيق.
-- الراكب يحتاج موقع سائقه ليتتبّعه على الخريطة أثناء اقترابه.
--
-- **لماذا لا نستعمل الأعمدة المحسوبة هنا؟** لأن موقع السائق يتغيّر كل
-- ٥ ثوانٍ، والعمود المحسوب المخزَّن يُعاد حسابه مع كل تحديث — وهو ما
-- نريده فعلاً، لكن `generated always as ... stored` يمنع الكتابة على
-- العمود الأصل من دالة security definer في بعض الحالات. الأبسط والأضمن:
-- نحدّثهما داخل update_driver_location نفسها.
-- -----------------------------------------------------------------------------
alter table public.drivers
  add column if not exists current_lat double precision,
  add column if not exists current_lng double precision;

comment on column public.drivers.current_lat is
  'خط العرض، يُحدَّث مع current_location. للقراءة من التطبيق.';

-- نعيد تعريف الدالة لتملأ العمودين الجديدين
create or replace function public.update_driver_location(
  p_lat       double precision,
  p_lng       double precision,
  p_heading   smallint default null,
  p_speed_kmh smallint default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_trip_id uuid;
begin
  if auth.uid() is null then
    raise exception 'غير مصرّح';
  end if;

  -- تذكير: st_makepoint تأخذ (خط الطول، خط العرض) — lng أولاً ثم lat
  update public.drivers
  set current_location    = st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography,
      current_lat         = p_lat,
      current_lng         = p_lng,
      heading             = p_heading,
      speed_kmh           = p_speed_kmh,
      location_updated_at = now()
  where id = auth.uid();

  if not found then
    raise exception 'المستخدم الحالي ليس سائقاً';
  end if;

  -- أثناء الرحلة نحفظ أثر المسار لحساب المسافة الفعلية وحلّ النزاعات
  select id into v_trip_id
  from public.trips
  where driver_id = auth.uid()
    and status in ('accepted', 'driver_arrived', 'in_progress');

  if v_trip_id is not null then
    insert into public.trip_locations (trip_id, location, heading, speed_kmh)
    values (
      v_trip_id,
      st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography,
      p_heading,
      p_speed_kmh
    );
  end if;
end;
$$;

-- نملأ العمودين للسائقين الموجودين من مواقعهم الحالية
update public.drivers
set current_lat = st_y(current_location::geometry),
    current_lng = st_x(current_location::geometry)
where current_location is not null and current_lat is null;


-- -----------------------------------------------------------------------------
-- ٢) خفض رسوم الإلغاء
-- -----------------------------------------------------------------------------
-- كانت ١٠٠٠ دينار — أي **كامل أجرة أقصر رحلة** بعد اعتماد الحد الأدنى
-- الجديد. عقوبة بحجم الخدمة نفسها تُنفّر الراكب أكثر مما تحمي السائق.
--
-- ٥٠٠ تعوّض السائق عن تحرّكه دون أن تبدو عقاباً.
-- -----------------------------------------------------------------------------
update public.pricing_zones
set cancellation_fee_iqd = 500
where is_active;


-- -----------------------------------------------------------------------------
-- ٣) تقرير التحقق
-- -----------------------------------------------------------------------------
select
  city_name_ar          as "المدينة",
  base_fare_iqd         as "أجرة البداية",
  per_km_iqd            as "لكل كم",
  minimum_fare_iqd      as "الحد الأدنى",
  cancellation_fee_iqd  as "رسوم الإلغاء",
  free_cancel_window_s  as "مهلة الإلغاء المجاني (ث)"
from public.pricing_zones
where is_active
order by city_name_ar
limit 5;
