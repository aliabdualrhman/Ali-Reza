-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0006 — محرك المطابقة (Dispatch Engine)
-- =============================================================================
-- كل الدوال هنا security definer: تعمل بصلاحيات عالية لأنها تعدّل جداول
-- لا يملك المستخدم صلاحية مباشرة عليها. لذلك كل دالة تتحقق بنفسها من هوية
-- المستدعي (auth.uid()) قبل أي شيء — هذا هو خط الدفاع الوحيد.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- تحديث موقع السائق. يُستدعى كل ٤-٥ ثوانٍ من تطبيق السائق.
--
-- أكثر دالة تُستدعى في النظام كله، لذا أبقيناها خفيفة جداً: تحديث صف واحد
-- بمفتاحه الأساسي، بلا استعلامات فرعية ولا انضمامات.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- تبديل حالة السائق بين متصل وغير متصل.
-- نمنع الاتصال إذا تجاوز دينه الحد أو لم تُعتمد وثائقه.
-- -----------------------------------------------------------------------------
create or replace function public.set_driver_online(p_online boolean)
returns public.driver_status
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  d public.drivers;
  v_min_balance numeric;
begin
  select * into d from public.drivers where id = auth.uid() for update;
  if not found then
    raise exception 'المستخدم الحالي ليس سائقاً';
  end if;

  if d.status = 'on_trip' then
    raise exception 'لا يمكن تغيير الحالة أثناء رحلة جارية';
  end if;

  if p_online then
    if d.verification_status <> 'approved' then
      raise exception 'حسابك قيد المراجعة — لم تُعتمد وثائقك بعد'
        using errcode = 'insufficient_privilege';
    end if;

    -- نأخذ أدنى حد مسموح من أي منطقة مفعّلة (نموذج مبسط لمرحلة MVP)
    select min(min_wallet_balance_iqd) into v_min_balance
    from public.pricing_zones where is_active;

    if d.wallet_balance_iqd < coalesce(v_min_balance, -25000) then
      raise exception 'رصيدك % دينار. سدّد العمولات المستحقة لتتمكن من الاتصال',
        d.wallet_balance_iqd
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  update public.drivers
  set status = case when p_online then 'online' else 'offline' end::public.driver_status
  where id = auth.uid()
  returning status into d.status;

  return d.status;
end;
$$;

