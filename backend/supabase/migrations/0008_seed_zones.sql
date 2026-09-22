-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0008 — بيانات التهيئة: مناطق الخدمة والتسعير
-- =============================================================================
-- الحدود هنا مضلعات تقريبية تغطي المدن. عند الإطلاق الفعلي استبدلها بحدود
-- دقيقة مرسومة على خريطة (geojson.io يصدّرها جاهزة).
--
-- تذكير الترتيب: كل زوج هو (خط الطول، خط العرض) — lng ثم lat.
-- =============================================================================

insert into public.pricing_zones (
  city_name, city_name_ar, boundary,
  base_fare_iqd, per_km_iqd, per_minute_iqd, minimum_fare_iqd,
  cancellation_fee_iqd, commission_rate,
  search_radius_m, max_search_radius_m
) values
-- -----------------------------------------------------------------------------
-- بغداد — مضلع يغطي الكرخ والرصافة وأطرافهما
-- -----------------------------------------------------------------------------
(
  'Baghdad', 'بغداد',
  st_geogfromtext('POLYGON((
    44.20 33.45, 44.65 33.45, 44.70 33.35,
    44.65 33.18, 44.30 33.15, 44.15 33.25,
    44.20 33.45
  ))'),
  1000, 250, 25, 1500, 1000, 0.150,
  3000, 7000
),
-- -----------------------------------------------------------------------------
-- البصرة — مسافات أطول بين الأحياء، سعر الكم أعلى قليلاً
-- -----------------------------------------------------------------------------
(
  'Basra', 'البصرة',
  st_geogfromtext('POLYGON((
    47.70 30.60, 47.90 30.60, 47.95 30.45,
    47.85 30.40, 47.70 30.45, 47.70 30.60
  ))'),
  1000, 275, 25, 1500, 1000, 0.150,
  3500, 8000
),
-- -----------------------------------------------------------------------------
-- أربيل — كثافة أقل، نطاق بحث أوسع
-- -----------------------------------------------------------------------------
(
  'Erbil', 'أربيل',
  st_geogfromtext('POLYGON((
    43.90 36.25, 44.10 36.25, 44.15 36.10,
    44.00 36.05, 43.88 36.12, 43.90 36.25
  ))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 9000
);

-- كل منطقة تبدأ بلا ذروة
insert into public.surge_state (zone_id, multiplier)
select id, 1.00 from public.pricing_zones;

-- =============================================================================
-- أسباب الإلغاء الجاهزة — لتوحيد التقارير بدل نص حر
-- =============================================================================
create table public.cancellation_reasons (
  code        text primary key,
  label_ar    text not null,
  label_en    text not null,
  for_role    public.user_role not null,
  sort_order  smallint not null default 0,
  is_active   boolean not null default true
);

alter table public.cancellation_reasons enable row level security;
create policy "cancel reasons: قراءة عامة"
  on public.cancellation_reasons for select using (is_active);

insert into public.cancellation_reasons (code, label_ar, label_en, for_role, sort_order) values
  ('rider_wait_too_long',  'وقت الانتظار طويل',              'Wait time too long',      'rider',  1),
  ('rider_wrong_pickup',   'حددت نقطة انطلاق خاطئة',         'Wrong pickup location',   'rider',  2),
  ('rider_changed_plans',  'تغيّرت خطتي',                    'Changed my plans',        'rider',  3),
  ('rider_found_other',    'وجدت وسيلة أخرى',                'Found another ride',      'rider',  4),
  ('rider_driver_asked',   'السائق طلب مني الإلغاء',         'Driver asked me to cancel','rider', 5),
  ('driver_rider_absent',  'الراكب غير موجود',               'Rider not at pickup',     'driver', 1),
  ('driver_wrong_address', 'العنوان غير صحيح أو غير واضح',   'Address unclear',         'driver', 2),
  ('driver_vehicle_issue', 'عطل في الدراجة',                 'Vehicle problem',         'driver', 3),
  ('driver_too_far',       'نقطة الانطلاق بعيدة جداً',        'Pickup too far',          'driver', 4),
  ('driver_rider_refused', 'الراكب رفض الركوب',              'Rider refused to board',  'driver', 5);
