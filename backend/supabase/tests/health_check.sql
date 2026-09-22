set search_path = public, extensions;

-- =============================================================================
-- فحص صحّة القاعدة — استعلام واحد يقول الحقيقة
-- =============================================================================
-- **لماذا يقرأ الواقع لا سجلّاً؟** لأن أي سجلّ نكتبه بأيدينا يعتمد على ألّا
-- ننسى الكتابة فيه — وقد نسينا بالفعل مرتين، فضاع ترحيل 0023 بلا أن يعلم
-- أحد حتى انفجر بعده بيومين.
--
-- هذا الاستعلام لا يسأل "ماذا سجّلنا؟" بل **"ماذا يوجد في القاعدة الآن؟"**
-- لكل ترحيل شيءٌ يُنشئه لا وجود له بدونه — جدول أو عمود أو دالة. فوجودُه
-- برهان على أن الملف نُفِّذ، وغيابه برهان على أنه لم يُنفَّذ.
--
-- **شغّله متى شككت.** أول سطر يقول "ناقص" هو الملف الذي عليك تطبيقه.
-- =============================================================================

with expected(seq, migration, kind, obj, col) as (values
  (1,  '0001_extensions_and_enums',      'type',   'trip_status',              null),
  (2,  '0002_profiles',                  'table',  'profiles',                 null),
  (3,  '0003_drivers',                   'table',  'drivers',                  null),
  (4,  '0004_trips',                     'table',  'trips',                    null),
  (5,  '0005_pricing_and_wallet',        'table',  'pricing_zones',            null),
  (6,  '0006_matching_engine',           'func',   'accept_trip_offer',        null),
  (7,  '0007_rls_policies',              'view',   'trip_party_info',          null),
  (8,  '0008_seed_zones',                'func',   'zone_for_point',           null),
  (9,  '0009_fix_policy_recursion',      'func',   'can_rate_trip',            null),
  (10, '0010_storage_policies',          'func',   'document_storage_path',    null),
  (11, '0011_fix_document_upload',       'table',  'user_documents',           null),
  (12, '0012_more_service_zones',        'zones',  '10',                       null),
  (13, '0013_pricing_distance_only',     'column', 'pricing_zones',            'per_minute_iqd'),
  (14, '0014_trip_coordinates',          'column', 'trips',                    'pickup_lat'),
  (15, '0015_tracking_and_fees',         'column', 'pricing_zones',            'free_cancel_window_s'),
  (16, '0016_notify_trigger',            'func',   'notify_driver_of_offer',   null),
  (17, '0017_persistent_search',         'column', 'pricing_zones',            'max_search_seconds'),
  (18, '0018_offer_timeout',             'func',   'dispatch_tick',            null),
  (19, '0019_party_identity',            'func',   'sync_avatar_from_selfie',  null),
  (20, '0020_broadcast_dispatch',        'column', 'pricing_zones',            'max_concurrent_offers'),
  (21, '0021_lock_and_privacy_fixes',    'proc',   'dispatch_minute',          null),
  (22, '0022_topup_payout_ratings',      'table',  'topup_codes',              null),
  (23, '0023_payout_reserve',            'func',   'payout_reserve_iqd',       null),
  (24, '0024_cancel_policy_and_geofence','func',   'my_cancels_today',         null),
  (25, '0025_lower_pricing',             'price',  '250',                      null),
  (26, '0026_payout_hold',               'func',   'cancel_payout_request',    null),
  (27, '0027_settings_welcome_coupons',  'table',  'coupons',                  null),
  (28, '0028_stops_and_destination_change','table','trip_stops',               null),
  (29, '0029_staff_and_audit',           'table',  'audit_log',                null),
  (30, '0030_support_and_zone_gating',   'func',   'set_zone_active',          null),
  (31, '0031_tuktuk',                    'column', 'drivers',                  'vehicle_kind'),
  (32, '0032_fare_boost',                'func',   'boost_trip_fare',          null),
  (33, '0033_boost_priority',            'column', 'pricing_zones',            'boosted_concurrent_offers'),
  (34, '0034_zone_tuning',               'func',   'set_zone_numbers',         null)
)
select
  e.migration as "الترحيل",
  case when found then 'مطبَّق ✓' else 'ناقص ✗' end as "الحالة"
from expected e
cross join lateral (
  select case e.kind
    when 'table' then exists (
      select 1 from information_schema.tables
      where table_schema = 'public' and table_name = e.obj)
    when 'view' then exists (
      select 1 from information_schema.views
      where table_schema = 'public' and table_name = e.obj)
    when 'column' then exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = e.obj
        and column_name = e.col)
    when 'type' then exists (
      select 1 from pg_type where typname = e.obj)
    when 'func' then exists (
      select 1 from pg_proc p
      where p.proname = e.obj and p.pronamespace = 'public'::regnamespace
        and p.prokind = 'f')
    -- الإجراء يختلف عن الدالة في `prokind`: هذا ما يميّز 0021 عن سابقه،
    -- إذ حوّل dispatch_minute من دالة إلى إجراء ليستطيع الإفلات من
    -- المعاملة بعد كل نبضة.
    when 'proc' then exists (
      select 1 from pg_proc p
      where p.proname = e.obj and p.pronamespace = 'public'::regnamespace
        and p.prokind = 'p')
    -- ترحيلات البيانات لا تُنشئ كائناً، فنفحص أثرها
    when 'zones' then (select count(*) from public.pricing_zones) >= e.obj::int
    when 'price' then exists (
      select 1 from public.pricing_zones
      where per_km_iqd = e.obj::numeric)
    else false
  end as found
) chk
order by e.seq;