-- -----------------------------------------------------------------------------
-- إيجاد أقرب السائقين المتاحين — الاستعلام الأهم في النظام.
--
-- st_dwithin(a, b, r) تسأل "هل المسافة بينهما أقل من r متر؟" وهي الدالة
-- الوحيدة التي تستطيع استخدام الفهرس المكاني GIST. لو كتبنا بدلاً منها
-- st_distance(a,b) < r لأجبرنا بوستغرس على حساب المسافة لكل صف في الجدول.
-- الفرق بين الاثنين هو الفرق بين ٥ مللي ثانية و ٥ ثوانٍ عند ألف سائق.
--
-- نستبعد أيضاً السائقين الذين انقطع تحديث موقعهم: التطبيق ربما أُغلق فجأة
-- والحالة بقيت online. موقع عمره دقيقتان لا يُعتمد عليه.
-- -----------------------------------------------------------------------------
create or replace function public.find_nearby_drivers(
  p_pickup     geography,
  p_radius_m   integer default 3000,
  p_limit      integer default 10,
  p_exclude    uuid[]  default '{}'
)
returns table (
  driver_id    uuid,
  distance_m   integer,
  rating_avg   numeric,
  full_name    text,
  vehicle_plate text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    d.id,
    st_distance(d.current_location, p_pickup)::integer as distance_m,
    d.rating_avg,
    p.full_name,
    d.vehicle_plate
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.is_available_for_matching
    and d.current_location is not null
    and d.location_updated_at > now() - interval '90 seconds'
    and not (d.id = any(p_exclude))
    and p.is_blocked = false
    and st_dwithin(d.current_location, p_pickup, p_radius_m)
    -- استبعاد من لديه رحلة نشطة أصلاً (حماية إضافية فوق حالة on_trip)
    and not exists (
      select 1 from public.trips t
      where t.driver_id = d.id
        and t.status in ('accepted', 'driver_arrived', 'in_progress')
    )
  order by st_distance(d.current_location, p_pickup)
  limit p_limit;
$$;

-- -----------------------------------------------------------------------------
-- تقدير أجرة رحلة قبل تأكيدها. يُستدعى من شاشة "تأكيد الرحلة".
-- -----------------------------------------------------------------------------
create or replace function public.estimate_trip(
  p_pickup_lat  double precision,
  p_pickup_lng  double precision,
  p_dropoff_lat double precision,
  p_dropoff_lng double precision,
  p_distance_m  integer,
  p_duration_s  integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_pickup  geography;
  v_zone_id uuid;
  v_drivers integer;
begin
  v_pickup := st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography;

  v_zone_id := public.zone_for_point(v_pickup);
  if v_zone_id is null then
    return jsonb_build_object(
      'available', false,
      'reason', 'out_of_service_area',
      'message', 'خدمتنا غير متوفرة في هذه المنطقة حالياً'
    );
  end if;

  select count(*) into v_drivers
  from public.find_nearby_drivers(v_pickup, 5000, 20);

  return public.calculate_fare(p_zone_id => v_zone_id,
                               p_distance_m => p_distance_m,
                               p_duration_s => p_duration_s)
         || jsonb_build_object(
              'available', true,
              'zone_id', v_zone_id,
              'nearby_drivers', v_drivers
            );
end;
$$;

-- -----------------------------------------------------------------------------
-- طلب رحلة جديدة. ينشئ الرحلة بحالة searching ثم يرسل أول عرض.
-- -----------------------------------------------------------------------------
create or replace function public.request_trip(
  p_pickup_lat      double precision,
  p_pickup_lng      double precision,
  p_dropoff_lat     double precision,
  p_dropoff_lng     double precision,
  p_pickup_address  text,
  p_dropoff_address text,
  p_distance_m      integer,
  p_duration_s      integer,
  p_payment_method  public.payment_method default 'cash',
  p_note            text default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_rider   public.profiles;
  v_pickup  geography;
  v_dropoff geography;
  v_zone_id uuid;
  v_fare    jsonb;
  v_trip    public.trips;
begin
  select * into v_rider from public.profiles where id = auth.uid();
  if not found or v_rider.is_blocked then
    raise exception 'غير مصرّح لك بطلب رحلة' using errcode = 'insufficient_privilege';
  end if;

  v_pickup  := st_setsrid(st_makepoint(p_pickup_lng,  p_pickup_lat),  4326)::geography;
  v_dropoff := st_setsrid(st_makepoint(p_dropoff_lng, p_dropoff_lat), 4326)::geography;

  v_zone_id := public.zone_for_point(v_pickup);
  if v_zone_id is null then
    raise exception 'نقطة الانطلاق خارج نطاق الخدمة';
  end if;

  v_fare := public.calculate_fare(v_zone_id, p_distance_m, p_duration_s);

  -- الفهرس الفريد trips_one_active_per_rider يمنع رحلتين نشطتين للراكب نفسه.
  -- نلتقط الخطأ ونحوّله لرسالة مفهومة بدل خطأ قاعدة بيانات خام.
  begin
    insert into public.trips (
      rider_id, pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note
    ) values (
      auth.uid(), v_pickup, p_pickup_address,
      v_dropoff, p_dropoff_address,
      p_distance_m, p_duration_s,
      (v_fare ->> 'total')::numeric,
      (v_fare ->> 'surge_multiplier')::numeric,
      v_fare,
      p_payment_method, p_note
    )
    returning * into v_trip;
  exception when unique_violation then
    raise exception 'لديك رحلة نشطة بالفعل' using errcode = 'unique_violation';
  end;

  -- أرسل العرض للسائق الأقرب
  perform public.dispatch_next_offer(v_trip.id);

  return v_trip;
end;
$$;

-- -----------------------------------------------------------------------------
-- إرسال العرض للسائق التالي في الطابور.
--
-- تُستدعى: عند إنشاء الرحلة، وعند رفض/انتهاء صلاحية عرض سابق.
-- توسّع نطاق البحث تدريجياً إن لم تجد أحداً قريباً.
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_next_offer(p_trip_id uuid)
returns public.trip_offers
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_trip     public.trips;
  v_zone     public.pricing_zones;
  v_tried    uuid[];
  v_rank     smallint;
  v_radius   integer;
  v_candidate record;
  v_offer    public.trip_offers;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;   -- الرحلة قُبلت أو أُلغيت بينما كنا نبحث
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  -- السائقون الذين عُرضت عليهم الرحلة سابقاً
  -- array[]::uuid[] وليس '{}' — بوستغرس لا يستطيع استنتاج نوع المصفوفة
  -- الفارغة داخل coalesce فيرفض الدالة بخطأ نوع غامض.
  select coalesce(array_agg(driver_id), array[]::uuid[]), count(*)
  into v_tried, v_rank
  from public.trip_offers where trip_id = p_trip_id;

  if v_rank >= v_zone.max_offers_per_trip then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  -- توسيع النطاق: كل ثلاث محاولات فاشلة نوسّع دائرة البحث
  v_radius := least(
    v_zone.search_radius_m * (1 + (v_rank / 3)),
    v_zone.max_search_radius_m
  );

  select * into v_candidate
  from public.find_nearby_drivers(v_trip.pickup_location, v_radius, 1, v_tried);

  if not found then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  insert into public.trip_offers (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
  values (
    p_trip_id,
    v_candidate.driver_id,
    v_rank + 1,
    v_candidate.distance_m,
    -- تقدير خشن: متوسط سرعة دراجة في المدينة ٢٥ كم/س ≈ ٦.٩ م/ث
    (v_candidate.distance_m / 6.9)::integer,
    now() + make_interval(secs => v_zone.offer_timeout_s)
  )
  returning * into v_offer;

  return v_offer;
end;
$$;

-- -----------------------------------------------------------------------------
-- قبول السائق للعرض — أخطر دالة من ناحية التزامن.
--
-- السيناريو الذي نحمي منه: سائقان يضغطان "قبول" في نفس الجزء من الثانية.
-- الحل طبقتان:
--   ١) نقفل صف الرحلة (for update) فيصطف الطلبان بدل أن يتوازيا.
--   ٢) نتحقق أن الحالة ما زالت searching بعد الحصول على القفل.
-- الثاني هو المهم: صاحب القفل الثاني سيجد الحالة accepted ويُرفض.
-- -----------------------------------------------------------------------------
create or replace function public.accept_trip_offer(p_offer_id uuid)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_offer public.trip_offers;
  v_trip  public.trips;
begin
  select * into v_offer from public.trip_offers where id = p_offer_id;
  if not found then
    raise exception 'العرض غير موجود';
  end if;

  if v_offer.driver_id <> auth.uid() then
    raise exception 'هذا العرض ليس لك' using errcode = 'insufficient_privilege';
  end if;

  if v_offer.status <> 'pending' then
    raise exception 'انتهت صلاحية هذا العرض';
  end if;

  if v_offer.expires_at < now() then
    update public.trip_offers set status = 'expired', responded_at = now()
    where id = p_offer_id;
    raise exception 'انتهت مهلة العرض';
  end if;

  -- القفل — من هنا يصطف المتنافسون
  select * into v_trip from public.trips where id = v_offer.trip_id for update;

  if v_trip.status <> 'searching' then
    update public.trip_offers set status = 'cancelled', responded_at = now()
    where id = p_offer_id;
    raise exception 'سبقك سائق آخر لهذه الرحلة';
  end if;

  update public.trips
  set status = 'accepted', driver_id = v_offer.driver_id
  where id = v_trip.id
  returning * into v_trip;

  update public.drivers set status = 'on_trip' where id = v_offer.driver_id;

  update public.trip_offers set status = 'accepted', responded_at = now()
  where id = p_offer_id;

  -- إبطال كل العروض الأخرى المعلّقة لهذه الرحلة
  update public.trip_offers set status = 'cancelled', responded_at = now()
  where trip_id = v_trip.id and status = 'pending' and id <> p_offer_id;

  return v_trip;
end;
$$;

-- -----------------------------------------------------------------------------
-- رفض العرض — ينتقل فوراً للسائق التالي بدل انتظار انتهاء المهلة.
-- -----------------------------------------------------------------------------
create or replace function public.reject_trip_offer(p_offer_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_offer public.trip_offers;
begin
  select * into v_offer from public.trip_offers
  where id = p_offer_id and driver_id = auth.uid() and status = 'pending';

  if not found then
    raise exception 'العرض غير موجود أو انتهت صلاحيته';
  end if;

  update public.trip_offers set status = 'rejected', responded_at = now()
  where id = p_offer_id;

  perform public.dispatch_next_offer(v_offer.trip_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- تقدّم الرحلة: وصول السائق، ثم بدء الرحلة.
-- دالة واحدة للانتقالين لأن التحقق من الصلاحية متطابق.
-- -----------------------------------------------------------------------------
create or replace function public.advance_trip(
  p_trip_id uuid,
  p_to      public.trip_status
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_trip public.trips;
begin
  if p_to not in ('driver_arrived', 'in_progress') then
    raise exception 'استخدم complete_trip أو cancel_trip لهذه الحالة';
  end if;

  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك' using errcode = 'insufficient_privilege';
  end if;

  -- المُشغّل enforce_trip_transition يرفض الانتقالات غير المنطقية
  update public.trips set status = p_to where id = p_trip_id
  returning * into v_trip;

  return v_trip;
end;
$$;

-- -----------------------------------------------------------------------------
-- إنهاء الرحلة: يحسب الأجرة النهائية ويقيّد العمولة على محفظة السائق.
--
-- ملاحظة جوهرية للسوق العراقي: الدفع نقدي، فالسائق يقبض كامل الأجرة بيده.
-- لذلك لا نضيف له أرباحاً — بل نخصم العمولة من محفظته كدين للمنصة.
-- عندما يسدّد لاحقاً يُسجَّل topup فيعود رصيده نحو الصفر.
-- -----------------------------------------------------------------------------
create or replace function public.complete_trip(
  p_trip_id          uuid,
  p_actual_distance_m integer default null,
  p_actual_duration_s integer default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_trip  public.trips;
  v_zone  uuid;
  v_fare  jsonb;
  v_dist  integer;
  v_dur   integer;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك' using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status <> 'in_progress' then
    raise exception 'لا يمكن إنهاء رحلة حالتها %', v_trip.status;
  end if;

  v_dist := coalesce(p_actual_distance_m, v_trip.estimated_distance_m);
  v_dur  := coalesce(
    p_actual_duration_s,
    extract(epoch from (now() - v_trip.started_at))::integer,
    v_trip.estimated_duration_s
  );

  v_zone := public.zone_for_point(v_trip.pickup_location);

  -- نعيد الحساب بالمعامل المجمّد وقت الطلب — لا يجوز أن يتغير سعر الذروة
  -- على الراكب بعد أن وافق عليه.
  v_fare := public.calculate_fare(v_zone, v_dist, v_dur, v_trip.surge_multiplier);

  update public.trips
  set status             = 'completed',
      actual_distance_m  = v_dist,
      actual_duration_s  = v_dur,
      fare_final_iqd     = (v_fare ->> 'total')::numeric,
      commission_iqd     = (v_fare ->> 'commission')::numeric,
      driver_earning_iqd = (v_fare ->> 'driver_earning')::numeric,
      fare_breakdown     = v_fare,
      payment_status     = case when v_trip.payment_method = 'cash'
                                then 'paid'::public.payment_status
                                else 'pending'::public.payment_status end
  where id = p_trip_id
  returning * into v_trip;

  -- نرفع علم تجاوز الحُرّاس: هذا تعديل نظامي موثوق، لا من المستخدم.
  perform set_config('app.bypass_guards', 'on', true);

  update public.drivers
  set status          = 'online',
      trips_completed = trips_completed + 1
  where id = v_trip.driver_id;

  perform set_config('app.bypass_guards', 'off', true);


  -- قيد العمولة كدين على السائق (سالب)
  perform public.post_wallet_transaction(
    p_driver_id   => v_trip.driver_id,
    p_txn_type    => 'commission',
    p_amount_iqd  => -v_trip.commission_iqd,
    p_trip_id     => v_trip.id,
    p_description => format('عمولة الرحلة رقم %s', v_trip.trip_number)
  );

  return v_trip;
end;
$$;

-- -----------------------------------------------------------------------------
-- إلغاء الرحلة من الراكب أو السائق.
-- رسوم الإلغاء تُطبَّق على الراكب فقط بعد قبول السائق وانتهاء مهلة السماح.
-- -----------------------------------------------------------------------------
create or replace function public.cancel_trip(
  p_trip_id uuid,
  p_reason  text default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_trip public.trips;
  v_zone public.pricing_zones;
  v_is_rider boolean;
  v_fee numeric(10,2) := 0;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'الرحلة غير موجودة';
  end if;

  v_is_rider := (v_trip.rider_id = auth.uid());

  if not v_is_rider and v_trip.driver_id is distinct from auth.uid() then
    raise exception 'لا تملك صلاحية إلغاء هذه الرحلة' using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status in ('completed', 'cancelled') then
    raise exception 'الرحلة منتهية بالفعل';
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  -- رسوم الإلغاء: على الراكب فقط، وفقط إذا كان السائق قد تحرك نحوه
  -- وتجاوز مهلة الإلغاء المجاني.
  if v_is_rider
     and v_trip.status in ('accepted', 'driver_arrived')
     and v_trip.accepted_at is not null
     and now() > v_trip.accepted_at + make_interval(secs => v_zone.free_cancel_window_s)
  then
    v_fee := v_zone.cancellation_fee_iqd;
  end if;

  update public.trips
  set status               = 'cancelled',
      cancelled_by         = auth.uid(),
      cancellation_reason  = p_reason,
      cancellation_fee_iqd = v_fee
  where id = p_trip_id
  returning * into v_trip;

  -- إبطال العروض المعلّقة
  update public.trip_offers set status = 'cancelled', responded_at = now()
  where trip_id = p_trip_id and status = 'pending';

  -- إعادة السائق للشبكة
  if v_trip.driver_id is not null then
    update public.drivers
    set status = case when status = 'on_trip' then 'online' else status end,
        trips_cancelled = trips_cancelled + case when not v_is_rider then 1 else 0 end
    where id = v_trip.driver_id;

    -- رسوم الإلغاء تذهب للسائق تعويضاً عن وقته
    if v_fee > 0 then
      perform public.post_wallet_transaction(
        p_driver_id   => v_trip.driver_id,
        p_txn_type    => 'cancellation_fee',
        p_amount_iqd  => v_fee,
        p_trip_id     => v_trip.id,
        p_description => format('تعويض إلغاء الرحلة رقم %s', v_trip.trip_number)
      );
    end if;
  end if;

  return v_trip;
end;
$$;

-- -----------------------------------------------------------------------------
-- تنظيف العروض المنتهية ودفع الرحلات العالقة للسائق التالي.
-- يُشغَّل كل ٥ ثوانٍ عبر pg_cron أو Edge Function مجدولة.
-- -----------------------------------------------------------------------------
create or replace function public.expire_stale_offers()
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_trip_id uuid;
  v_count integer := 0;
begin
  for v_trip_id in
    update public.trip_offers
    set status = 'expired', responded_at = now()
    where status = 'pending' and expires_at < now()
    returning trip_id
  loop
    perform public.dispatch_next_offer(v_trip_id);
    v_count := v_count + 1;
  end loop;

  -- سائق أغلق التطبيق دون تسجيل خروج: نفصله بعد انقطاع الموقع دقيقتين
  update public.drivers
  set status = 'offline'
  where status = 'online'
    and (location_updated_at is null or location_updated_at < now() - interval '2 minutes');

  return v_count;
end;
$$;
