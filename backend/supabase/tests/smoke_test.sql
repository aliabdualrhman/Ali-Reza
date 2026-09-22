-- =============================================================================
-- زنبور — اختبار الدخان: رحلة كاملة من الطلب حتى قيد العمولة
-- =============================================================================
-- يحاكي راكباً وسائقاً حقيقيين ويمرّ بدورة الرحلة كاملة، ثم يطبع تقريراً.
--
-- **آمن للتكرار:** يحذف بيانات الاختبار السابقة في بدايته، فيمكن تشغيله
-- مراراً. ولا يمسّ أي بيانات حقيقية — كل حساباته على النطاق @zanbour.test
--
-- **كيف يعمل انتحال الهوية؟** دوالنا تعتمد auth.uid() التي تقرأ معرّف
-- المستخدم من رمز الجلسة. في محرر SQL لا يوجد رمز، فنضبطه يدوياً عبر
-- set_config('request.jwt.claims', ...) — وهو ما تقرأه auth.uid() فعلاً.
-- بهذا نختبر الدوال بنفس شروط التطبيق الحقيقي لا بصلاحيات مدير.
-- =============================================================================

set search_path = public, extensions;

do $$
declare
  v_rider   uuid := '11111111-1111-1111-1111-111111111111';
  v_driver  uuid := '22222222-2222-2222-2222-222222222222';
  v_trip    public.trips;
  v_offer   public.trip_offers;
  v_zone    uuid;
  v_est     jsonb;
  v_nearby  integer;
  v_balance numeric;
