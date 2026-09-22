-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0004 — الرحلات والعروض والمسارات
-- =============================================================================

create table public.trips (
  id                uuid primary key default gen_random_uuid(),

  -- رقم قصير يقرأه الراكب والسائق ("رحلة رقم 10432") — أسهل من UUID للدعم الفني
  trip_number       bigint generated always as identity (start with 10000),

  rider_id          uuid not null references public.profiles(id) on delete restrict,
  driver_id         uuid          references public.drivers(id)  on delete restrict,

  status            public.trip_status not null default 'searching',

  -- ---------------------------------------------------------------------------
  -- الجغرافيا
  -- ---------------------------------------------------------------------------
  pickup_location   geography(Point, 4326) not null,
  pickup_address    text,
  dropoff_location  geography(Point, 4326) not null,
  dropoff_address   text,

  -- المسار المقترح وقت الطلب (من خدمة التوجيه) لعرضه على الخريطة
  planned_route     geography(LineString, 4326),

  -- ---------------------------------------------------------------------------
  -- القياسات: تقدير وقت الطلب مقابل الفعلي بعد الانتهاء
  -- ---------------------------------------------------------------------------
  estimated_distance_m  integer,
  estimated_duration_s  integer,
  actual_distance_m     integer,
  actual_duration_s     integer,

  -- ---------------------------------------------------------------------------
  -- المال — كل المبالغ بالدينار العراقي
  --
  -- نجمّد قواعد التسعير المستعملة داخل الرحلة (fare_breakdown) بدل الإشارة
  -- لجدول الأسعار. لو غيّرنا التسعيرة غداً يجب ألا تتغير فاتورة رحلة الأمس.
  -- ---------------------------------------------------------------------------
  fare_estimated_iqd    numeric(10,2),
  fare_final_iqd        numeric(10,2),
  surge_multiplier      numeric(4,2) not null default 1.00,
  commission_iqd        numeric(10,2),   -- حصة المنصة
  driver_earning_iqd    numeric(10,2),   -- حصة السائق = fare_final - commission
  fare_breakdown        jsonb,           -- لقطة من قواعد التسعير وقت الحساب

  payment_method        public.payment_method not null default 'cash',
  payment_status        public.payment_status not null default 'pending',

  -- ---------------------------------------------------------------------------
  -- الطوابع الزمنية — كل انتقال حالة يُسجَّل. أساس كل التقارير لاحقاً.
  -- ---------------------------------------------------------------------------
  requested_at      timestamptz not null default now(),
  accepted_at       timestamptz,
  driver_arrived_at timestamptz,
  started_at        timestamptz,
  completed_at      timestamptz,
  cancelled_at      timestamptz,

  cancelled_by      uuid references public.profiles(id),
  cancellation_reason text,
  cancellation_fee_iqd numeric(10,2) not null default 0,

  rider_note        text,               -- "أنا عند باب المستشفى الجانبي"

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  -- الرحلة المكتملة يجب أن يكون لها سائق وأجرة نهائية
  constraint trips_completed_needs_driver check (
    status <> 'completed' or (driver_id is not null and fare_final_iqd is not null)
  ),
  constraint trips_surge_range check (surge_multiplier between 1.00 and 5.00)
);

comment on table public.trips is 'الرحلة — الكيان المركزي. كل انتقال حالة يُسجَّل بطابع زمني.';

create index trips_rider_idx    on public.trips (rider_id, requested_at desc);
create index trips_driver_idx   on public.trips (driver_id, requested_at desc);
create index trips_status_idx   on public.trips (status);
-- فهرس جزئي للرحلات النشطة فقط — يُستعلم عنه باستمرار وهي قليلة العدد
create index trips_active_idx   on public.trips (status, requested_at)
  where status in ('searching', 'accepted', 'driver_arrived', 'in_progress');
create index trips_pickup_gist  on public.trips using gist (pickup_location);

-- الراكب لا يملك أكثر من رحلة نشطة واحدة في نفس الوقت.
-- فهرس فريد جزئي — أبسط وأمتن من فحصها بمُشغّل.
create unique index trips_one_active_per_rider
  on public.trips (rider_id)
  where status in ('searching', 'accepted', 'driver_arrived', 'in_progress');

-- وكذلك السائق: رحلة واحدة فقط في الوقت الواحد.
create unique index trips_one_active_per_driver
  on public.trips (driver_id)
  where driver_id is not null
    and status in ('accepted', 'driver_arrived', 'in_progress');

create trigger trips_touch_updated_at
  before update on public.trips
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- منع الرحلات الوهمية القصيرة جداً (أقل من ١٠٠ متر بين الانطلاق والوجهة).
-- كتبناها كمُشغّل لا كقيد check لأن قيود check لا تقبل دوال PostGIS
-- في بعض إصدارات بوستغرس (تُعتبر غير ثابتة عبر الإصدارات).
-- -----------------------------------------------------------------------------
create or replace function public.validate_trip_distance()
returns trigger
language plpgsql
as $$
begin
  if st_distance(new.pickup_location, new.dropoff_location) < 100 then
    raise exception 'المسافة بين نقطة الانطلاق والوجهة قصيرة جداً (أقل من ١٠٠ متر)'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger trips_validate_distance
  before insert on public.trips
  for each row execute function public.validate_trip_distance();