begin
  -- ===========================================================================
  -- ٠) تنظيف تشغيل سابق
  -- ===========================================================================
  delete from auth.users where email like '%@zanbour.test';
  raise notice '[٠] نُظّفت بيانات الاختبار السابقة';

  -- ===========================================================================
  -- ١) إنشاء الحسابات — يمرّ عبر مُشغّل handle_new_user
  -- ===========================================================================
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data
  ) values
  (
    '00000000-0000-0000-0000-000000000000', v_rider, 'authenticated', 'authenticated',
    'rider@zanbour.test', crypt('TestPass123!', gen_salt('bf')),
    now(), now(), now(), '{"provider":"email"}'::jsonb,
    jsonb_build_object(
      'role', 'rider',
      'full_name', 'علي حسن محمد',
      'phone', '07701234567',
      'date_of_birth', '1995-04-12',
      'address', 'بغداد - الكرادة - شارع 62'
    )
  ),
  (
    '00000000-0000-0000-0000-000000000000', v_driver, 'authenticated', 'authenticated',
    'driver@zanbour.test', crypt('TestPass123!', gen_salt('bf')),
    now(), now(), now(), '{"provider":"email"}'::jsonb,
    jsonb_build_object(
      'role', 'driver',
      'full_name', 'كرار عبد الله جاسم',
      'phone', '07809876543',
      'date_of_birth', '1990-08-20',
      'address', 'بغداد - الجادرية',
      'vehicle_type', 'هوندا CG 150'
    )
  );
  raise notice '[١] أُنشئ الحسابان — المُشغّل ولّد profiles و drivers';

  -- ===========================================================================
  -- ٢) وثائق السائق ثم اعتمادها (دور المدير)
  -- ===========================================================================
  insert into public.user_documents (user_id, doc_type, storage_path) values
    (v_rider,  'live_selfie',       'test/rider-selfie.jpg'),
    (v_driver, 'live_selfie',       'test/driver-selfie.jpg'),
    (v_driver, 'national_id_front', 'test/id-front.jpg'),
    (v_driver, 'national_id_back',  'test/id-back.jpg'),
    (v_driver, 'vehicle_photo',     'test/bike-1.jpg'),
    (v_driver, 'vehicle_photo',     'test/bike-2.jpg');

  -- الراكب اعتُمد تلقائياً بمُشغّل auto_approve_rider_docs؛ نتحقق:
  if not (select identity_verified from public.profiles where id = v_rider) then
    raise exception 'فشل: صورة الراكب لم تُعتمد تلقائياً';
  end if;
  raise notice '[٢أ] الراكب اعتُمد تلقائياً ✓';

  -- السائق يحتاج موافقة يدوية
  update public.user_documents set status = 'approved', reviewed_at = now()
  where user_id = v_driver;

  if (select verification_status from public.drivers where id = v_driver) <> 'approved' then
    raise exception 'فشل: السائق لم يُعتمد بعد قبول كل وثائقه';
  end if;
  raise notice '[٢ب] السائق اعتُمد بعد مراجعة الوثائق ✓';

  -- ===========================================================================
  -- ٣) السائق يتصل ويحدّث موقعه (بهويته)
  -- ===========================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_driver, 'role', 'authenticated')::text, true);

  perform public.set_driver_online(true);
  perform public.update_driver_location(33.3120, 44.3620, 90::smallint, 25::smallint);

  if (select status from public.drivers where id = v_driver) <> 'online' then
    raise exception 'فشل: السائق لم يصر متصلاً';
  end if;
  raise notice '[٣] السائق متصل وموقعه محدَّث في الكرادة ✓';

  -- ===========================================================================
  -- ٤) الراكب يقدّر الأجرة ثم يطلب الرحلة (بهويته)
  -- ===========================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rider, 'role', 'authenticated')::text, true);

  v_est := public.estimate_trip(33.3100, 44.3600, 33.2850, 44.4050, 4200, 780);
  raise notice '[٤أ] التقدير: % دينار | سائقون قريبون: %',
    v_est ->> 'total', v_est ->> 'nearby_drivers';

  if (v_est ->> 'nearby_drivers')::int < 1 then
    raise exception 'فشل: البحث الجغرافي لم يجد السائق المتصل';
  end if;

  v_trip := public.request_trip(
    p_pickup_lat => 33.3100, p_pickup_lng => 44.3600,
    p_dropoff_lat => 33.2850, p_dropoff_lng => 44.4050,
    p_pickup_address => 'الكرادة - قرب جامع بونية',
    p_dropoff_address => 'الجادرية - بوابة الجامعة',
    p_distance_m => 4200, p_duration_s => 780,
    p_note => 'أنا عند الباب الجانبي'
  );
  raise notice '[٤ب] الرحلة % أُنشئت بحالة % وأجرة مقدَّرة %',
    v_trip.trip_number, v_trip.status, v_trip.fare_estimated_iqd;

  -- ===========================================================================
  -- ٥) هل أرسل المحرك عرضاً للسائق تلقائياً؟
  -- ===========================================================================
  select * into v_offer from public.trip_offers where trip_id = v_trip.id;
  if not found then
    raise exception 'فشل: لم يُرسَل أي عرض — محرك المطابقة لم يعمل';
  end if;
  raise notice '[٥] عرض للسائق: ترتيب % | مسافة % م | وصول مقدَّر % ث',
    v_offer.rank, v_offer.distance_m, v_offer.eta_s;

  -- ===========================================================================
  -- ٦) السائق يقبل ثم يتقدّم بالرحلة
  -- ===========================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_driver, 'role', 'authenticated')::text, true);

  v_trip := public.accept_trip_offer(v_offer.id);
  raise notice '[٦أ] قُبلت — الحالة % في %', v_trip.status, v_trip.accepted_at;

  v_trip := public.advance_trip(v_trip.id, 'driver_arrived');
  v_trip := public.advance_trip(v_trip.id, 'in_progress');
  raise notice '[٦ب] وصل السائق ثم بدأت الرحلة ✓';

  -- ===========================================================================
  -- ٧) اختبار الحماية: هل تُرفض القفزات غير المنطقية؟
  -- ===========================================================================
  begin
    perform public.advance_trip(v_trip.id, 'driver_arrived');   -- رجوع للخلف
    raise exception 'فشل أمني: قُبل انتقال حالة غير مسموح!';
  exception when check_violation then
    raise notice '[٧] الرجوع بحالة الرحلة مرفوض كما يجب ✓';
  end;

  -- ===========================================================================
  -- ٨) إنهاء الرحلة وقيد العمولة
  -- ===========================================================================
  v_trip := public.complete_trip(v_trip.id, 4350, 810);
  raise notice '[٨أ] اكتملت — أجرة % | عمولة % | للسائق %',
    v_trip.fare_final_iqd, v_trip.commission_iqd, v_trip.driver_earning_iqd;

  select wallet_balance_iqd into v_balance from public.drivers where id = v_driver;
  if v_balance <> -v_trip.commission_iqd then
    raise exception 'فشل محاسبي: الرصيد % لا يساوي سالب العمولة %',
      v_balance, v_trip.commission_iqd;
  end if;
  raise notice '[٨ب] محفظة السائق % دينار (دين العمولة) ✓', v_balance;

  if (select status from public.drivers where id = v_driver) <> 'online' then
    raise exception 'فشل: السائق لم يعد للشبكة بعد الرحلة';
  end if;
  raise notice '[٨ج] السائق عاد متاحاً للرحلة التالية ✓';

  -- ===========================================================================
  -- ٩) التقييم
  -- ===========================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rider, 'role', 'authenticated')::text, true);

  insert into public.ratings (trip_id, rater_id, ratee_id, stars, comment)
  values (v_trip.id, v_rider, v_driver, 5, 'سائق محترم وسريع');

  raise notice '[٩] تقييم السائق: % من % تقييم',
    (select rating_avg from public.drivers where id = v_driver),
    (select rating_count from public.drivers where id = v_driver);

  raise notice '';
  raise notice '===== نجحت كل المراحل =====';
end $$;

-- =============================================================================
-- تقرير النتيجة
-- =============================================================================
select
  t.trip_number                       as "رقم الرحلة",
  t.status                            as "الحالة",
  t.actual_distance_m                 as "المسافة (م)",
  t.fare_final_iqd                    as "الأجرة",
  t.commission_iqd                    as "العمولة",
  t.driver_earning_iqd                as "حصة السائق",
  d.wallet_balance_iqd                as "رصيد المحفظة",
  d.rating_avg                        as "تقييم السائق",
  d.trips_completed                   as "رحلات مكتملة",
  extract(epoch from (t.completed_at - t.requested_at))::int as "الزمن الكلي (ث)"
from public.trips t
join public.drivers d on d.id = t.driver_id
join public.profiles p on p.id = t.rider_id
where p.email = 'rider@zanbour.test';