-- -----------------------------------------------------------------------------
-- فرض دورة حياة الرحلة داخل قاعدة البيانات.
--
-- لماذا هنا وليس في تطبيق Flutter؟ لأن التطبيق يعمل على جهاز المستخدم ولا
-- يمكن الوثوق به. سائق بتطبيق معدَّل يستطيع إرسال "الرحلة اكتملت" مباشرة
-- بعد القبول ليقبض أجرة رحلة لم تحدث. القاعدة هي الحكم الأخير.
-- -----------------------------------------------------------------------------
create or replace function public.enforce_trip_transition()
returns trigger
language plpgsql
as $$
declare
  allowed public.trip_status[];
begin
  if new.status = old.status then
    return new;
  end if;

  allowed := case old.status
    when 'searching'      then array['accepted', 'no_drivers', 'cancelled']
    when 'no_drivers'     then array['searching', 'cancelled']
    when 'accepted'       then array['driver_arrived', 'cancelled']
    when 'driver_arrived' then array['in_progress', 'cancelled']
    when 'in_progress'    then array['completed', 'cancelled']
    when 'completed'      then array[]::text[]
    when 'cancelled'      then array[]::text[]
  end::public.trip_status[];

  if not (new.status = any(allowed)) then
    raise exception 'انتقال حالة غير مسموح للرحلة %: من % إلى %',
      old.id, old.status, new.status
      using errcode = 'check_violation';
  end if;

  -- ختم الطابع الزمني المناسب تلقائياً — لا نثق بالتطبيق في تحديده
  case new.status
    when 'accepted'       then new.accepted_at       := now();
    when 'driver_arrived' then new.driver_arrived_at := now();
    when 'in_progress'    then new.started_at        := now();
    when 'completed'      then new.completed_at      := now();
    when 'cancelled'      then new.cancelled_at      := now();
    else null;
  end case;

  return new;
end;
$$;

create trigger trips_enforce_transition
  before update of status on public.trips
  for each row execute function public.enforce_trip_transition();

-- =============================================================================
-- عروض الرحلة — حلقة المطابقة
-- =============================================================================
-- لا نرسل الطلب لكل السائقين دفعة واحدة (يسبب تسابقاً وقبولات متزامنة).
-- نرسله لأقرب سائق، ننتظر ١٥ ثانية، فإن لم يقبل ننتقل للتالي. هذا الجدول
-- يسجّل كل عرض — ومنه نقيس معدل قبول كل سائق لاحقاً.
-- =============================================================================
create table public.trip_offers (
  id            uuid primary key default gen_random_uuid(),
  trip_id       uuid not null references public.trips(id)   on delete cascade,
  driver_id     uuid not null references public.drivers(id) on delete cascade,

  status        public.offer_status not null default 'pending',
  rank          smallint not null,        -- ترتيب السائق في حلقة البحث (1 = الأقرب)
  distance_m    integer,                  -- بعده عن نقطة الانطلاق وقت العرض
  eta_s         integer,                  -- الوقت المقدّر لوصوله

  sent_at       timestamptz not null default now(),
  expires_at    timestamptz not null,
  responded_at  timestamptz,

  -- لا نعرض نفس الرحلة على نفس السائق مرتين
  unique (trip_id, driver_id)
);

create index trip_offers_trip_idx    on public.trip_offers (trip_id, rank);
create index trip_offers_driver_idx  on public.trip_offers (driver_id, sent_at desc);
-- للعامل الدوري الذي ينهي العروض المنتهية صلاحيتها
create index trip_offers_pending_idx on public.trip_offers (expires_at)
  where status = 'pending';

-- =============================================================================
-- فُتات المسار — نقاط الموقع أثناء الرحلة
-- =============================================================================
-- نستعملها لثلاثة أشياء: رسم المسار الفعلي، حساب المسافة الحقيقية للأجرة،
-- وحلّ النزاعات ("السائق أخذني بطريق أطول").
-- =============================================================================
create table public.trip_locations (
  id          bigint generated always as identity primary key,
  trip_id     uuid not null references public.trips(id) on delete cascade,
  location    geography(Point, 4326) not null,
  heading     smallint,
  speed_kmh   smallint,
  recorded_at timestamptz not null default now()
);

create index trip_locations_trip_idx on public.trip_locations (trip_id, recorded_at);

-- =============================================================================
-- التقييمات
-- =============================================================================
create table public.ratings (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references public.trips(id) on delete cascade,
  rater_id   uuid not null references public.profiles(id) on delete cascade,
  ratee_id   uuid not null references public.profiles(id) on delete cascade,
  stars      smallint not null check (stars between 1 and 5),
  comment    text,
  created_at timestamptz not null default now(),

  -- تقييم واحد لكل طرف في كل رحلة
  unique (trip_id, rater_id)
);

create index ratings_ratee_idx on public.ratings (ratee_id);

-- -----------------------------------------------------------------------------
-- تحديث متوسط تقييم السائق تدريجياً بدل إعادة حسابه من كل الصفوف.
-- المتوسط الجديد = (المتوسط القديم × العدد + التقييم الجديد) ÷ (العدد + 1)
-- -----------------------------------------------------------------------------
create or replace function public.apply_driver_rating()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  -- نرفع علم تجاوز الحُرّاس: هذا تعديل نظامي موثوق، لا من المستخدم.
  perform set_config('app.bypass_guards', 'on', true);

  update public.drivers
  set rating_avg = round(
        ((rating_avg * rating_count) + new.stars)::numeric / (rating_count + 1),
        2
      ),
      rating_count = rating_count + 1
  where id = new.ratee_id;

  perform set_config('app.bypass_guards', 'off', true);

  return new;
end;
$$;

create trigger ratings_apply_to_driver
  after insert on public.ratings
  for each row execute function public.apply_driver_rating();
