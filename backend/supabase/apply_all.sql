-- =============================================================================
-- زنبور — المخطط الكامل لقاعدة البيانات
-- =============================================================================
-- ملف مُجمَّع آلياً من ملفات الترحيل بترتيبها الصحيح.
-- الصقه كاملاً في: Supabase → SQL Editor → New query → Run
-- =============================================================================



-- ##########################################################################
-- ملف: 0001_extensions_and_enums.sql
-- ##########################################################################

-- =============================================================================
-- 0001 — الإضافات والأنواع المعرّفة (Extensions & Enums)
-- =============================================================================
-- postgis: يضيف نوع البيانات الجغرافي geography ودوال المسافة والبحث المكاني.
--          بدونه لا يمكن السؤال "من هم أقرب السائقين؟" بكفاءة.
-- =============================================================================

create extension if not exists postgis      with schema extensions;
create extension if not exists pgcrypto     with schema extensions;  -- gen_random_uuid()
create extension if not exists pg_trgm      with schema extensions;  -- بحث نصي للعناوين

-- -----------------------------------------------------------------------------
-- الأدوار: راكب، سائق، مشرف
-- -----------------------------------------------------------------------------
create type public.user_role as enum ('rider', 'driver', 'admin');

-- -----------------------------------------------------------------------------
-- حالة السائق اللحظية.
--   offline  = مغلق التطبيق أو أوقف الاستقبال، لا يستقبل عروضاً
--   online   = متاح وينتظر رحلة
--   on_trip  = مرتبط برحلة حالياً
-- -----------------------------------------------------------------------------
create type public.driver_status as enum ('offline', 'online', 'on_trip');

-- -----------------------------------------------------------------------------
-- حالة التحقق من وثائق السائق. لا يُسمح له بالعمل إلا بحالة approved.
-- -----------------------------------------------------------------------------
create type public.verification_status as enum ('pending', 'approved', 'rejected', 'suspended');

-- -----------------------------------------------------------------------------
-- دورة حياة الرحلة — العمود الفقري للتطبيق كله.
--
--   searching        الراكب طلب، النظام يبحث عن سائق
--   no_drivers       انتهى البحث بلا نتيجة
--   accepted         سائق قبل الطلب وهو في طريقه للراكب
--   driver_arrived   السائق وصل نقطة الانطلاق وينتظر
--   in_progress      الراكب ركب والرحلة جارية
--   completed        وصلوا الوجهة وتم احتساب الأجرة
--   cancelled        أُلغيت من الراكب أو السائق أو النظام
--
-- الانتقالات المسموحة تُفرض بمُشغّل (trigger) في 0004 — لا نعتمد على التطبيق.
-- -----------------------------------------------------------------------------
create type public.trip_status as enum (
  'searching', 'no_drivers', 'accepted', 'driver_arrived',
  'in_progress', 'completed', 'cancelled'
);

-- -----------------------------------------------------------------------------
-- حالة العرض المُرسل لسائق معيّن (حلقة المطابقة).
-- -----------------------------------------------------------------------------
create type public.offer_status as enum ('pending', 'accepted', 'rejected', 'expired', 'cancelled');

-- -----------------------------------------------------------------------------
-- طرق الدفع. في العراق النقد هو الأساس — لذلك هو القيمة الافتراضية.
-- wallet = رصيد الراكب داخل التطبيق (شحن مسبق)
-- -----------------------------------------------------------------------------
create type public.payment_method as enum ('cash', 'wallet', 'card');
create type public.payment_status as enum ('pending', 'paid', 'failed', 'refunded');

-- -----------------------------------------------------------------------------
-- أنواع حركات محفظة السائق.
--   trip_earning     ما استحقه السائق من رحلة
--   commission       عمولة المنصة (تُخصم، قيمة سالبة)
--   topup            شحن رصيد من السائق لتغطية العمولات
--   payout           تحويل أرباح للسائق
--   adjustment       تصحيح يدوي من الإدارة
-- -----------------------------------------------------------------------------
create type public.wallet_txn_type as enum (
  'trip_earning', 'commission', 'topup', 'payout', 'adjustment', 'cancellation_fee'
);

-- -----------------------------------------------------------------------------
-- أنواع الوثائق.
--
--   live_selfie          صورة حية يلتقطها المستخدم بالكاميرا وقت التسجيل.
--                        مطلوبة من **الجميع** — راكباً كان أم سائقاً.
--   national_id_front    صورة وجه البطاقة الوطنية — للسائقين فقط
--   national_id_back     صورة ظهر البطاقة الوطنية — للسائقين فقط
--   driving_license      إجازة السوق
--   vehicle_registration سنوية الدراجة
--   insurance            وثيقة التأمين
-- -----------------------------------------------------------------------------
create type public.document_type as enum (
  'live_selfie', 'national_id_front', 'national_id_back', 'vehicle_photo',
  'driving_license', 'vehicle_registration', 'insurance'
);


-- ##########################################################################
-- ملف: 0002_profiles.sql
-- ##########################################################################

-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0002 — الملفات الشخصية (Profiles)
-- =============================================================================
-- Supabase يخزّن بيانات الدخول في جدول محمي اسمه auth.users لا نعدّله مباشرة.
-- نبني جدول profiles موازياً له بنفس المعرّف (id) لنضع فيه بياناتنا.
--
-- نموذج الحساب المعتمد:
--
--   التسجيل   بريد + كلمة مرور، ثم رسالة تأكيد تصل للبريد
--             + الاسم الثلاثي + تاريخ الميلاد + العنوان + رقم الهاتف
--             + صورة حية للوجه
--             ويضيف السائق: صورتَي البطاقة الوطنية (وجه وظهر)
--                          + نوع الدراجة + صورها
--
--   الاعتماد  الراكب يُعتمد تلقائياً. السائق ينتظر موافقة المدير يدوياً.
--
--   الدخول    بريد + كلمة مرور فقط — بلا رمز ولا رسالة
--
--   نسيان     رابط استعادة يُرسل إلى البريد
--
-- كلمات المرور تديرها Supabase Auth في جدول auth.users ولا نراها إطلاقاً —
-- تُخزَّن مُجزّأة (hashed) ولا يمكن استرجاعها، ولذلك الاستعادة تكون بإعادة
-- تعيين لا بإرسال كلمة المرور القديمة.
--
-- **لماذا التوثيق بالبريد لا الهاتف؟** رسائل البريد مجانية عملياً بينما كل
-- رسالة SMS تكلّف، وكل مستخدم أندرويد يملك بريداً بالضرورة لأنه شرط لتحميل
-- التطبيقات من Play Store. والتوثيق يحدث **مرة واحدة عند التسجيل** لا في
-- كل دخول، فالكلفة تقترب من الصفر.
--
-- رقم الهاتف يُجمع كـ **بيان وظيفي** لا كوسيلة توثيق: السائق يحتاجه ليتصل
-- بالراكب حين لا يجده. لذلك هو غير موثّق افتراضياً (phone_verified = false).
-- =============================================================================

create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,

  -- ---------------------------------------------------------------------------
  -- الهوية
  -- ---------------------------------------------------------------------------
  -- الاسم الثلاثي — **فريد**.
  --
  -- تنبيه: تكرار الاسم الثلاثي شائع فعلاً ("محمد علي حسن" قد يكون شخصين
  -- مختلفين). هذا القيد سيمنع الثاني من التسجيل. أُضيف بقرار صريح؛
  -- لإلغائه احذف كلمة unique من هذا السطر ولا شيء غيرها.
  --
  -- نوحّد الفراغات قبل الحفظ في handle_new_user، وإلا مرّ "محمد  علي حسن"
  -- بفراغين كاسم مختلف عن "محمد علي حسن" وسقط شرط التفرّد.
  full_name     text not null unique,

  email         text not null unique,

  -- **لا نخزّن رقم البطاقة الوطنية.** السائق يرفع صورتَي بطاقته (وجه وظهر)
  -- والمدير يتحقق منهما بصرياً وقت المراجعة، وينتهي الأمر.
  --
  -- الأثر المترتب: لا توجد وسيلة آلية تمنع شخصاً من فتح حسابَي سائق
  -- ببطاقة واحدة — تُكتشف بالعين عند المراجعة. مقبول عند عشرات السائقين،
  -- ويحتاج إعادة نظر عند المئات.

  -- تاريخ الميلاد. نتحقق من العمر في handle_new_user لا بقيد check،
  -- لأن حساب العمر يحتاج now() وقيود check لا تقبل الدوال غير الثابتة.
  date_of_birth date not null,

  -- العنوان كما يكتبه المستخدم — نص حر لا إحداثيات.
  address       text not null,

  -- هل اكتمل التحقق من الهوية (قُبلت الصورة الحية)؟
  -- يُحدَّث آلياً من مُشغّل على user_documents في 0003.
  identity_verified boolean not null default false,

  -- رقم الهاتف — **إلزامي** لكل مستخدم، راكباً كان أم سائقاً.
  --
  -- هو وسيلة الاتصال الوحيدة بين طرفي الرحلة: السائق يتصل بالراكب حين لا
  -- يجده عند نقطة الانطلاق، والراكب يتصل بالسائق إن تأخر. رحلة بلا رقم
  -- هاتف لأحد الطرفين رحلة معطوبة.
  --
  -- إلزامي لكنه **غير موثّق** — لا نرسل إليه رمزاً. التوثيق يتم بالبريد.
  -- علم phone_verified محجوز لو قررنا لاحقاً توثيق أرقام السائقين وحدهم.
  --
  -- **فريد**: لا يُسجَّل رقم واحد لحسابين. هذا خط الدفاع الأساسي ضد تعدد
  -- الحسابات بعد إلغاء تخزين رقم البطاقة.
  --
  -- الأثر: عائلة تتشارك هاتفاً واحداً لن تستطيع فتح حسابين. مقبول لأن
  -- الرقم وسيلة الاتصال بين طرفي الرحلة ولا يصح أن يشير إلى شخصين.
  --
  -- التفرّد يعمل على الصيغة الموحّدة E.164، فلا يمرّ نفس الرقم بصيغتين.
  phone           text not null unique,
  phone_verified  boolean not null default false,

  avatar_url    text,
  role          public.user_role not null default 'rider',

  -- الحظر يمنع الدخول للخدمة دون حذف الحساب (نحتاج سجل الرحلات للمحاسبة)
  is_blocked    boolean not null default false,
  blocked_reason text,

  -- اللغة المفضلة للإشعارات: ar (افتراضي) أو en أو ku
  locale        text not null default 'ar',

  -- رمز جهاز الإشعارات (Firebase Cloud Messaging)
  fcm_token     text,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- أرقام الهواتف العراقية: +9647XXXXXXXXX  (٧٥٠ ,٧٧٠ ,٧٨٠ ...)
  constraint profiles_phone_iraqi_format
    check (phone ~ '^\+9647[3-9][0-9]{8}$'),

  -- تاريخ ميلاد منطقي: ليس في المستقبل ولا قبل ١٢٠ سنة.
  -- '1900-01-01' ثابت لا دالة، فيُقبل في قيد check.
  constraint profiles_dob_sane
    check (date_of_birth > date '1900-01-01' and date_of_birth < date '2030-01-01'),

  constraint profiles_address_not_blank
    check (length(btrim(address)) >= 5),

  -- الاسم الثلاثي: ثلاث كلمات على الأقل.
  constraint profiles_full_name_triple
    check (array_length(regexp_split_to_array(btrim(full_name), '\s+'), 1) >= 3)
);

comment on table public.profiles is 'بيانات المستخدم العامة، مرتبطة ١:١ مع auth.users';
comment on column public.profiles.phone is
  'رقم الهاتف بصيغة E.164، مثال: +9647701234567. إلزامي وغير موثّق — للاتصال بين طرفي الرحلة.';
comment on column public.profiles.email is
  'البريد الإلكتروني — وسيلة التوثيق المعتمدة (رمز يُرسل إليه).';

create index profiles_role_idx  on public.profiles (role);
create index profiles_phone_idx on public.profiles (phone);

-- -----------------------------------------------------------------------------
-- تحديث updated_at تلقائياً عند أي تعديل.
-- دالة عامة نعيد استخدامها في كل الجداول.
-- -----------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- عند تسجيل مستخدم جديد في auth.users نُنشئ له profile تلقائياً.
-- بقية البيانات تصل عبر raw_user_meta_data من التطبيق وقت التسجيل.
--
-- security definer: تعمل بصلاحيات مالك الدالة لأن التريغر يعمل على جدول
-- محمي (auth.users) لا يملك المستخدم العادي صلاحية الكتابة في مخططنا منه.
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  requested_role public.user_role;
  v_full_name    text;
  v_phone        text;
  v_dob          date;
  v_address      text;
  v_age          integer;
begin
  -- نقبل rider أو driver فقط من التطبيق. admin يُمنح يدوياً من قاعدة البيانات،
  -- وإلا لاستطاع أي شخص ترقية نفسه لمشرف وقت التسجيل.
  requested_role := coalesce(
    nullif(new.raw_user_meta_data ->> 'role', '')::public.user_role,
    'rider'
  );
  if requested_role = 'admin' then
    requested_role := 'rider';
  end if;

  -- توحيد الاسم: نقصّ الأطراف ونحوّل أي تتابع فراغات إلى فراغ واحد.
  v_full_name := nullif(
    regexp_replace(btrim(new.raw_user_meta_data ->> 'full_name'), '\s+', ' ', 'g'),
    '');
  v_address   := nullif(btrim(new.raw_user_meta_data ->> 'address'), '');

  begin
    v_dob := (new.raw_user_meta_data ->> 'date_of_birth')::date;
  exception when others then
    raise exception 'تاريخ الميلاد غير صالح — الصيغة المطلوبة YYYY-MM-DD';
  end;

  -- توحيد صيغة الهاتف: نقبل 07701234567 أو 9647701234567 أو +9647701234567
  -- ونخزّنها جميعاً بصيغة E.164 واحدة، وإلا تعذّر البحث والمطابقة.
  v_phone := regexp_replace(coalesce(new.raw_user_meta_data ->> 'phone', ''), '[^0-9]', '', 'g');
  if v_phone ~ '^07[3-9][0-9]{8}$' then
    v_phone := '+964' || substring(v_phone from 2);
  elsif v_phone ~ '^9647[3-9][0-9]{8}$' then
    v_phone := '+' || v_phone;
  elsif v_phone ~ '^7[3-9][0-9]{8}$' then
    v_phone := '+964' || v_phone;
  else
    v_phone := null;
  end if;

  if v_full_name is null then
    raise exception 'الاسم الكامل مطلوب للتسجيل';
  end if;

  if v_phone is null then
    raise exception 'رقم هاتف عراقي صحيح مطلوب للتسجيل';
  end if;

  if v_address is null then
    raise exception 'العنوان مطلوب للتسجيل';
  end if;

  if v_dob is null then
    raise exception 'تاريخ الميلاد مطلوب للتسجيل';
  end if;

  -- التحقق من العمر. السائق يقود مركبة وينقل ركّاباً فحدّه ١٨،
  -- والراكب ١٦. القاعدة هي الحكم لا شاشة التسجيل.
  v_age := extract(year from age(current_date, v_dob))::integer;
  if requested_role = 'driver' and v_age < 18 then
    raise exception 'العمر الأدنى لتسجيل السائق ١٨ سنة';
  elsif v_age < 16 then
    raise exception 'العمر الأدنى للتسجيل ١٦ سنة';
  end if;

  -- نلتقط تعارض التفرّد ونحوّله لرسالة يفهمها المستخدم، بدل خطأ خام
  -- من قاعدة البيانات يظهر له كنص إنجليزي غامض.
  if exists (select 1 from public.profiles where phone = v_phone) then
    raise exception 'رقم الهاتف مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;
  if exists (select 1 from public.profiles where full_name = v_full_name) then
    raise exception 'الاسم مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;

  insert into public.profiles (
    id, full_name, email, date_of_birth, address, phone, role, locale
  )
  values (
    new.id,
    v_full_name,
    new.email,
    v_dob,
    v_address,
    v_phone,
    requested_role,
    coalesce(nullif(new.raw_user_meta_data ->> 'locale', ''), 'ar')
  );

  -- السائق يحتاج سجلاً في جدول drivers ليبدأ رحلة التحقق من الوثائق
  if requested_role = 'driver' then
    insert into public.drivers (id, vehicle_type)
    values (new.id, nullif(btrim(new.raw_user_meta_data ->> 'vehicle_type'), ''));
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- دوال مساعدة نستعملها كثيراً في سياسات الأمان (RLS) لاحقاً.
-- stable = لا تعدّل البيانات، يسمح لبوستغرس بتخزين نتيجتها ضمن الاستعلام الواحد.
--
-- security definer مقصود هنا: يجعلها تتجاوز RLS فلا تقع في تكرار لانهائي
-- حين تُستدعى من داخل سياسة مطبَّقة على نفس الجدول.
-- -----------------------------------------------------------------------------
create or replace function public.current_role_is(target public.user_role)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = target and is_blocked = false
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select public.current_role_is('admin');
$$;


-- ##########################################################################
-- ملف: 0003_drivers.sql
-- ##########################################################################

-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0003 — السائقون والمركبات والوثائق
-- =============================================================================

create table public.drivers (
  id                  uuid primary key references public.profiles(id) on delete cascade,

  -- ---------------------------------------------------------------------------
  -- حالة العمل
  -- ---------------------------------------------------------------------------
  status              public.driver_status not null default 'offline',
  verification_status public.verification_status not null default 'pending',
  rejection_reason    text,

  -- ---------------------------------------------------------------------------
  -- الموقع اللحظي.
  --
  -- geography(Point,4326): نقطة على سطح الأرض بنظام الإحداثيات العالمي (GPS).
  -- اخترنا geography لا geometry لأنها تحسب المسافات بالأمتار على سطح كروي
  -- مباشرة — لا نحتاج إسقاطات أو تحويلات. أبطأ قليلاً لكن أصح.
  --
  -- ملاحظة الترتيب: PostGIS يأخذ (خط الطول, خط العرض) — longitude ثم latitude.
  -- هذا معكوس عن ترتيب جوجل مابس (lat, lng) وهو مصدر أخطاء شائع جداً.
  -- ---------------------------------------------------------------------------
  current_location    geography(Point, 4326),
  heading             smallint,          -- اتجاه الدراجة بالدرجات 0-359 لتدوير الأيقونة
  speed_kmh           smallint,
  location_updated_at timestamptz,

  -- ---------------------------------------------------------------------------
  -- المركبة (دُمجت هنا بدل جدول منفصل: السائق لديه دراجة واحدة في نموذجنا)
  -- ---------------------------------------------------------------------------
  -- نوع الدراجة كما يكتبه السائق عند التسجيل (نص حر).
  -- الحقول التفصيلية تحته يملؤها المدير وقت المراجعة من صور الدراجة.
  vehicle_type        text,

  -- كل ما تحت هذا السطر **اختياري**: لا يمنع غيابه اعتماد السائق.
  -- يملؤه المدير وقت المراجعة من صور الدراجة، أو يبقى فارغاً.
  vehicle_plate       text,
  vehicle_make        text,              -- مثال: هوندا
  vehicle_model       text,              -- مثال: CG 150
  vehicle_color       text,
  vehicle_year        smallint,

  -- ---------------------------------------------------------------------------
  -- السمعة والأداء
  -- ---------------------------------------------------------------------------
  rating_avg          numeric(3,2) not null default 5.00 check (rating_avg between 1 and 5),
  rating_count        integer not null default 0,
  trips_completed     integer not null default 0,
  trips_cancelled     integer not null default 0,

  -- ---------------------------------------------------------------------------
  -- المحفظة: رصيد السائق لدى المنصة بالدينار العراقي.
  --
  -- سالب = السائق مدين للمنصة بعمولات رحلات نقدية (حصّل الأجرة كاملة نقداً).
  -- نمنعه من الاتصال إذا تجاوز الحد الأدنى المسموح — وإلا تراكم دين لا يُسترد.
  --
  -- numeric(12,2) وليس float: الحسابات المالية بالعوائم تنتج أخطاء تقريب.
  -- ---------------------------------------------------------------------------
  wallet_balance_iqd  numeric(12,2) not null default 0,

  is_available_for_matching boolean generated always as (
    status = 'online' and verification_status = 'approved'
  ) stored,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint drivers_heading_range check (heading is null or heading between 0 and 359),
  constraint drivers_speed_sane    check (speed_kmh is null or speed_kmh between 0 and 200)
);

comment on column public.drivers.current_location is
  'آخر موقع معروف. PostGIS يستخدم ترتيب (lng, lat) — عكس جوجل مابس.';
comment on column public.drivers.wallet_balance_iqd is
  'رصيد بالدينار. سالب = عمولات مستحقة على السائق للمنصة.';

-- -----------------------------------------------------------------------------
-- الفهرس المكاني — هذا أهم فهرس في قاعدة البيانات كلها.
--
-- GIST هو نوع فهرس يفهم الأشكال الهندسية. بدونه فإن سؤال "أقرب السائقين"
-- يجبر بوستغرس على حساب المسافة لكل سائق في الجدول (مسح كامل).
-- معه يقفز مباشرة للمنطقة الجغرافية المطلوبة.
--
-- الفهرس جزئي (where): نفهرس فقط السائقين المتاحين فعلاً. أصغر حجماً وأسرع.
-- -----------------------------------------------------------------------------
create index drivers_location_gist_idx
  on public.drivers using gist (current_location)
  where is_available_for_matching;

create index drivers_status_idx       on public.drivers (status) where status <> 'offline';
create index drivers_verification_idx on public.drivers (verification_status);

create trigger drivers_touch_updated_at
  before update on public.drivers
  for each row execute function public.touch_updated_at();

-- =============================================================================
-- وثائق المستخدمين
-- =============================================================================
-- جدول واحد للجميع لا للسائقين وحدهم: **الصورة الحية مطلوبة من كل مستخدم**
-- راكباً كان أم سائقاً. الفرق أن السائق يضيف فوقها وثائق المركبة والإجازة.
--
-- الملفات تُخزَّن في Supabase Storage ونحفظ هنا مسارها لا رابطاً عاماً —
-- صور البطاقات والوجوه لا يجوز أن تكون متاحة برابط مباشر لمن يخمّنه.
-- =============================================================================
create table public.user_documents (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  doc_type      public.document_type not null,

  storage_path  text not null,

  status        public.verification_status not null default 'pending',
  review_notes  text,
  reviewed_by   uuid references public.profiles(id),
  reviewed_at   timestamptz,
  expires_at    date,                    -- الإجازة والتأمين لهما تاريخ انتهاء

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  created_by_admin boolean not null default false
);

-- نسخة واحدة لكل نوع وثيقة لكل مستخدم — **عدا صور الدراجة**، فهي متعددة
-- بطبيعتها (أمام، خلف، لوحة). لذلك فهرس فريد جزئي بدل قيد unique عادي.
create unique index user_documents_one_per_type
  on public.user_documents (user_id, doc_type)
  where doc_type <> 'vehicle_photo';

-- حدّ أعلى لصور الدراجة يمنع إغراق التخزين
create or replace function public.limit_vehicle_photos()
returns trigger
language plpgsql
as $$
begin
  if new.doc_type = 'vehicle_photo' then
    if (select count(*) from public.user_documents
        where user_id = new.user_id and doc_type = 'vehicle_photo') >= 6 then
      raise exception 'الحد الأقصى ٦ صور للدراجة';
    end if;
  end if;
  return new;
end;
$$;

create trigger user_documents_limit_vehicle_photos
  before insert on public.user_documents
  for each row execute function public.limit_vehicle_photos();

comment on table public.user_documents is
  'وثائق التحقق. live_selfie مطلوبة من الجميع، والبقية للسائقين.';

create index user_documents_user_idx    on public.user_documents (user_id);
create index user_documents_pending_idx on public.user_documents (status)
  where status = 'pending';

create trigger user_documents_touch_updated_at
  before update on public.user_documents
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- الاعتماد التلقائي للركّاب.
--
-- الراكب لا ينتظر موافقة المدير — صورته الحية تُقبل فور رفعها. المدير
-- يراجعها لاحقاً فقط عند بلاغ أو نزاع.
--
-- **لماذا؟** مراجعة صور آلاف الركّاب يدوياً وظيفة بدوام كامل. المراجعة
-- اليدوية تُحفظ للسائقين — وهم عشرات — لأنهم من ينقل الناس ويقبض المال.
-- -----------------------------------------------------------------------------
create or replace function public.auto_approve_rider_docs()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.doc_type = 'live_selfie'
     and (select role from public.profiles where id = new.user_id) = 'rider'
  then
    new.status := 'approved';
    new.reviewed_at := now();
  end if;
  return new;
end;
$$;

create trigger user_documents_auto_approve_riders
  before insert on public.user_documents
  for each row execute function public.auto_approve_rider_docs();

-- -----------------------------------------------------------------------------
-- عند تغيير حالة وثيقة نعيد تقييم حالة صاحبها.
--
--   الصورة الحية  →  profiles.identity_verified
--   وثائق السائق  →  drivers.verification_status
--
-- السائق لا يُعتمد إلا إذا قُبلت **كل** وثائقه الإلزامية، والصورة الحية
-- من ضمنها — فهو يحتاج إثبات أنه هو صاحب البطاقة التي رفعها.
-- -----------------------------------------------------------------------------
create or replace function public.recompute_verification()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role         public.user_role;
  -- الوثائق الإلزامية لاعتماد السائق — ثلاث فقط.
  --
  -- **اختيارية بقرار صريح:** إجازة السوق، والسنوية (vehicle_registration)،
  -- والتأمين، ورقم لوحة المركبة. السائق يستطيع رفعها ويستطيع تركها،
  -- والاعتماد لا يتوقف عليها.
  --
  -- تفعيل أيٍّ منها لاحقاً = إضافة اسمها لهذه المصفوفة وحدها. لا شيء آخر
  -- في النظام يحتاج تغييراً.
  --
  -- (سبق التنبيه لأثر ذلك قانونياً؛ القرار متّخذ وموثّق هنا.)
  required_docs  public.document_type[] := array[
    'live_selfie', 'national_id_front', 'national_id_back', 'vehicle_photo'
  ]::public.document_type[];
  approved_count integer;
  rejected_count integer;
begin
  select role into v_role from public.profiles where id = new.user_id;

  -- نرفع علم تجاوز الحُرّاس: هذا تعديل نظامي موثوق، لا من المستخدم.
  perform set_config('app.bypass_guards', 'on', true);

  -- ١) التحقق من الهوية — يخص الجميع
  if new.doc_type = 'live_selfie' then
    update public.profiles
    set identity_verified = (new.status = 'approved')
    where id = new.user_id;
  end if;

  -- ٢) أهلية القيادة — تخص السائقين وحدهم
  if v_role = 'driver' then
    -- نعدّ **الأنواع المميزة** لا الصفوف: صور الدراجة متعددة، ولو عددنا
    -- الصفوف لاعتُمد سائق رفع ثلاث صور دراجة بلا بطاقة ولا صورة حية.
    select
      count(distinct doc_type) filter (
        where status = 'approved' and doc_type = any(required_docs)),
      count(distinct doc_type) filter (
        where status = 'rejected' and doc_type = any(required_docs))
    into approved_count, rejected_count
    from public.user_documents
    where user_id = new.user_id;

    update public.drivers d
    set verification_status = case
          when rejected_count > 0                              then 'rejected'
          when approved_count = array_length(required_docs, 1) then 'approved'
          else 'pending'
        end::public.verification_status,
        -- السائق المرفوض يُفصل عن الشبكة فوراً
        status = case
          when rejected_count > 0 then 'offline'
          else d.status
        end
    where d.id = new.user_id;
  end if;

  perform set_config('app.bypass_guards', 'off', true);

  return new;
end;
$$;

create trigger user_documents_recompute_verification
  after insert or update of status on public.user_documents
  for each row execute function public.recompute_verification();


-- ##########################################################################
-- ملف: 0004_trips.sql
-- ##########################################################################

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


-- ##########################################################################
-- ملف: 0005_pricing_and_wallet.sql
-- ##########################################################################

-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0005 — التسعير والمحفظة
-- =============================================================================

-- =============================================================================
-- إعدادات التسعير — صف واحد لكل مدينة
-- =============================================================================
-- نجعلها جدولاً لا ثوابت في الكود لسببين:
--   ١) الأسعار تتغير مع الوقود والتضخم، ولا يجوز أن يتطلب ذلك إصدار تطبيق جديد.
--   ٢) بغداد ليست البصرة — كل مدينة لها تسعيرتها.
-- =============================================================================
create table public.pricing_zones (
  id                 uuid primary key default gen_random_uuid(),
  city_name          text not null,
  city_name_ar       text not null,

  -- حدود المنطقة. الطلب خارج أي منطقة مفعّلة يُرفض.
  boundary           geography(Polygon, 4326) not null,

  -- ---------------------------------------------------------------------------
  -- مكوّنات الأجرة (بالدينار العراقي)
  --   الأجرة = أجرة_البداية + (كم × سعر_الكم) + (دقيقة × سعر_الدقيقة)
  --   ثم تُضرب بمعامل الذروة، ولا تنزل تحت الحد الأدنى.
  -- ---------------------------------------------------------------------------
  base_fare_iqd      numeric(10,2) not null default 1000,
  per_km_iqd         numeric(10,2) not null default 250,
  per_minute_iqd     numeric(10,2) not null default 25,
  minimum_fare_iqd   numeric(10,2) not null default 1500,

  -- رسوم الإلغاء بعد قبول السائق وتحركه نحو الراكب
  cancellation_fee_iqd numeric(10,2) not null default 1000,
  -- مهلة الإلغاء المجاني بالثواني بعد قبول السائق
  free_cancel_window_s integer not null default 120,

  -- نسبة عمولة المنصة من الأجرة (0.15 = ١٥٪)
  commission_rate    numeric(4,3) not null default 0.150,

  -- ---------------------------------------------------------------------------
  -- حدود المطابقة
  -- ---------------------------------------------------------------------------
  search_radius_m         integer not null default 3000,
  max_search_radius_m     integer not null default 7000,
  offer_timeout_s         integer not null default 15,
  max_offers_per_trip     smallint not null default 8,

  -- أقصى دين مسموح على السائق قبل فصله عن الشبكة (قيمة سالبة)
  min_wallet_balance_iqd  numeric(12,2) not null default -25000,

  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint pricing_commission_sane check (commission_rate between 0 and 0.5),
  constraint pricing_radius_order    check (max_search_radius_m >= search_radius_m)
);

create index pricing_zones_boundary_gist on public.pricing_zones using gist (boundary)
  where is_active;

create trigger pricing_zones_touch_updated_at
  before update on public.pricing_zones
  for each row execute function public.touch_updated_at();

-- =============================================================================
-- معاملات الذروة — رفع السعر وقت ازدحام الطلب
-- =============================================================================
-- يُحسب دورياً: عدد الطلبات النشطة ÷ عدد السائقين المتاحين في المنطقة.
-- نخزّنه بدل حسابه لحظياً حتى لا يتغير السعر بين شاشة التقدير وشاشة التأكيد.
-- =============================================================================
create table public.surge_state (
  zone_id     uuid primary key references public.pricing_zones(id) on delete cascade,
  multiplier  numeric(4,2) not null default 1.00 check (multiplier between 1.00 and 5.00),
  active_requests  integer not null default 0,
  available_drivers integer not null default 0,
  updated_at  timestamptz not null default now()
);

-- =============================================================================
-- حركات محفظة السائق — دفتر أستاذ لا يُعدَّل ولا يُحذف منه
-- =============================================================================
-- كل صف حركة واحدة، ونخزّن الرصيد بعدها (balance_after) لنستطيع تدقيق أي
-- خلاف مالي لاحقاً دون إعادة حساب التاريخ كله.
-- =============================================================================
create table public.wallet_transactions (
  id             uuid primary key default gen_random_uuid(),
  driver_id      uuid not null references public.drivers(id) on delete restrict,
  trip_id        uuid references public.trips(id) on delete set null,

  txn_type       public.wallet_txn_type not null,
  amount_iqd     numeric(12,2) not null,   -- موجب = إضافة، سالب = خصم
  balance_after_iqd numeric(12,2) not null,

  description    text,
  created_by     uuid references public.profiles(id),  -- للتسويات اليدوية
  created_at     timestamptz not null default now(),

  constraint wallet_amount_nonzero check (amount_iqd <> 0)
);

create index wallet_txn_driver_idx on public.wallet_transactions (driver_id, created_at desc);
create index wallet_txn_trip_idx   on public.wallet_transactions (trip_id);

-- -----------------------------------------------------------------------------
-- الدالة الوحيدة المسموح لها تعديل رصيد المحفظة.
--
-- لماذا دالة واحدة؟ لأن تحديث الرصيد وتسجيل الحركة يجب أن يحدثا معاً أو
-- لا يحدثا إطلاقاً. لو سمحنا بتحديث drivers.wallet_balance_iqd مباشرة من
-- أماكن متفرقة لانحرف الرصيد عن مجموع الحركات وضاعت إمكانية التدقيق.
--
-- for update: يقفل صف السائق حتى نهاية المعاملة، فلا تتداخل حركتان متزامنتان.
-- -----------------------------------------------------------------------------
create or replace function public.post_wallet_transaction(
  p_driver_id   uuid,
  p_txn_type    public.wallet_txn_type,
  p_amount_iqd  numeric,
  p_trip_id     uuid default null,
  p_description text default null,
  p_created_by  uuid default null
)
returns public.wallet_transactions
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_new_balance numeric(12,2);
  v_txn public.wallet_transactions;
begin
  if p_amount_iqd = 0 then
    raise exception 'لا يمكن تسجيل حركة محفظة بقيمة صفر';
  end if;

  -- القفل يمنع تسابق حركتين على نفس المحفظة
  select wallet_balance_iqd + p_amount_iqd
  into v_new_balance
  from public.drivers
  where id = p_driver_id
  for update;

  if not found then
    raise exception 'السائق % غير موجود', p_driver_id;
  end if;

  -- نرفع علم تجاوز الحُرّاس: هذا تعديل نظامي موثوق، لا من المستخدم.
  perform set_config('app.bypass_guards', 'on', true);

  update public.drivers
  set wallet_balance_iqd = v_new_balance
  where id = p_driver_id;

  perform set_config('app.bypass_guards', 'off', true);


  insert into public.wallet_transactions
    (driver_id, trip_id, txn_type, amount_iqd, balance_after_iqd, description, created_by)
  values
    (p_driver_id, p_trip_id, p_txn_type, p_amount_iqd, v_new_balance, p_description, p_created_by)
  returning * into v_txn;

  return v_txn;
end;
$$;

-- منع الكتابة المباشرة على الرصيد من خارج الدالة أعلاه — طبقتان:
--   ١) سحب صلاحية UPDATE على العمود من مستخدمي التطبيق (هنا).
--   ٢) المُشغّل drivers_guard_columns في 0007 يرفض أي تغيير للرصيد ما لم
--      يكن العلم app.bypass_guards مرفوعاً، وهو ما لا تفعله إلا هذه الدالة.
-- الطبقة الأولى وحدها لا تكفي: الدوال security definer تعمل بصلاحيات المالك
-- وتتجاوز منح الصلاحيات، فلولا المُشغّل لاستطاعت أي دالة منها تعديل الرصيد.
revoke update (wallet_balance_iqd) on public.drivers from authenticated, anon;

-- =============================================================================
-- حساب الأجرة
-- =============================================================================
-- ترجع jsonb لا رقماً مفرداً: نحتاج تفصيل المكوّنات لعرضه للراكب ولتجميده
-- داخل الرحلة (fare_breakdown). الشفافية تقلّل نزاعات الأجرة كثيراً.
-- =============================================================================
create or replace function public.calculate_fare(
  p_zone_id     uuid,
  p_distance_m  integer,
  p_duration_s  integer,
  p_surge       numeric default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  z public.pricing_zones;
  v_surge     numeric(4,2);
  v_distance  numeric;
  v_time      numeric;
  v_subtotal  numeric;
  v_total     numeric;
  v_commission numeric;
begin
  select * into z from public.pricing_zones where id = p_zone_id and is_active;
  if not found then
    raise exception 'منطقة تسعير غير معروفة أو غير مفعّلة: %', p_zone_id;
  end if;

  v_surge := coalesce(
    p_surge,
    (select multiplier from public.surge_state where zone_id = p_zone_id),
    1.00
  );

  v_distance := (p_distance_m::numeric / 1000) * z.per_km_iqd;
  v_time     := (p_duration_s::numeric / 60)   * z.per_minute_iqd;
  v_subtotal := z.base_fare_iqd + v_distance + v_time;
  v_total    := greatest(v_subtotal * v_surge, z.minimum_fare_iqd);

  -- التقريب لأقرب ٢٥٠ دينار: أصغر فئة نقدية متداولة عملياً في العراق،
  -- ويجنّب السائق والراكب مشكلة "ما عندي فراطة".
  v_total := round(v_total / 250) * 250;

  v_commission := round(v_total * z.commission_rate, 2);

  return jsonb_build_object(
    'currency',        'IQD',
    'base_fare',       z.base_fare_iqd,
    'distance_m',      p_distance_m,
    'distance_charge', round(v_distance, 2),
    'duration_s',      p_duration_s,
    'time_charge',     round(v_time, 2),
    'subtotal',        round(v_subtotal, 2),
    'surge_multiplier', v_surge,
    'minimum_fare',    z.minimum_fare_iqd,
    'total',           v_total,
    'commission_rate', z.commission_rate,
    'commission',      v_commission,
    'driver_earning',  v_total - v_commission,
    'calculated_at',   now()
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- تحديد منطقة التسعير من نقطة جغرافية.
-- st_contains يستفيد من الفهرس المكاني على boundary.
-- -----------------------------------------------------------------------------
create or replace function public.zone_for_point(p_point geography)
returns uuid
language sql
stable
security definer
set search_path = public, extensions
as $$
  select id
  from public.pricing_zones
  where is_active
    and st_contains(boundary::geometry, p_point::geometry)
  limit 1;
$$;


-- ##########################################################################
-- ملف: 0006_matching_engine.sql
-- ##########################################################################

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


-- ##########################################################################
-- ملف: 0007_rls_policies.sql
-- ##########################################################################

-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0007 — سياسات أمان الصفوف (Row Level Security)
-- =============================================================================
-- مفهوم RLS: تطبيق Flutter يتصل بقاعدة البيانات مباشرة بمفتاح عام (anon key)
-- يعرفه أي شخص يفكك ملف APK. الأمان لا يأتي من إخفاء المفتاح، بل من هذه
-- السياسات: قواعد تُطبَّق على كل استعلام فتحدد أي الصفوف يراها المستخدم.
--
-- القاعدة الذهبية: نمنع كل شيء افتراضياً ثم نسمح بأضيق ما يلزم.
-- =============================================================================

alter table public.profiles            enable row level security;
alter table public.drivers             enable row level security;
alter table public.user_documents      enable row level security;
alter table public.trips               enable row level security;
alter table public.trip_offers         enable row level security;
alter table public.trip_locations      enable row level security;
alter table public.ratings             enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.pricing_zones       enable row level security;
alter table public.surge_state         enable row level security;

-- =============================================================================
-- profiles
-- =============================================================================

create policy "profiles: يقرأ المستخدم ملفه"
  on public.profiles for select
  using (id = auth.uid() or public.is_admin());

-- **لا توجد سياسة تتيح لطرفي الرحلة قراءة ملف بعضهما مباشرة.** هذا مقصود.
--
-- سياسة SELECT تمنح الصف كاملاً بكل أعمدته — ولا يمكن حصرها بأعمدة معيّنة.
-- لو سمحنا للسائق بقراءة ملف راكبه، لرأى **رقم بطاقته الوطنية**.
--
-- البديل: العرض trip_party_info في نهاية هذا الملف، يكشف الحقول الآمنة فقط
-- (الاسم، الصورة، التقييم، بيانات المركبة) ويكشف الهاتف أثناء الرحلة النشطة
-- وحدها.

-- المستخدم يعدّل ملفه.
--
-- ملاحظة مهمة: منع ترقية الدور مكتوب كمُشغّل (أسفل الملف) لا كشرط في
-- with check. السبب أن أي استعلام فرعي من profiles داخل سياسة على profiles
-- يُنتج خطأ "infinite recursion detected in policy" — السياسة تُطبَّق على
-- استعلامها الفرعي فتستدعي نفسها.
create policy "profiles: يعدّل المستخدم ملفه"
  on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy "profiles: صلاحية كاملة للمشرف"
  on public.profiles for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- drivers
-- =============================================================================

create policy "drivers: يقرأ السائق سجله"
  on public.drivers for select
  using (id = auth.uid() or public.is_admin());

-- الراكب يرى بيانات سائقه أثناء الرحلة فقط (لوحة الدراجة، التقييم، الموقع)
create policy "drivers: راكب الرحلة النشطة"
  on public.drivers for select
  using (
    exists (
      select 1 from public.trips t
      where t.driver_id = drivers.id
        and t.rider_id = auth.uid()
        and t.status in ('accepted', 'driver_arrived', 'in_progress')
    )
  );

-- السائق يحدّث بيانات مركبته فقط. الحالة والموقع والرصيد والاعتماد
-- تُغيَّر حصراً عبر الدوال في 0006، ويحرسها المُشغّل أسفل الملف
-- (وليس with check، لنفس سبب التكرار اللانهائي المذكور أعلاه).
create policy "drivers: يحدّث السائق بيانات مركبته"
  on public.drivers for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy "drivers: صلاحية كاملة للمشرف"
  on public.drivers for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- user_documents — وثائق شخصية حساسة (صور بطاقات ووجوه)
-- =============================================================================
-- لا يرى أحد وثائق أحد. حتى طرفا الرحلة لا يريان صور بعضهما — الصورة الحية
-- أداة تحقق للإدارة، لا لعرضها على المستخدمين.
-- =============================================================================

create policy "documents: المستخدم يرى وثائقه"
  on public.user_documents for select
  using (user_id = auth.uid() or public.is_admin());

create policy "documents: المستخدم يرفع وثائقه"
  on public.user_documents for insert
  with check (user_id = auth.uid() and status = 'pending');

-- يعيد الرفع فقط إن كانت مرفوضة أو معلّقة — لا يمس المقبولة.
-- ولا يستطيع تغيير الحالة إلى approved بنفسه: with check يفرض pending.
create policy "documents: المستخدم يعيد رفع المرفوضة"
  on public.user_documents for update
  using (user_id = auth.uid() and status in ('pending', 'rejected'))
  with check (user_id = auth.uid() and status = 'pending');

create policy "documents: المشرف يراجع"
  on public.user_documents for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- trips
-- =============================================================================

create policy "trips: طرفا الرحلة يقرآنها"
  on public.trips for select
  using (rider_id = auth.uid() or driver_id = auth.uid() or public.is_admin());

-- السائق يرى الرحلة المعروضة عليه قبل قبولها (وإلا لن يرى تفاصيل العرض)
create policy "trips: السائق يرى العرض المُقدَّم له"
  on public.trips for select
  using (
    exists (
      select 1 from public.trip_offers o
      where o.trip_id = trips.id
        and o.driver_id = auth.uid()
        and o.status = 'pending'
    )
  );

-- لا INSERT ولا UPDATE مباشر على الرحلات إطلاقاً.
-- كل تعديل يمر عبر request_trip / accept_trip_offer / advance_trip /
-- complete_trip / cancel_trip. هذا ما يمنع تزوير الأجرة أو تخطي الحالات.

create policy "trips: صلاحية كاملة للمشرف"
  on public.trips for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- trip_offers
-- =============================================================================

create policy "offers: السائق يرى عروضه"
  on public.trip_offers for select
  using (driver_id = auth.uid() or public.is_admin());

-- الراكب يتابع تقدم البحث ("جارٍ الاتصال بالسائق الثالث...")
create policy "offers: الراكب يتابع بحث رحلته"
  on public.trip_offers for select
  using (
    exists (select 1 from public.trips t where t.id = trip_offers.trip_id and t.rider_id = auth.uid())
  );

-- =============================================================================
-- trip_locations — أثر المسار
-- =============================================================================

create policy "locations: طرفا الرحلة"
  on public.trip_locations for select
  using (
    exists (
      select 1 from public.trips t
      where t.id = trip_locations.trip_id
        and (t.rider_id = auth.uid() or t.driver_id = auth.uid())
    )
    or public.is_admin()
  );

-- =============================================================================
-- ratings
-- =============================================================================

create policy "ratings: يقرأ الجميع تقييمات مرئية"
  on public.ratings for select
  using (rater_id = auth.uid() or ratee_id = auth.uid() or public.is_admin());

-- يقيّم فقط من كان طرفاً في رحلة مكتملة، ولا يقيّم نفسه
create policy "ratings: تقييم بعد رحلة مكتملة"
  on public.ratings for insert
  with check (
    rater_id = auth.uid()
    and ratee_id <> auth.uid()
    and exists (
      select 1 from public.trips t
      where t.id = ratings.trip_id
        and t.status = 'completed'
        and (
          (t.rider_id  = auth.uid() and t.driver_id = ratings.ratee_id) or
          (t.driver_id = auth.uid() and t.rider_id  = ratings.ratee_id)
        )
    )
  );

-- =============================================================================
-- wallet_transactions — للقراءة فقط من التطبيق
-- =============================================================================

create policy "wallet: السائق يقرأ كشف حسابه"
  on public.wallet_transactions for select
  using (driver_id = auth.uid() or public.is_admin());

create policy "wallet: المشرف يسجّل تسويات"
  on public.wallet_transactions for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- pricing_zones & surge_state — قراءة عامة، تعديل للمشرف
-- =============================================================================

create policy "pricing: قراءة عامة للمناطق المفعّلة"
  on public.pricing_zones for select
  using (is_active or public.is_admin());

create policy "pricing: تعديل للمشرف"
  on public.pricing_zones for all
  using (public.is_admin()) with check (public.is_admin());

create policy "surge: قراءة عامة"
  on public.surge_state for select using (true);

create policy "surge: تعديل للمشرف"
  on public.surge_state for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- منح الصلاحيات على الدوال
-- =============================================================================
-- الدوال security definer تتجاوز RLS، لذلك نمنحها للمستخدمين المسجّلين فقط
-- (authenticated) وليس للزوار (anon).
-- =============================================================================

revoke all on function public.update_driver_location    from public, anon;
revoke all on function public.set_driver_online          from public, anon;
revoke all on function public.request_trip               from public, anon;
revoke all on function public.accept_trip_offer          from public, anon;
revoke all on function public.reject_trip_offer          from public, anon;
revoke all on function public.advance_trip               from public, anon;
revoke all on function public.complete_trip              from public, anon;
revoke all on function public.cancel_trip                from public, anon;
revoke all on function public.post_wallet_transaction    from public, anon, authenticated;
revoke all on function public.dispatch_next_offer        from public, anon, authenticated;
revoke all on function public.expire_stale_offers        from public, anon, authenticated;

grant execute on function public.update_driver_location  to authenticated;
grant execute on function public.set_driver_online        to authenticated;
grant execute on function public.estimate_trip            to authenticated;
grant execute on function public.request_trip             to authenticated;
grant execute on function public.accept_trip_offer        to authenticated;
grant execute on function public.reject_trip_offer        to authenticated;
grant execute on function public.advance_trip             to authenticated;
grant execute on function public.complete_trip            to authenticated;
grant execute on function public.cancel_trip              to authenticated;
grant execute on function public.find_nearby_drivers      to authenticated;

-- =============================================================================
-- عرض مبسّط لبيانات الطرف الآخر — نكشف الحد الأدنى فقط
-- =============================================================================
-- الراكب يحتاج: اسم السائق، تقييمه، لوحة دراجته. لا يحتاج رقم هويته ولا رصيده.
-- =============================================================================
-- ملاحظتان على التصميم:
--
-- ١) لا نضع security_invoker = true عمداً. بدونها يعمل العرض بصلاحيات مالكه
--    فيتجاوز RLS على profiles — وهذا ما نريده بالضبط: أن يقرأ الحقول الآمنة
--    نيابةً عن المستخدم دون منحه صلاحية قراءة الجدول كله.
--
-- ٢) security_barrier = true يمنع بوستغرس من تقديم شروط المستخدم على شرط
--    where الخاص بنا أثناء التحسين. بدونها يستطيع مستخدم ذكي تمرير دالة
--    تُنفَّذ قبل الفلترة فتتسرب صفوف رحلات لا يملكها.
create or replace view public.trip_party_info
with (security_barrier = true)
as
select
  t.id   as trip_id,
  p.id   as person_id,
  case when p.id = t.driver_id then 'driver' else 'rider' end as party,

  p.full_name,
  p.avatar_url,

  -- الهاتف يُكشف أثناء الرحلة النشطة فقط. بعد انتهائها لا يبقى سبب
  -- لبقاء رقم الراكب في يد السائق.
  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end as phone,

  d.rating_avg,
  d.vehicle_plate,
  d.vehicle_make,
  d.vehicle_model,
  d.vehicle_color

from public.trips t
join public.profiles p
  on p.id = t.rider_id or p.id = t.driver_id
left join public.drivers d on d.id = p.id
-- الفلتر الأمني: لا تُرجع إلا رحلات المستدعي نفسه
where t.rider_id = auth.uid() or t.driver_id = auth.uid();

comment on view public.trip_party_info is
  'الحقول الآمنة فقط عن طرفي الرحلة. لا يكشف رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;

-- =============================================================================
-- تفعيل البث اللحظي (Realtime)
-- =============================================================================
-- Supabase يبث تغييرات الجداول المضافة لهذا المنشور عبر WebSocket.
-- سياسات RLS تُطبَّق على البث أيضاً — فلا يصل الراكب إلا ما يحق له رؤيته.
-- =============================================================================
alter publication supabase_realtime add table public.trips;
alter publication supabase_realtime add table public.trip_offers;
alter publication supabase_realtime add table public.drivers;

-- بدون هذا يرسل بوستغرس المفتاح الأساسي فقط عند التحديث، ونحتاج الصف كاملاً
alter table public.trips       replica identity full;
alter table public.trip_offers replica identity full;

-- =============================================================================
-- المُشغّلات الحارسة — تحمي الأعمدة الحسّاسة من التعديل المباشر
-- =============================================================================
-- لماذا مُشغّل لا سياسة RLS؟ لأن مقارنة القيمة الجديدة بالقديمة تحتاج
-- استعلاماً فرعياً من نفس الجدول، وهو ما يسبب تكراراً لانهائياً داخل السياسة.
-- المُشغّل يملك old و new جاهزتين فلا يحتاج استعلاماً أصلاً.
--
-- منفذ العبور: الدوال الموثوقة (post_wallet_transaction وغيرها) ترفع علماً
-- محلياً للمعاملة قبل التعديل. العلم يزول تلقائياً بنهاية المعاملة، ولا
-- يستطيع المستخدم رفعه لأنه لا يملك صلاحية استدعاء تلك الدوال.
-- =============================================================================

create or replace function public.guards_bypassed()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('app.bypass_guards', true), 'off') = 'on';
$$;

-- -----------------------------------------------------------------------------
create or replace function public.guard_profile_columns()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.guards_bypassed() or public.is_admin() then
    return new;
  end if;

  if new.role is distinct from old.role then
    raise exception 'لا يمكن تغيير دور المستخدم' using errcode = 'insufficient_privilege';
  end if;

  if new.is_blocked is distinct from old.is_blocked then
    raise exception 'لا يمكن تغيير حالة الحظر' using errcode = 'insufficient_privilege';
  end if;

  -- التحقق من الهوية يُقرَّر من مراجعة الصورة الحية، لا من التطبيق
  if new.identity_verified is distinct from old.identity_verified then
    raise exception 'حالة التحقق من الهوية تُحدَّد من مراجعة الوثائق فقط'
      using errcode = 'insufficient_privilege';
  end if;

  if new.phone_verified is distinct from old.phone_verified then
    raise exception 'لا يمكن توثيق الهاتف من التطبيق'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger profiles_guard_columns
  before update on public.profiles
  for each row execute function public.guard_profile_columns();

-- -----------------------------------------------------------------------------
create or replace function public.guard_driver_columns()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.guards_bypassed() or public.is_admin() then
    return new;
  end if;

  if new.wallet_balance_iqd is distinct from old.wallet_balance_iqd then
    raise exception 'الرصيد يُعدَّل حصراً عبر post_wallet_transaction'
      using errcode = 'insufficient_privilege';
  end if;

  if new.verification_status is distinct from old.verification_status then
    raise exception 'حالة الاعتماد تُحدَّد من مراجعة الوثائق فقط'
      using errcode = 'insufficient_privilege';
  end if;

  if new.rating_avg is distinct from old.rating_avg
     or new.rating_count is distinct from old.rating_count
     or new.trips_completed is distinct from old.trips_completed then
    raise exception 'إحصاءات السائق تُحدَّث من النظام فقط'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger drivers_guard_columns
  before update on public.drivers
  for each row execute function public.guard_driver_columns();


-- ##########################################################################
-- ملف: 0008_seed_zones.sql
-- ##########################################################################

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


-- ##########################################################################
-- ملف: 0009_fix_policy_recursion.sql
-- ##########################################################################

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


-- ##########################################################################
-- ملف: 0010_storage_policies.sql
-- ##########################################################################

-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
set search_path = public, extensions;

-- =============================================================================
-- 0010 — سياسات تخزين الوثائق
-- =============================================================================
-- البكت `documents` خاص (Private)، لكن الخصوصية وحدها لا تكفي: بدون سياسات
-- لا يستطيع أي مستخدم مسجّل الرفع ولا القراءة إطلاقاً، ومع سياسات فضفاضة
-- يقرأ كل مستخدم صور الجميع.
--
-- **اصطلاح المسار — أساس الأمان كله:**
--
--     documents/<user_id>/<doc_type>_<timestamp>.jpg
--
-- أول جزء من المسار هو معرّف صاحب الملف. السياسات تقارنه بـ auth.uid()،
-- فيصير كل مستخدم محصوراً في مجلده لا يخرج منه.
--
-- storage.foldername(name) تفكّك المسار إلى مصفوفة أجزاء، و [1] أولها.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- الرفع — كل مستخدم في مجلده وحده
-- -----------------------------------------------------------------------------
drop policy if exists "documents: رفع في مجلد المستخدم" on storage.objects;
create policy "documents: رفع في مجلد المستخدم"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- -----------------------------------------------------------------------------
-- القراءة — ملفاتك أنت، أو أي ملف إن كنت مشرفاً
--
-- المشرف يحتاجها لمراجعة وثائق السائقين واعتمادهم.
-- لا أحد غيرهما: حتى طرفا الرحلة لا يريان صور بعضهما.
-- -----------------------------------------------------------------------------
drop policy if exists "documents: قراءة ملفاتي" on storage.objects;
create policy "documents: قراءة ملفاتي"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documents'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin()
    )
  );

-- -----------------------------------------------------------------------------
-- الاستبدال — لإعادة رفع وثيقة مرفوضة
-- -----------------------------------------------------------------------------
drop policy if exists "documents: استبدال ملفاتي" on storage.objects;
create policy "documents: استبدال ملفاتي"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- -----------------------------------------------------------------------------
-- الحذف — للمشرف وحده
--
-- **لماذا نمنع المستخدم من حذف وثائقه؟** لأنها دليل تحقق. سائق تورّط في
-- حادثة يجب ألا يستطيع محو صورة بطاقته بضغطة. الاستبدال مسموح، المحو لا.
-- -----------------------------------------------------------------------------
drop policy if exists "documents: حذف للمشرف فقط" on storage.objects;
create policy "documents: حذف للمشرف فقط"
  on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and public.is_admin());

-- =============================================================================
-- ضبط البكت: الحد الأقصى للحجم والأنواع المسموحة
-- =============================================================================
-- الحد يمنع رفع فيديو بدل صورة أو إغراق التخزين. وحصر الأنواع يمنع رفع
-- ملف تنفيذي بامتداد صورة.
-- =============================================================================
update storage.buckets
set file_size_limit   = 5242880,        -- ٥ ميجابايت
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'],
    public = false                       -- تأكيد، ولو أُنشئ خاصاً أصلاً
where id = 'documents';

-- =============================================================================
-- دالة مساعدة: بناء مسار وثيقة بالاصطلاح الصحيح
-- =============================================================================
-- نضعها في القاعدة لا في التطبيق حتى لا يختلف اصطلاح المسار بين تطبيق
-- الراكب وتطبيق السائق ولوحة الإدارة. مصدر واحد للحقيقة.
-- =============================================================================
create or replace function public.document_storage_path(
  p_doc_type public.document_type,
  p_ext      text default 'jpg'
)
returns text
language sql
stable
as $$
  select auth.uid()::text || '/' || p_doc_type::text || '_' ||
         extract(epoch from now())::bigint::text || '.' || p_ext;
$$;

grant execute on function public.document_storage_path(public.document_type, text)
  to authenticated;


-- ##########################################################################
-- ملف: 0011_fix_document_upload.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0011 — إصلاح رفع الوثائق
-- =============================================================================
-- **العَرَض:** كل محاولة رفع صورة حية تفشل برسالة عامة في التطبيق.
--
-- **السبب الأول — تعارض السياسة مع المُشغّل:**
--
--   سياسة الإدراج تشترط status = 'pending'
--   ومُشغّل auto_approve_rider_docs يغيّرها إلى 'approved' للراكب
--
--   مُشغّلات BEFORE تُنفَّذ **قبل** فحص RLS، فالصف الواصل للفحص حالته
--   approved بينما السياسة تشترط pending. النتيجة: رفض كل رفع من راكب.
--
--   المفارقة أن الاعتماد التلقائي نفسه هو ما كان يكسر الرفع.
--
-- **السبب الثاني — upsert على فهرس جزئي:**
--
--   فهرسنا الفريد جزئي (يستثني vehicle_photo لأن صور الدراجة متعددة)،
--   و ON CONFLICT (user_id, doc_type) يتطلب فهرساً كاملاً يطابقه تماماً.
--   بوستغرس يرفض بـ 42P10.
--
-- **الحل:** نقل منطق الرفع كله إلى دالة واحدة في القاعدة، ودمج فرض الحالة
-- مع الاعتماد التلقائي في مُشغّل واحد بدل مُشغّل وسياسة يتنازعان.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- مُشغّل واحد يفرض الحالة ثم يعتمد الراكب
--
-- **لماذا دالة واحدة لا اثنتان؟** ترتيب تنفيذ مُشغّلات BEFORE في بوستغرس
-- أبجدي حسب اسم المُشغّل — اعتماد خفي وهشّ. دمجهما يجعل الترتيب صريحاً
-- في الكود: افرض pending أولاً، ثم اعتمد إن كان راكباً.
-- -----------------------------------------------------------------------------
create or replace function public.enforce_document_status()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role public.user_role;
begin
  -- ١) لا يعتمد المستخدم وثيقته بنفسه.
  --
  -- نفرض pending هنا بدل اشتراطها في سياسة RLS. لماذا؟ لأن السياسة تفحص
  -- الصف **بعد** المُشغّلات، فلو اشترطت pending لتعارضت مع الاعتماد
  -- التلقائي أدناه. الفرض في المُشغّل يحسم التنازع من جذره.
  if not public.is_admin() and not public.guards_bypassed() then
    new.status      := 'pending';
    new.reviewed_by := null;
    new.reviewed_at := null;
  end if;

  -- ٢) الراكب يُعتمد تلقائياً — لا مراجعة يدوية عليه إطلاقاً.
  --
  -- مراجعة صور آلاف الركّاب يدوياً وظيفة بدوام كامل. المراجعة تُحفظ
  -- للسائقين وهم عشرات، لأنهم من ينقل الناس ويقبض المال.
  select role into v_role from public.profiles where id = new.user_id;

  if new.doc_type = 'live_selfie' and v_role = 'rider' then
    new.status      := 'approved';
    new.reviewed_at := now();
  end if;

  return new;
end;
$$;

drop trigger if exists user_documents_auto_approve_riders on public.user_documents;
drop trigger if exists user_documents_enforce_status      on public.user_documents;

create trigger user_documents_enforce_status
  before insert or update on public.user_documents
  for each row execute function public.enforce_document_status();

-- -----------------------------------------------------------------------------
-- السياسات: تتحقق من الملكية فقط، والحالة يفرضها المُشغّل
-- -----------------------------------------------------------------------------
drop policy if exists "documents: المستخدم يرفع وثائقه" on public.user_documents;
create policy "documents: المستخدم يرفع وثائقه"
  on public.user_documents for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "documents: المستخدم يعيد رفع المرفوضة" on public.user_documents;
create policy "documents: المستخدم يعيد رفع المرفوضة"
  on public.user_documents for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- المستخدم يحتاج حذف صفه القديم عند إعادة الرفع.
-- ملاحظة: هذا حذف **سجل** الوثيقة لا **ملف** الصورة — ملفات التخزين
-- تبقى، وحذفها للمشرف وحده كما في 0010، لأنها دليل تحقق.
drop policy if exists "documents: حذف سجل عند إعادة الرفع" on public.user_documents;
create policy "documents: حذف سجل عند إعادة الرفع"
  on public.user_documents for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- =============================================================================
-- دالة تسجيل الوثيقة — المنفذ الوحيد من التطبيق
-- =============================================================================
-- تحلّ محل upsert الذي كان يفشل على الفهرس الجزئي.
--
-- تتصرف حسب النوع:
--   vehicle_photo  →  تُضاف بجانب سابقاتها (صور متعددة للدراجة)
--   ما عداها       →  تستبدل سابقتها (نسخة واحدة لكل نوع)
--
-- وضعها في القاعدة لا في التطبيق يضمن أن تطبيق الراكب وتطبيق السائق
-- ولوحة الإدارة تتصرف بالمنطق نفسه. مصدر واحد للحقيقة.
-- =============================================================================
create or replace function public.submit_document(
  p_doc_type     public.document_type,
  p_storage_path text
)
returns public.user_documents
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.user_documents;
begin
  if v_uid is null then
    raise exception 'يجب تسجيل الدخول أولاً' using errcode = 'insufficient_privilege';
  end if;

  if p_storage_path is null or btrim(p_storage_path) = '' then
    raise exception 'مسار الملف مفقود';
  end if;

  -- المسار يجب أن يبدأ بمعرّف صاحبه — نفس اصطلاح سياسات التخزين في 0010.
  -- بدون هذا الفحص يستطيع مستخدم تسجيل مسار ملف يخص غيره.
  if split_part(p_storage_path, '/', 1) <> v_uid::text then
    raise exception 'مسار الملف لا يطابق حسابك'
      using errcode = 'insufficient_privilege';
  end if;

  -- نسخة واحدة لكل نوع عدا صور الدراجة
  if p_doc_type <> 'vehicle_photo' then
    delete from public.user_documents
    where user_id = v_uid and doc_type = p_doc_type;
  end if;

  insert into public.user_documents (user_id, doc_type, storage_path)
  values (v_uid, p_doc_type, p_storage_path)
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.submit_document(public.document_type, text)
  from public, anon;
grant execute on function public.submit_document(public.document_type, text)
  to authenticated;


-- ##########################################################################
-- ملف: 0012_more_service_zones.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0012 — توسيع مناطق الخدمة إلى ١١ محافظة إضافية
-- =============================================================================
-- **العَرَض:** المستخدم في الناصرية يرى "خدمتنا غير متوفرة في هذه المنطقة".
--
-- **السبب:** 0008 عرّف بغداد والبصرة وأربيل فقط، فأعادت zone_for_point قيمة
-- فارغة لأي نقطة خارجها ورفضت estimate_trip الطلب.
--
-- الرفض سلوك صحيح لا خلل: قبول رحلة في منطقة بلا تسعيرة يعني رحلة بلا
-- أجرة محسوبة. المشكلة كانت في التغطية لا في المنطق.
--
-- **الحدود من OpenStreetMap لا من التخمين.** جُلبت عبر Nominatim ووُسّعت
-- ١٥٪ لتشمل الأطراف والأحياء الجديدة التي تنمو خارج الحدود الرسمية.
--
-- **قيد معروف:** هذه **مستطيلات** لا حدوداً حقيقية. تغطّي المدينة وشيئاً
-- من الصحراء حولها. مقبول الآن — الأثر الوحيد أن راكباً خارج العمران قد
-- يطلب رحلة. قبل التوسّع الجاد ارسم مضلعات دقيقة على geojson.io وبدّلها.
-- =============================================================================

insert into public.pricing_zones (
  city_name, city_name_ar, boundary,
  base_fare_iqd, per_km_iqd, per_minute_iqd, minimum_fare_iqd,
  cancellation_fee_iqd, commission_rate,
  search_radius_m, max_search_radius_m
) values
-- الناصرية
(
  'Nasiriyah', 'الناصرية',
  st_geogfromtext('POLYGON((46.0319 30.836, 46.4479 30.836, 46.4479 31.252, 46.0319 31.252, 46.0319 30.836))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
),
-- النجف
(
  'Najaf', 'النجف',
  st_geogfromtext('POLYGON((44.122 31.793, 44.538 31.793, 44.538 32.209, 44.122 32.209, 44.122 31.793))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
),
-- كربلاء
(
  'Karbala', 'كربلاء',
  st_geogfromtext('POLYGON((43.9225 32.4998, 44.128 32.4998, 44.128 32.6815, 43.9225 32.6815, 43.9225 32.4998))'),
  1000, 250, 25, 1500, 1000, 0.150,
  3500, 9000
),
-- الحلة
(
  'Hillah', 'الحلة',
  st_geogfromtext('POLYGON((44.2248 32.2742, 44.6408 32.2742, 44.6408 32.6902, 44.2248 32.6902, 44.2248 32.2742))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
),
-- الديوانية
(
  'Diwaniyah', 'الديوانية',
  st_geogfromtext('POLYGON((44.5308 31.6466, 45.2857 31.6466, 45.2857 32.4005, 44.5308 32.4005, 44.5308 31.6466))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
),
-- العمارة
(
  'Amarah', 'العمارة',
  st_geogfromtext('POLYGON((46.9416 31.6418, 47.3576 31.6418, 47.3576 32.0578, 46.9416 32.0578, 46.9416 31.6418))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
),
-- الكوت
(
  'Kut', 'الكوت',
  st_geogfromtext('POLYGON((45.4159 32.2885, 46.2461 32.2885, 46.2461 32.8604, 45.4159 32.8604, 45.4159 32.2885))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
),
-- السماوة
(
  'Samawah', 'السماوة',
  st_geogfromtext('POLYGON((45.0747 31.0999, 45.4907 31.0999, 45.4907 31.5159, 45.0747 31.5159, 45.0747 31.0999))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
),
-- الموصل
(
  'Mosul', 'الموصل',
  st_geogfromtext('POLYGON((43.0279 36.2837, 43.1796 36.2837, 43.1796 36.4048, 43.0279 36.4048, 43.0279 36.2837))'),
  1000, 250, 25, 1500, 1000, 0.150,
  3500, 9000
),
-- كركوك
(
  'Kirkuk', 'كركوك',
  st_geogfromtext('POLYGON((44.1874 35.2639, 44.6034 35.2639, 44.6034 35.6799, 44.1874 35.6799, 44.1874 35.2639))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
),
-- السليمانية
(
  'Sulaymaniyah', 'السليمانية',
  st_geogfromtext('POLYGON((45.2346 35.3491, 45.6506 35.3491, 45.6506 35.7651, 45.2346 35.7651, 45.2346 35.3491))'),
  1000, 250, 25, 1500, 1000, 0.150,
  4000, 10000
);

-- كل منطقة جديدة تبدأ بلا ذروة.
-- not exists يجعل الملف آمناً للتكرار: لا يضاعف الصفوف إن أُعيد تشغيله.
insert into public.surge_state (zone_id, multiplier)
select z.id, 1.00
from public.pricing_zones z
where not exists (
  select 1 from public.surge_state s where s.zone_id = z.id
);

-- تقرير التغطية
select city_name_ar as "المدينة",
       round(st_area(boundary) / 1000000)::int as "المساحة (كم٢)",
       search_radius_m as "نطاق البحث"
from public.pricing_zones
where is_active
order by city_name_ar;


-- ##########################################################################
-- ملف: 0013_pricing_distance_only.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0013 — التسعير بالمسافة وحدها
-- =============================================================================
-- **القرار:** إلغاء عامل الزمن من معادلة الأجرة.
--
--   قبل:  500 + (كم × 250) + (دقيقة × 25)   حد أدنى 1500
--   بعد:  500 + (كم × 350)                   حد أدنى 1000
--
-- **لماذا أُلغي الزمن؟**
--
-- ١) تقديره غير دقيق ولن يصير دقيقاً. OSRM يفترض **سيارة** لا دراجة، وقدّر
--    ١.٥ كم في الناصرية بعشر دقائق — أي ٩ كم/ساعة، وهو بطيء غير واقعي.
--    والدراجة تتجاوز الزحام أصلاً، وهو سبب اختيار الناس لها.
--
-- ٢) السعر يصير **متوقعاً**. الراكب يعرف أن مشوار الجامعة يكلفه ١٥٠٠ دائماً،
--    لا ١٥٠٠ صباحاً و٢٠٠٠ ظهراً. الثقة أثمن من دقة محاسبية في سوق ناشئ.
--
-- **الثمن المقبول:** السائق العالق في زحام طويل لا يُعوَّض. البديل الأعدل
-- موجود أصلاً في التصميم: معامل الذروة `surge_state` — يرفع السعر حين
-- **يقل السائقون فعلاً**، لا حين يبطئ الشارع.
--
-- **لا يحتاج هذا تعديل كود.** دالة calculate_fare تضرب الدقائق في
-- per_minute_iqd، وضبطه على صفر يُلغي المكوّن. البنية كانت جاهزة لهذا
-- لأننا جعلنا التسعير بيانات لا ثوابت مكتوبة في الدوال.
-- =============================================================================

update public.pricing_zones
set base_fare_iqd    = 500,
    per_km_iqd       = 350,
    per_minute_iqd   = 0,
    minimum_fare_iqd = 1000
where is_active;

-- =============================================================================
-- السلّم الناتج — للمراجعة
-- =============================================================================
-- generate_series يوّلد رحلات نموذجية ونحسب أجرة كل منها بالدالة الحقيقية
-- لا بحساب يدوي. لو غيّرنا المعادلة لاحقاً يعكس هذا التقرير التغيير فوراً.
-- =============================================================================
select
  d.km || ' كم'                                              as "المسافة",
  (public.calculate_fare(z.id, (d.km * 1000)::int, 0) ->> 'total')::numeric
                                                             as "الأجرة",
  (public.calculate_fare(z.id, (d.km * 1000)::int, 0) ->> 'commission')::numeric
                                                             as "العمولة",
  (public.calculate_fare(z.id, (d.km * 1000)::int, 0) ->> 'driver_earning')::numeric
                                                             as "للسائق"
from (values (1.5), (3.0), (5.0), (8.0), (12.0), (20.0)) as d(km)
cross join (select id from public.pricing_zones where city_name = 'Nasiriyah') z
order by d.km;


-- ##########################################################################
-- ملف: 0014_trip_coordinates.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0014 — إحداثيات الرحلة كأعمدة قابلة للقراءة
-- =============================================================================
-- **المشكلة:** تطبيق السائق يحتاج إحداثيات نقطة الانطلاق والوجهة ليفتح
-- Waze عليها. لكن PostgREST يعيد عمود geography بصيغة WKB سداسية عشرية
-- (`0101000020E6100000...`) وهي غير قابلة للقراءة في التطبيق.
--
-- **الخيارات المرفوضة:**
--   - تفكيك WKB في التطبيق: كود هشّ يتعامل مع ترتيب البايتات ونظام
--     الإحداثيات، وأي خطأ فيه يرسل السائق إلى مكان خاطئ.
--   - دالة RPC لكل رحلة: نداء شبكة إضافي لبيانات موجودة أصلاً في الصف.
--
-- **الحل:** أعمدة محسوبة ومخزّنة. بوستغرس يحسبها مرة عند الإدراج ويعيدها
-- كأرقام عادية. لا كلفة استعلام، ولا كود تفكيك، ولا تعارض ممكن بينها
-- وبين العمود الأصلي لأنها مشتقة منه لا مكتوبة يدوياً.
--
-- **تذكير الترتيب:** st_y يعطي خط العرض (latitude) و st_x خط الطول
-- (longitude). PostGIS يخزّن (lng, lat) عكس ترتيب الخرائط الشائع، وهذا
-- مصدر أخطاء متكرر — لذلك نسمّي الأعمدة صراحةً.
-- =============================================================================

alter table public.trips
  add column if not exists pickup_lat double precision
    generated always as (st_y(pickup_location::geometry)) stored,
  add column if not exists pickup_lng double precision
    generated always as (st_x(pickup_location::geometry)) stored,
  add column if not exists dropoff_lat double precision
    generated always as (st_y(dropoff_location::geometry)) stored,
  add column if not exists dropoff_lng double precision
    generated always as (st_x(dropoff_location::geometry)) stored;

comment on column public.trips.pickup_lat is
  'خط العرض، مشتق آلياً من pickup_location. للقراءة من التطبيق.';
comment on column public.trips.dropoff_lat is
  'خط العرض، مشتق آلياً من dropoff_location. للقراءة من التطبيق.';

-- تحقّق: يجب أن تطابق الإحداثيات المستخرجة النقطة الأصلية
select
  trip_number as "رقم الرحلة",
  round(pickup_lat::numeric, 5)  as "انطلاق (عرض)",
  round(pickup_lng::numeric, 5)  as "انطلاق (طول)",
  round(dropoff_lat::numeric, 5) as "وجهة (عرض)",
  round(dropoff_lng::numeric, 5) as "وجهة (طول)"
from public.trips
order by requested_at desc
limit 5;


-- ##########################################################################
-- ملف: 0015_tracking_and_fees.sql
-- ##########################################################################

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


-- ##########################################################################
-- ملف: 0016_notify_trigger.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0016 — استدعاء دالة الإشعارات عند إنشاء عرض
-- =============================================================================
-- **شرط مسبق:** انشر الدالة `notify-driver` من لوحة Supabase أولاً، وأضف
-- سرّ `FIREBASE_SERVICE_ACCOUNT`. بدونهما يفشل الاستدعاء بصمت (وهو مقبول
-- — العرض يصل عبر البثّ اللحظي ما دام التطبيق مفتوحاً).
-- =============================================================================

-- pg_net يتيح لبوستغرس إطلاق طلبات HTTP **غير متزامنة**.
--
-- عدم التزامن جوهري هنا: لو انتظر المُشغّل رد Firebase لتأخّر إنشاء العرض
-- ثانية أو ثانيتين — وهي عمر ثمين من مهلة الخمس عشرة ثانية.
create extension if not exists pg_net with schema extensions;

-- -----------------------------------------------------------------------------
-- إعدادات الاستدعاء
-- -----------------------------------------------------------------------------
-- نخزّنها في جدول لا في نص الدالة: تغيير المفتاح لاحقاً يصير تحديث صف
-- بدل إعادة تعريف دالة.
--
-- **لا يُقرأ من التطبيق إطلاقاً** — RLS مفعّلة بلا سياسة قراءة، فحتى
-- المدير لا يراه من اللوحة. الدوال security definer وحدها تصل إليه.
-- -----------------------------------------------------------------------------
create table if not exists public.app_config (
  key         text primary key,
  value       text not null,
  updated_at  timestamptz not null default now()
);

alter table public.app_config enable row level security;
-- لا سياسات: لا أحد يقرأ ولا يكتب من التطبيق. عمداً.

comment on table public.app_config is
  'إعدادات داخلية للخادم. لا تُقرأ من التطبيقات — RLS بلا سياسات.';

-- -----------------------------------------------------------------------------
-- المُشغّل
-- -----------------------------------------------------------------------------
create or replace function public.notify_driver_of_offer()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text;
  v_key text;
begin
  select value into v_url from public.app_config where key = 'edge_notify_url';
  select value into v_key from public.app_config where key = 'edge_service_key';

  -- الإعداد ناقص — لا نُفشل إنشاء العرض بسببه.
  --
  -- الإشعار تحسين لا شرط: العرض يصل عبر البثّ اللحظي ما دام التطبيق
  -- مفتوحاً. إسقاط الرحلة لأن الإشعار لم يُضبط خطأ فادح.
  if v_url is null or v_key is null then
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := jsonb_build_object('record', to_jsonb(new)),
    timeout_milliseconds := 5000
  );

  return new;
end;
$$;

drop trigger if exists trip_offers_notify on public.trip_offers;
create trigger trip_offers_notify
  after insert on public.trip_offers
  for each row execute function public.notify_driver_of_offer();

-- =============================================================================
-- بعد نشر الدالة، شغّل هذا بقيمك (احذف علامات التعليق)
-- =============================================================================
-- المفتاح المطلوب هو **service_role** من Settings → API. يُخزَّن في القاعدة
-- ولا يصل التطبيقات إطلاقاً — RLS بلا سياسات تمنع قراءته.
-- =============================================================================
/*
insert into public.app_config (key, value) values
  ('edge_notify_url',
   'https://jacixgrnovflddrzbegd.supabase.co/functions/v1/notify-driver'),
  ('edge_service_key', 'ضع_service_role_key_هنا')
on conflict (key) do update set value = excluded.value, updated_at = now();
*/

-- تحقّق من التركيب
select
  tgname                                        as "المُشغّل",
  case when tgenabled = 'O' then 'مفعّل' else 'معطّل' end as "الحالة",
  (select count(*) from public.app_config)      as "إعدادات مضبوطة"
from pg_trigger
where tgname = 'trip_offers_notify';


-- ##########################################################################
-- ملف: 0017_persistent_search.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0017 — البحث المستمر عن سائق، وتشغيل العامل الدوري
-- =============================================================================
-- **ثغرة أخطر اكتُشفت أثناء هذا العمل:** كتبنا `expire_stale_offers()` في
-- 0006 لتنهي العروض المنتهية وتنتقل للسائق التالي… **ولم نجدولها إطلاقاً.**
--
-- الأثر: عرض لم يردّ عليه السائق يبقى `pending` إلى الأبد، والرحلة عالقة
-- في `searching` بلا محاولة تالية. لم نلحظه لأن اختباراتنا كانت بسائق
-- واحد يقبل فوراً.
--
-- **والتغيير المطلوب:** لا نقول للراكب "لا يوجد سائق" بعد ثماني محاولات.
-- نستمر بالبحث حتى يلغي هو أو تنتهي مهلة طويلة. السائق قد يتصل بعد
-- دقيقة، والراكب الذي رُفض طلبه لن يعيد المحاولة غالباً.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ١) مهلة البحث القصوى
-- -----------------------------------------------------------------------------
alter table public.pricing_zones
  add column if not exists max_search_seconds integer not null default 600;

comment on column public.pricing_zones.max_search_seconds is
  'أقصى مدة بحث قبل الاستسلام. ١٠ دقائق افتراضياً.';


-- -----------------------------------------------------------------------------
-- ٢) إعادة كتابة الإرسال: نستمر بدل الاستسلام
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
  v_elapsed  integer;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;   -- الرحلة قُبلت أو أُلغيت بينما كنا نبحث
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  -- هل تجاوزنا مهلة البحث الكلية؟
  v_elapsed := extract(epoch from (now() - v_trip.requested_at))::integer;
  if v_elapsed > v_zone.max_search_seconds then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  -- لا يوجد عرض معلّق حالياً؟ (وإلا ننتظر رده)
  if exists (
    select 1 from public.trip_offers
    where trip_id = p_trip_id and status = 'pending' and expires_at > now()
  ) then
    return null;
  end if;

  -- السائقون الذين عُرضت عليهم الرحلة في **الجولة الحالية**.
  --
  -- **التغيير الجوهري:** بعد استنفاد كل السائقين نبدأ جولة جديدة بدل
  -- الاستسلام. السائق الذي رفض قبل دقيقتين قد يكون فرغ الآن، والذي كان
  -- بعيداً قد اقترب.
  select coalesce(array_agg(driver_id), array[]::uuid[]), count(*)
  into v_tried, v_rank
  from public.trip_offers
  where trip_id = p_trip_id
    and sent_at > now() - make_interval(secs => 120);   -- جولة = دقيقتان

  -- توسيع النطاق تدريجياً داخل الجولة
  v_radius := least(
    v_zone.search_radius_m * (1 + (v_rank / 3)),
    v_zone.max_search_radius_m
  );

  select * into v_candidate
  from public.find_nearby_drivers(v_trip.pickup_location, v_radius, 1, v_tried);

  if not found then
    -- لا سائق متاح الآن — **لا نستسلم**. نترك الرحلة `searching`
    -- والعامل الدوري سيعيد المحاولة بعد ثوانٍ.
    return null;
  end if;

  insert into public.trip_offers (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
  values (
    p_trip_id,
    v_candidate.driver_id,
    v_rank + 1,
    v_candidate.distance_m,
    (v_candidate.distance_m / 6.9)::integer,
    now() + make_interval(secs => v_zone.offer_timeout_s)
  )
  returning * into v_offer;

  return v_offer;
end;
$$;


-- -----------------------------------------------------------------------------
-- ٣) العامل الدوري: ينهي المنتهي ويعيد المحاولة
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_tick()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_expired integer := 0;
  v_retried integer := 0;
  v_offline integer := 0;
  v_trip_id uuid;
begin
  -- إنهاء العروض التي انتهت مهلتها
  with done as (
    update public.trip_offers
    set status = 'expired', responded_at = now()
    where status = 'pending' and expires_at < now()
    returning 1
  )
  select count(*) into v_expired from done;

  -- فصل السائقين الذين انقطع تحديث موقعهم.
  -- موقع عمره دقيقتان لا يُعتمد عليه — أسوأ من لا موقع لأنه يرسل
  -- الراكب إلى مكان غادره السائق.
  with gone as (
    update public.drivers
    set status = 'offline'
    where status = 'online'
      and (location_updated_at is null
           or location_updated_at < now() - interval '2 minutes')
    returning 1
  )
  select count(*) into v_offline from gone;

  -- إعادة المحاولة لكل رحلة ما زالت تبحث
  for v_trip_id in
    select id from public.trips where status = 'searching'
  loop
    perform public.dispatch_next_offer(v_trip_id);
    v_retried := v_retried + 1;
  end loop;

  return jsonb_build_object(
    'expired_offers', v_expired,
    'searching_trips', v_retried,
    'drivers_set_offline', v_offline,
    'at', now()
  );
end;
$$;

revoke all on function public.dispatch_tick from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٤) الجدولة — هذا ما كان ناقصاً
-- -----------------------------------------------------------------------------
-- pg_cron أدق تفصيل يقبله هو الدقيقة. ونحن نحتاج كل خمس ثوانٍ، فنجدول
-- مهمة واحدة كل دقيقة تدور داخلياً اثنتي عشرة مرة بفاصل خمس ثوانٍ.
--
-- حيلة مقبولة عند هذا الحجم. عند آلاف الرحلات يومياً تُستبدل بخدمة
-- مستقلة تحتفظ بشبكة السائقين في الذاكرة.
-- -----------------------------------------------------------------------------
create extension if not exists pg_cron with schema extensions;

create or replace function public.dispatch_minute()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  i integer;
begin
  for i in 1..12 loop
    perform public.dispatch_tick();
    -- pg_sleep داخل مهمة مجدولة مقبول: تعمل في اتصالها الخاص ولا
    -- تحجب أحداً. لكنها تشغل اتصالاً لدقيقة كاملة — سبب إضافي
    -- لاستبدالها بخدمة مستقلة عند التوسّع.
    if i < 12 then perform pg_sleep(5); end if;
  end loop;
end;
$$;

-- نحذف أي جدولة سابقة قبل الإضافة — يجعل الملف آمناً للتكرار
select cron.unschedule('zanbour-dispatch')
where exists (select 1 from cron.job where jobname = 'zanbour-dispatch');

select cron.schedule(
  'zanbour-dispatch',
  '* * * * *',                       -- كل دقيقة
  $cron$ select public.dispatch_minute(); $cron$
);


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  jobname   as "المهمة",
  schedule  as "الجدولة",
  active    as "مفعّلة"
from cron.job
where jobname = 'zanbour-dispatch';


-- ##########################################################################
-- ملف: 0018_offer_timeout.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0018 — مهلة العرض: من ١٥ ثانية إلى ٤٥
-- =============================================================================
-- **الخطأ الذي نصلحه:** خمس عشرة ثانية رقم مأخوذ من تطبيقات سيارات الأجرة،
-- حيث الهاتف مثبّت على المقود والتطبيق مفتوح أمام السائق. ثم بنينا
-- الإشعارات تحديداً ليعمل المنتج **والهاتف في الجيب والشاشة مطفأة** —
-- وتركنا مهلة لا تكفي لإخراج الهاتف. الميزتان تتناقضان.
--
-- ظهر ذلك في أول اختبار حقيقي: الإشعار يصل، والسائق يضغطه، فيجد نفسه في
-- الشاشة الرئيسية. لم يكن التوجيه معطّلاً — كان يعمل بدقة ويجد العرض قد
-- انتهى. التسلسل: اهتزاز عند ٣، إخراج الهاتف وفتح القفل حتى ١٠، ضغط
-- الإشعار عند ١٢، وانتهاء العرض عند ١٥ قبل أن يستيقظ التطبيق.
--
-- **لماذا ٤٥ لا ٦٠ ولا ٣٠؟** الجولة الواحدة ١٢٠ ثانية، فـ٤٥ تترك متسعاً
-- لعرضين متتاليين داخلها. وهي أطول من زمن الإخراج والفتح والقراءة بهامش
-- مريح، دون أن يطول انتظار الراكب قبل انتقال طلبه إلى سائق آخر.
-- =============================================================================

alter table public.pricing_zones
  alter column offer_timeout_s set default 45;

-- المناطق الأربع عشرة القائمة كلها على ١٥. نرفع ما لم يُخصَّص يدوياً فقط.
update public.pricing_zones
set offer_timeout_s = 45
where offer_timeout_s = 15;

comment on column public.pricing_zones.offer_timeout_s is
  'مهلة ردّ السائق على العرض بالثواني. ٤٥ افتراضياً — تكفي لإخراج الهاتف '
  'وفتح القفل وقراءة الطلب، وتبقى دون الجولة (١٢٠ث).';


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select city_name_ar as "المنطقة", offer_timeout_s as "مهلة العرض (ث)"
from public.pricing_zones
order by city_name_ar;


-- ##########################################################################
-- ملف: 0019_party_identity.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0019 — طرفا الرحلة يتعارفان: صورة، ولوحة، ولون
-- =============================================================================
-- الأساس الأمني كان مبنياً منذ 0007: العرض `trip_party_info` يكشف الحقول
-- الآمنة وحدها، والهاتف أثناء الرحلة النشطة فقط. لكن ثلاثة أشياء كانت
-- ناقصة **من الجذر لا من الواجهة**:
--
--   ١) `profiles.avatar_url` عمود موجود، والعرض يكشفه، والشاشات تتجاهله —
--      **ولا سطر في المشروع يكتب فيه قيمة.** الصورة الحية تُخزَّن وثيقةَ
--      هوية في مخزن خاص، ولا أحد يربطها بالملف الشخصي.
--
--   ٢) اللوحة واللون أعمدة فارغة في كل صف. كتبنا في 0003 أن "المدير
--      يملؤها وقت المراجعة"، ولم نبنِ له مكاناً يملؤها فيه. فسطر اللوحة
--      في شاشة الراكب كود ميت لا يظهر أبداً.
--
--   ٣) `vehicle_type` — الحقل الوحيد المجموع فعلاً — ليس في العرض أصلاً.
--
-- القرار: السائق يكتب اللوحة واللون عند التسجيل، والمدير يتحقق منهما
-- مقابل صور الدراجة عند الاعتماد. أدقّ من ترك المدير يقرأ كل لوحة من
-- صورة، وأسرع من انتظاره.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) التسجيل يلتقط اللوحة واللون
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  requested_role public.user_role;
  v_full_name text;
  v_phone     text;
  v_address   text;
  v_dob       date;
  v_age       integer;
begin
  requested_role := coalesce(
    nullif(new.raw_user_meta_data ->> 'role', '')::public.user_role,
    'rider'
  );

  v_full_name := btrim(new.raw_user_meta_data ->> 'full_name');
  v_phone     := nullif(btrim(new.raw_user_meta_data ->> 'phone'), '');
  v_address   := nullif(btrim(new.raw_user_meta_data ->> 'address'), '');
  v_dob       := (nullif(new.raw_user_meta_data ->> 'date_of_birth', ''))::date;

  if v_full_name is null or v_full_name = '' then
    raise exception 'الاسم الكامل مطلوب للتسجيل';
  end if;

  if array_length(regexp_split_to_array(v_full_name, '\s+'), 1) < 3 then
    raise exception 'الاسم الثلاثي مطلوب: الاسم واسم الأب واسم الجد';
  end if;

  if v_phone is null then
    raise exception 'رقم الهاتف مطلوب للتسجيل';
  end if;

  if v_address is null then
    raise exception 'العنوان مطلوب للتسجيل';
  end if;

  if v_dob is null then
    raise exception 'تاريخ الميلاد مطلوب للتسجيل';
  end if;

  v_age := extract(year from age(current_date, v_dob))::integer;
  if requested_role = 'driver' and v_age < 18 then
    raise exception 'العمر الأدنى لتسجيل السائق ١٨ سنة';
  elsif v_age < 16 then
    raise exception 'العمر الأدنى للتسجيل ١٦ سنة';
  end if;

  if exists (select 1 from public.profiles where phone = v_phone) then
    raise exception 'رقم الهاتف مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;
  if exists (select 1 from public.profiles where full_name = v_full_name) then
    raise exception 'الاسم مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;

  insert into public.profiles (
    id, full_name, email, date_of_birth, address, phone, role, locale
  )
  values (
    new.id,
    v_full_name,
    new.email,
    v_dob,
    v_address,
    v_phone,
    requested_role,
    coalesce(nullif(new.raw_user_meta_data ->> 'locale', ''), 'ar')
  );

  -- **التغيير:** اللوحة واللون معهما. يبقيان اختياريين في المخطط —
  -- غيابهما لا يمنع الاعتماد، والمدير يصحّحهما من صور الدراجة.
  if requested_role = 'driver' then
    insert into public.drivers (id, vehicle_type, vehicle_plate, vehicle_color)
    values (
      new.id,
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_type'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_plate'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_color'), '')
    );
  end if;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الصورة الحية تصير صورة الملف الشخصي
-- -----------------------------------------------------------------------------
-- **لماذا مُشغّل لا كتابة من التطبيق؟** لأن الصورة تُرفع من ثلاثة مسارات
-- (تسجيل الراكب، تسجيل السائق، إعادة رفع وثيقة مرفوضة)، ونسيان أحدها
-- يترك مستخدمين بلا صورة بلا سبب ظاهر. المُشغّل يلتقطها من مصدر واحد.
--
-- نخزّن **المسار** لا رابطاً كاملاً: المخزن خاص، والقراءة برابط موقّع
-- قصير الأجل يُولّده التطبيق عند العرض.
create or replace function public.sync_avatar_from_selfie()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.doc_type = 'live_selfie' then
    update public.profiles
    set avatar_url = new.storage_path
    where id = new.user_id;
  end if;
  return new;
end;
$fn$;

drop trigger if exists user_documents_sync_avatar on public.user_documents;
create trigger user_documents_sync_avatar
  after insert or update of storage_path on public.user_documents
  for each row execute function public.sync_avatar_from_selfie();

-- من سجّل قبل اليوم له صورة حية ولا `avatar_url`. نملؤها بأحدث صورة له.
update public.profiles p
set avatar_url = d.storage_path
from (
  select distinct on (user_id) user_id, storage_path
  from public.user_documents
  where doc_type = 'live_selfie'
  order by user_id, created_at desc
) d
where d.user_id = p.id and p.avatar_url is null;


-- -----------------------------------------------------------------------------
-- ٣) الطرف الآخر يقرأ صورتك أثناء الرحلة النشطة وحدها
-- -----------------------------------------------------------------------------
-- كتبنا في 0010: "لا أحد غيرهما — حتى طرفا الرحلة لا يريان صور بعضهما".
-- كان ذلك صحيحاً حين كانت الوثائق كلها سواء. الآن نفتح **الصورة الحية
-- وحدها**، **لطرف الرحلة وحده**، **أثناء نشاطها وحده**. البطاقة الوطنية
-- وصور الدراجة تبقى محجوبة كما كانت.
--
-- شرط `like '%/live_selfie_%'` يحصر السياسة بنوع واحد من الملفات، واصطلاح
-- المسار من 0010 يضمن أن الجزء الأول هو معرّف صاحب الصورة.
drop policy if exists "documents: صورة الطرف الآخر أثناء الرحلة" on storage.objects;
create policy "documents: صورة الطرف الآخر أثناء الرحلة"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documents'
    and name like '%/live_selfie_%'
    and exists (
      select 1 from public.trips t
      where t.status in ('accepted', 'driver_arrived', 'in_progress')
        and (
          (t.rider_id  = auth.uid()
             and t.driver_id::text = (storage.foldername(name))[1])
          or
          (t.driver_id = auth.uid()
             and t.rider_id::text  = (storage.foldername(name))[1])
        )
    )
  );


-- -----------------------------------------------------------------------------
-- ٤) العرض يكشف نوع الدراجة كذلك
-- -----------------------------------------------------------------------------
-- **نحذف قبل الإنشاء لا `create or replace`:** الأخير لا يقبل إلا إضافة
-- أعمدة في النهاية، ونحن ندسّ `vehicle_type` بين الأعمدة القائمة ليقرأ
-- التعريف مرتّباً. الحذف يُسقط الصلاحيات معه، فنعيد منحها أدناه.
drop view if exists public.trip_party_info;

create view public.trip_party_info
with (security_barrier = true)
as
select
  t.id   as trip_id,
  p.id   as person_id,
  case when p.id = t.driver_id then 'driver' else 'rider' end as party,

  p.full_name,
  p.avatar_url,

  -- الهاتف يُكشف أثناء الرحلة النشطة فقط. بعد انتهائها لا يبقى سبب
  -- لبقاء رقم الراكب في يد السائق.
  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end as phone,

  d.rating_avg,
  d.vehicle_type,
  d.vehicle_plate,
  d.vehicle_make,
  d.vehicle_model,
  d.vehicle_color

from public.trips t
join public.profiles p
  on p.id = t.rider_id or p.id = t.driver_id
left join public.drivers d on d.id = p.id
-- الفلتر الأمني: لا تُرجع إلا رحلات المستدعي نفسه
where t.rider_id = auth.uid() or t.driver_id = auth.uid();

comment on view public.trip_party_info is
  'الحقول الآمنة فقط عن طرفي الرحلة. لا يكشف رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.profiles where avatar_url is not null)
    as "ملفات لها صورة",
  (select count(*) from public.profiles) as "مجموع الملفات",
  (select count(*) from public.drivers where vehicle_plate is not null)
    as "سائقون لهم لوحة";


-- ##########################################################################
-- ملف: 0020_broadcast_dispatch.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0020 — البثّ المتوازي: خمسة سائقين معاً، وأولهم قبولاً يفوز
-- =============================================================================
-- المحرك حتى الآن **تسلسلي**: عرض واحد لسائق واحد، وانتظار ردّه قبل
-- الانتقال للتالي. مع مهلة ٤٥ ثانية يعني هذا أن ثالث أقرب سائق لا يرى
-- الطلب قبل دقيقة ونصف — والراكب واقف ينتظر.
--
-- الجديد: **بثّ متوازي** للأقرب فالأقرب. خمسة يرون الطلب معاً، وأولهم
-- قبولاً يأخذه، ومن يرفض يُستبدل فوراً بالسادس فيبقى العدد خمسة.
--
-- =============================================================================
-- **ثغرة كُشفت أثناء كتابة هذا الملف: `unique (trip_id, driver_id)`.**
--
-- القيد كُتب في 0004 بتعليق "لا نعرض نفس الرحلة على نفس السائق مرتين"،
-- وكان صحيحاً حينها. ثم كتبنا في 0017 منطق **الجولات المتكررة** — يعيد
-- العرض على من رفض بعد مدة — دون أن ننتبه أن القيد يمنعه.
--
-- الأثر: محاولة إعادة العرض ترفع `unique_violation`، فتُجهض حلقة
-- `dispatch_tick` كلها. أي أن الجولة الثانية **لم تعمل يوماً**، وما ظننّاه
-- "بحثاً مستمراً" كان جولة واحدة ثم صمت حتى تنتهي العشر دقائق.
--
-- البديل: فهرس فريد **جزئي** يمنع عرضين معلّقين في آنٍ واحد على السائق
-- نفسه لنفس الرحلة، ويسمح بعرض جديد بعد أن يُحسم الأول.
-- =============================================================================

alter table public.trip_offers
  drop constraint if exists trip_offers_trip_id_driver_id_key;

drop index if exists public.trip_offers_one_pending_idx;
create unique index trip_offers_one_pending_idx
  on public.trip_offers (trip_id, driver_id)
  where status = 'pending';


-- -----------------------------------------------------------------------------
-- ١) ضوابط البثّ — في المنطقة لا في الكود
-- -----------------------------------------------------------------------------
alter table public.pricing_zones
  add column if not exists max_concurrent_offers smallint not null default 5,
  add column if not exists offer_round_seconds   integer  not null default 60;

comment on column public.pricing_zones.max_concurrent_offers is
  'كم سائقاً يرى الطلب في آنٍ واحد. أولهم قبولاً يفوز.';

comment on column public.pricing_zones.offer_round_seconds is
  'بعد كم ثانية يُعاد عرض الرحلة على سائق رفضها أو أهملها.';


-- -----------------------------------------------------------------------------
-- ٢) الإرسال: نملأ المقاعد الخمسة بدل مقعد واحد
-- -----------------------------------------------------------------------------
-- نُبقي الاسم `dispatch_next_offer` لأن `reject_trip_offer` تستدعيه —
-- فرفض السائق يملأ مقعده فوراً بالسادس دون انتظار النبضة التالية.
create or replace function public.dispatch_next_offer(p_trip_id uuid)
returns public.trip_offers
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip      public.trips;
  v_zone      public.pricing_zones;
  v_tried     uuid[];
  v_sent      integer;      -- كم عرضاً أُرسل لهذه الرحلة إجمالاً (لتوسيع النطاق)
  v_live      integer;      -- كم عرضاً معلّقاً الآن
  v_need      integer;      -- كم مقعداً شاغراً
  v_radius    integer;
  v_candidate record;
  v_offer     public.trip_offers;
  v_elapsed   integer;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;   -- الرحلة قُبلت أو أُلغيت بينما كنا نبحث
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  -- هل تجاوزنا مهلة البحث الكلية؟
  v_elapsed := extract(epoch from (now() - v_trip.requested_at))::integer;
  if v_elapsed > v_zone.max_search_seconds then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  -- المقاعد المشغولة الآن
  select count(*) into v_live
  from public.trip_offers
  where trip_id = p_trip_id and status = 'pending' and expires_at > now();

  v_need := v_zone.max_concurrent_offers - v_live;
  if v_need <= 0 then
    return null;   -- الخمسة ممتلئة — ننتظر ردّاً أو انتهاء مهلة
  end if;

  -- السائقون المستبعدون **في الجولة الحالية**: من عُرضت عليه الرحلة خلال
  -- آخر `offer_round_seconds`. بعدها يعود إلى المنافسة — قد يكون فرغ،
  -- أو اقترب.
  select coalesce(array_agg(driver_id), array[]::uuid[])
  into v_tried
  from public.trip_offers
  where trip_id = p_trip_id
    and sent_at > now() - make_interval(secs => v_zone.offer_round_seconds);

  select count(*) into v_sent
  from public.trip_offers where trip_id = p_trip_id;

  -- توسيع النطاق تدريجياً كلما طال البحث
  v_radius := least(
    v_zone.search_radius_m * (1 + (v_sent / 5)),
    v_zone.max_search_radius_m
  );

  -- **الأقرب فالأقرب:** find_nearby_drivers ترتّب بالمسافة، فأول من نُدخله
  -- هو الأقرب. مع البثّ المتوازي يبقى الترتيب مهماً في `rank` وحده —
  -- الخمسة يرون الطلب في اللحظة نفسها.
  for v_candidate in
    select * from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried
    )
  loop
    insert into public.trip_offers
      (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
    values (
      p_trip_id,
      v_candidate.driver_id,
      v_sent + 1,
      v_candidate.distance_m,
      (v_candidate.distance_m / 6.9)::integer,
      now() + make_interval(secs => v_zone.offer_timeout_s)
    )
    -- سباق: نبضتان متزامنتان قد تختاران السائق نفسه. الفهرس الجزئي
    -- يمنع التكرار، وهذا يمنع الاستثناء من إجهاض الحلقة.
    on conflict do nothing
    returning * into v_offer;

    v_sent := v_sent + 1;
  end loop;

  return v_offer;   -- آخر عرض أُنشئ، أو null إن لم يوجد مرشّح
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) العامل الدوري يبقى كما هو منطقاً، ونعيد تعريفه للتوثيق فقط
-- -----------------------------------------------------------------------------
-- لا تغيير في جسده: ينهي المنتهي، ويفصل السائق الشبح، ويستدعي الإرسال
-- لكل رحلة تبحث. الفرق أن الاستدعاء صار يملأ خمسة مقاعد لا مقعداً.


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar             as "المنطقة",
  max_concurrent_offers    as "عروض متزامنة",
  offer_timeout_s          as "مهلة العرض (ث)",
  offer_round_seconds      as "العودة بعد (ث)"
from public.pricing_zones
order by city_name_ar;


-- ##########################################################################
-- ملف: 0021_lock_and_privacy_fixes.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0021 — العامل الدوري كان يقفل الرحلات دقيقةً كاملة
-- =============================================================================
-- **رمز الخطأ 57014 هو `query_canceled` — انتهاء مهلة الاستعلام.** ظهر
-- للراكب حين حاول إلغاء طلبه، وللسائق حين حاول القبول. ولم يكن سببه
-- بطء الشبكة ولا ضعف الخادم، بل قفلٌ نضعه نحن.
--
-- **السبب:** `dispatch_minute` تدور اثنتي عشرة مرة مع `pg_sleep(5)` بينها،
-- وكل ذلك **داخل معاملة واحدة**. و`dispatch_next_offer` تبدأ بـ
-- `select * from trips ... for update`. فقفل صفّ الرحلة يبقى محجوزاً
-- **حتى نهاية الدقيقة كلها** لا حتى نهاية النبضة.
--
-- فأي محاولة من الراكب أو السائق لتعديل تلك الرحلة تصطف خلف القفل، وحدّ
-- المهلة في Supabase ثماني ثوانٍ، فتُقتل ويظهر 57014.
--
-- كتبتُ في 0017 تعليقاً يقول إن `pg_sleep` هنا "لا تحجب أحداً". كان خطأً
-- صريحاً: هي لا تحجب اتصالاً آخر، لكنها تُبقي معاملةً مفتوحة تحمل أقفالاً.
--
-- **الحل:** إجراء (procedure) لا دالة. الإجراء وحده يستطيع `commit` في
-- منتصفه، فينتهي القفل مع كل نبضة بدل أن يمتدّ دقيقة.
-- =============================================================================

-- الدالة القديمة تُحذف: لا يجوز بقاء نسخة تُستدعى سهواً.
drop function if exists public.dispatch_minute();

create or replace procedure public.dispatch_minute()
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  i integer;
begin
  for i in 1..12 loop
    perform public.dispatch_tick();

    -- **هنا الإصلاح.** الإفلات من المعاملة يُطلق كل أقفال هذه النبضة،
    -- فيجد الراكبُ رحلته حرّةً ليلغيها والسائقُ ليقبلها.
    commit;

    if i < 12 then perform pg_sleep(5); end if;
  end loop;
end;
$fn$;

-- pg_cron ينفّذ نصاً حرفياً، و`call` هي ما يسمح للإجراء بأن يعمل خارج
-- معاملة محيطة — و`select` لا تفعل. تغيير الجدولة جزء من الإصلاح لا
-- تفصيل شكلي.
select cron.unschedule('zanbour-dispatch')
where exists (select 1 from cron.job where jobname = 'zanbour-dispatch');

select cron.schedule(
  'zanbour-dispatch',
  '* * * * *',
  $cron$ call public.dispatch_minute(); $cron$
);


-- -----------------------------------------------------------------------------
-- ٢) رسائل القبول تقول الحقيقة
-- -----------------------------------------------------------------------------
-- كانت كل حالة ليست `searching` تُترجم إلى "سبقك سائق آخر". فالرحلة التي
-- ألغاها الراكب، والتي استسلم البحث فيها بعد عشر دقائق، تُنسَبان إلى سائق
-- وهمي لم يوجد. السائق يظن أن المنافسة شرسة وأنه بطيء، والحقيقة غير ذلك.
create or replace function public.accept_trip_offer(p_offer_id uuid)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
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

    raise exception '%', case v_trip.status
      when 'cancelled'  then 'ألغى الراكب هذا الطلب'
      when 'no_drivers' then 'انتهت مدة البحث وأُغلق هذا الطلب'
      else 'سبقك سائق آخر لهذه الرحلة'
    end;
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
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) السائق لا يرى صورة الراكب — بقرار من المستخدم
-- -----------------------------------------------------------------------------
-- **نحجبها في العرض لا في الشاشة.** حذفُها من واجهة التطبيق يترك الصورة
-- تُرسَل إلى الجهاز ثم لا تُعرض — فمن يفتح استجابة الشبكة يراها. الحجب
-- هنا يعني أنها لا تغادر الخادم أصلاً.
--
-- الراكب يرى صورة سائقه: يركب خلف رجل لا يعرفه ويحتاج أن يتأكد أنه هو.
-- والسائق لا يحتاج مثل ذلك — يكفيه الاسم والهاتف.
drop view if exists public.trip_party_info;

create view public.trip_party_info
with (security_barrier = true)
as
select
  t.id   as trip_id,
  p.id   as person_id,
  case when p.id = t.driver_id then 'driver' else 'rider' end as party,

  p.full_name,

  -- صورة السائق فقط. صف الراكب يحمل null دائماً.
  case when p.id = t.driver_id then p.avatar_url else null end as avatar_url,

  -- الهاتف يُكشف أثناء الرحلة النشطة فقط. بعد انتهائها لا يبقى سبب
  -- لبقاء رقم الراكب في يد السائق.
  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end as phone,

  d.rating_avg,
  d.vehicle_type,
  d.vehicle_plate,
  d.vehicle_make,
  d.vehicle_model,
  d.vehicle_color

from public.trips t
join public.profiles p
  on p.id = t.rider_id or p.id = t.driver_id
left join public.drivers d on d.id = p.id
-- الفلتر الأمني: لا تُرجع إلا رحلات المستدعي نفسه
where t.rider_id = auth.uid() or t.driver_id = auth.uid();

comment on view public.trip_party_info is
  'الحقول الآمنة فقط عن طرفي الرحلة. صورة السائق دون الراكب، ولا يكشف '
  'رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;


-- سياسة التخزين تُضيَّق معها: الراكب يقرأ صورة سائقه، والسائق لا يقرأ
-- صورة راكبه. بلا هذا يبقى الملف نفسه قابلاً للتوقيع من طرف السائق.
drop policy if exists "documents: صورة الطرف الآخر أثناء الرحلة" on storage.objects;
create policy "documents: الراكب يرى صورة سائقه"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documents'
    and name like '%/live_selfie_%'
    and exists (
      select 1 from public.trips t
      where t.status in ('accepted', 'driver_arrived', 'in_progress')
        and t.rider_id = auth.uid()
        and t.driver_id::text = (storage.foldername(name))[1]
    )
  );


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  j.jobname   as "المهمة",
  j.schedule  as "الجدولة",
  j.command   as "الأمر"
from cron.job j
where j.jobname = 'zanbour-dispatch';


-- ##########################################################################
-- ملف: 0022_topup_payout_ratings.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0022 — رموز التعبئة، وطلبات السحب، والتقييم المتبادل
-- =============================================================================
-- الدفع نقدي، فالسائق يقبض الأجرة كاملةً بيده ونقيّد حصة المنصة ديناً
-- عليه. هذا الملف يبني الطريقين اللذين يسدّد بهما ذلك الدين ويقبض بهما
-- ما يفيض له:
--
--   ١) **رمز تعبئة** من ست عشرة خانة — نبيعه للسائق ويدخله في التطبيق.
--   ٢) **طلب سحب** حين يصير رصيده موجباً وكبيراً — ندفعه له زين كاش.
--
-- وأُضيف التقييم المتبادل: كان الراكب وحده يقيّم. السائق يستحق أن يعرف
-- من يركب خلفه، ويستحق الراكب أن يُعرف بحسن تعامله.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) حدّ الدين: من ٢٥٬٠٠٠ إلى ٣٬٠٠٠
-- -----------------------------------------------------------------------------
-- **لماذا خفضٌ بهذا الحجم؟** خمسة وعشرون ألفاً تعني أن سائقاً قد يجمع دين
-- سبع عشرة رحلة قبل أن يُوقفه النظام. مع الدفع النقدي هذا مبلغ حقيقي في
-- جيبه لا في حسابنا، وكلما كبر صعب تحصيله. ثلاثة آلاف = رحلتان تقريباً،
-- فيسدّد باستمرار ولا يتراكم عليه ما يعجزه.
alter table public.pricing_zones
  alter column min_wallet_balance_iqd set default -3000;

update public.pricing_zones
set min_wallet_balance_iqd = -3000
where min_wallet_balance_iqd = -25000;


-- -----------------------------------------------------------------------------
-- ٢) رموز التعبئة
-- -----------------------------------------------------------------------------
-- **لماذا الرمز في جدول مستقل لا عمود في السائق؟** لأنه يُولَّد قبل أن
-- نعرف من سيستعمله. ندير المخزون كما تُدار بطاقات الشحن: نولّد دفعةً،
-- ونرسلها، ونعرف أيها استُهلك ومتى ومن استهلكه.
create table if not exists public.topup_codes (
  id           uuid primary key default gen_random_uuid(),

  -- ست عشرة خانة رقمية بلا فواصل. نخزّنه نصاً لا رقماً: الأصفار البادئة
  -- جزء من الرمز، والرقم يبتلعها.
  code         text not null unique
                 check (code ~ '^[0-9]{16}$'),

  amount_iqd   numeric(12,2) not null check (amount_iqd > 0),

  -- من ولّده ومتى — للتدقيق حين يختلف سائق على رمز
  created_by   uuid references public.profiles(id),
  created_at   timestamptz not null default now(),
  batch_note   text,

  -- من استهلكه ومتى. فارغان = ما زال صالحاً.
  redeemed_by  uuid references public.drivers(id) on delete set null,
  redeemed_at  timestamptz,

  -- إبطال يدوي لرمز ضاع أو أُرسل خطأً
  is_void      boolean not null default false
);

create index if not exists topup_codes_unused_idx
  on public.topup_codes (created_at desc)
  where redeemed_by is null and not is_void;

comment on table public.topup_codes is
  'رموز تعبئة رصيد السائقين. تُولَّد من لوحة التحكم وتُستهلك مرة واحدة.';


-- -----------------------------------------------------------------------------
-- ٣) توليد دفعة رموز — للمشرف وحده
-- -----------------------------------------------------------------------------
create or replace function public.generate_topup_codes(
  p_count  integer,
  p_amount numeric,
  p_note   text default null
)
returns setof public.topup_codes
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  i     integer;
  v_code text;
  v_row public.topup_codes;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  if p_count < 1 or p_count > 200 then
    raise exception 'العدد بين ١ و٢٠٠ في الدفعة الواحدة';
  end if;

  if p_amount <= 0 then
    raise exception 'قيمة الرمز يجب أن تكون أكبر من صفر';
  end if;

  for i in 1..p_count loop
    -- ست عشرة خانة عشوائية. `gen_random_bytes` مصدر تعمية حقيقي لا
    -- `random()` — رمزٌ يُخمَّن هو مالٌ يُسرَق.
    --
    -- الحلقة تعالج التصادم النادر بدل أن تُسقط الدفعة كلها.
    loop
      select string_agg((get_byte(gen_random_bytes(1), 0) % 10)::text, '')
      into v_code
      from generate_series(1, 16);

      exit when not exists (
        select 1 from public.topup_codes where code = v_code
      );
    end loop;

    insert into public.topup_codes (code, amount_iqd, created_by, batch_note)
    values (v_code, p_amount, auth.uid(), p_note)
    returning * into v_row;

    return next v_row;
  end loop;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) استهلاك الرمز — يستدعيه السائق من تطبيقه
-- -----------------------------------------------------------------------------
-- **الدين يُسدَّد أولاً تلقائياً.** سائق عليه ٢٠٠٠ يعبّئ ٥٠٠٠ فيصير رصيده
-- ٣٠٠٠ موجباً. لا نحتاج منطقاً خاصاً لذلك: المحفظة رقم واحد بإشارة،
-- والإضافة تفعلها الحسبة نفسها. نذكرها هنا لأنها سؤال يتكرر.
create or replace function public.redeem_topup_code(p_code text)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_code    public.topup_codes;
  v_balance numeric(12,2);
begin
  if not exists (select 1 from public.drivers where id = auth.uid()) then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  -- تنظيف ما قد يكتبه السائق من مسافات أو شَرَطات
  p_code := regexp_replace(coalesce(p_code, ''), '[^0-9]', '', 'g');

  if p_code !~ '^[0-9]{16}$' then
    raise exception 'الرمز يجب أن يكون ١٦ رقماً';
  end if;

  -- القفل يمنع استهلاك الرمز مرتين من جهازين في اللحظة نفسها
  select * into v_code from public.topup_codes
  where code = p_code
  for update;

  if not found then
    raise exception 'رمز غير صحيح';
  end if;

  if v_code.is_void then
    raise exception 'هذا الرمز مُلغى';
  end if;

  if v_code.redeemed_by is not null then
    raise exception 'هذا الرمز مستعمل من قبل';
  end if;

  update public.topup_codes
  set redeemed_by = auth.uid(), redeemed_at = now()
  where id = v_code.id;

  perform public.post_wallet_transaction(
    p_driver_id   => auth.uid(),
    p_txn_type    => 'topup',
    p_amount_iqd  => v_code.amount_iqd,
    p_description => 'تعبئة برمز'
  );

  select wallet_balance_iqd into v_balance
  from public.drivers where id = auth.uid();

  return v_balance;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) طلبات السحب
-- -----------------------------------------------------------------------------
-- النوع يُنشأ مرة واحدة. `create type` لا يقبل `if not exists`، والملف
-- يجب أن يبقى آمناً للتكرار.
do $do$
begin
  if not exists (select 1 from pg_type where typname = 'payout_status') then
    create type public.payout_status as enum ('pending', 'paid', 'rejected');
  end if;
end
$do$;

create table if not exists public.payout_requests (
  id           uuid primary key default gen_random_uuid(),
  driver_id    uuid not null references public.drivers(id) on delete cascade,

  amount_iqd   numeric(12,2) not null check (amount_iqd > 0),
  status       public.payout_status not null default 'pending',

  -- رقم زين كاش. نلتقطه وقت الطلب لا وقت الدفع: قد يتغيّر هاتف السائق
  -- بين الأمرين، والمبلغ يجب أن يذهب إلى الرقم الذي طلب به.
  zain_phone   text not null,

  requested_at timestamptz not null default now(),
  processed_at timestamptz,
  processed_by uuid references public.profiles(id),
  admin_note   text
);

create index if not exists payout_requests_pending_idx
  on public.payout_requests (requested_at)
  where status = 'pending';

create index if not exists payout_requests_driver_idx
  on public.payout_requests (driver_id, requested_at desc);


-- الحد الأدنى للسحب. **فوق الخمسة آلاف** — أي أن خمسة آلاف بالضبط لا
-- تُسحب. رسوم التحويل وعناء المتابعة اليدوية لا يستحقّان مبلغاً أصغر.
create or replace function public.min_payout_iqd()
returns numeric language sql immutable as $fn$ select 5000::numeric $fn$;


create or replace function public.request_payout(p_amount numeric)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_balance numeric(12,2);
  v_phone   text;
  v_row     public.payout_requests;
begin
  select d.wallet_balance_iqd, p.phone
  into v_balance, v_phone
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.id = auth.uid()
  for update of d;

  if not found then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= public.min_payout_iqd() then
    raise exception 'أقل مبلغ للسحب أكثر من % دينار',
      public.min_payout_iqd()::bigint;
  end if;

  -- **نطرح الطلبات المعلّقة من الرصيد المتاح.** بدون ذلك يطلب السائق
  -- سحب رصيده مرتين قبل أن ندفع له الأولى.
  if p_amount > v_balance - coalesce((
       select sum(amount_iqd) from public.payout_requests
       where driver_id = auth.uid() and status = 'pending'
     ), 0)
  then
    raise exception 'المبلغ أكبر من رصيدك المتاح';
  end if;

  if v_phone is null or v_phone = '' then
    raise exception 'لا يوجد رقم هاتف في حسابك';
  end if;

  insert into public.payout_requests (driver_id, amount_iqd, zain_phone)
  values (auth.uid(), p_amount, v_phone)
  returning * into v_row;

  return v_row;
end;
$fn$;


-- السائق يسحب طلبه ما دام معلّقاً
create or replace function public.cancel_payout_request(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  delete from public.payout_requests
  where id = p_id and driver_id = auth.uid() and status = 'pending';

  if not found then
    raise exception 'الطلب غير موجود أو عُولج بالفعل';
  end if;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) المشرف يعلن الدفع
-- -----------------------------------------------------------------------------
-- **الخصم يحدث هنا لا وقت الطلب.** الطلب نيّة، والدفع فعل. لو خصمنا وقت
-- الطلب لصار رصيد السائق ناقصاً وهو لم يقبض بعد، ولو رفضنا الطلب لوجب
-- ردّ المبلغ — عملية إضافية تخطئ.
create or replace function public.mark_payout_paid(p_id uuid, p_note text default null)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests where id = p_id for update;
  if not found then
    raise exception 'الطلب غير موجود';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'هذا الطلب مُعالج بالفعل';
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'payout',
    p_amount_iqd  => -v_row.amount_iqd,
    p_description => 'سحب إلى زين كاش',
    p_created_by  => auth.uid()
  );

  update public.payout_requests
  set status = 'paid', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;


create or replace function public.reject_payout_request(p_id uuid, p_note text)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  update public.payout_requests
  set status = 'rejected', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id and status = 'pending'
  returning * into v_row;

  if not found then
    raise exception 'الطلب غير موجود أو مُعالج بالفعل';
  end if;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) التقييم المتبادل
-- -----------------------------------------------------------------------------
-- الراكب له تقييم كذلك. نضعه في `profiles` لا في جدول جديد: هو صفة
-- شخص لا كيان مستقل، والسائق يقرؤه من العرض `trip_party_info`.
alter table public.profiles
  add column if not exists rating_avg   numeric(3,2) not null default 5.00,
  add column if not exists rating_count integer      not null default 0;

-- المُشغّل القديم كان يحدّث `drivers` وحدها. صار يوجّه التقييم إلى الطرف
-- الصحيح: تقييم السائق إلى سجل السائق، وتقييم الراكب إلى ملفه.
create or replace function public.apply_driver_rating()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  -- نرفع علم تجاوز الحُرّاس: هذا تعديل نظامي موثوق، لا من المستخدم.
  perform set_config('app.bypass_guards', 'on', true);

  if exists (select 1 from public.drivers where id = new.ratee_id) then
    update public.drivers
    set rating_avg = round(
          ((rating_avg * rating_count) + new.stars)::numeric / (rating_count + 1),
          2
        ),
        rating_count = rating_count + 1
    where id = new.ratee_id;
  end if;

  -- ملف الشخص يُحدَّث في الحالتين: السائق شخص أيضاً، وتقييمه في ملفه
  -- يجعل مصدراً واحداً يكفي أي شاشة لا تعرف دور من تعرضه.
  update public.profiles
  set rating_avg = round(
        ((rating_avg * rating_count) + new.stars)::numeric / (rating_count + 1),
        2
      ),
      rating_count = rating_count + 1
  where id = new.ratee_id;

  perform set_config('app.bypass_guards', 'off', true);

  return new;
end;
$fn$;

-- نملأ تقييمات الملفات من التقييمات القائمة (كانت تذهب إلى `drivers` فقط)
update public.profiles p
set rating_avg   = coalesce(r.avg_stars, 5.00),
    rating_count = coalesce(r.n, 0)
from (
  select ratee_id, round(avg(stars)::numeric, 2) as avg_stars, count(*) as n
  from public.ratings group by ratee_id
) r
where r.ratee_id = p.id;


-- -----------------------------------------------------------------------------
-- ٨) العرض يكشف تقييم الراكب أيضاً
-- -----------------------------------------------------------------------------
drop view if exists public.trip_party_info;

create view public.trip_party_info
with (security_barrier = true)
as
select
  t.id   as trip_id,
  p.id   as person_id,
  case when p.id = t.driver_id then 'driver' else 'rider' end as party,

  p.full_name,

  -- صورة السائق فقط. صف الراكب يحمل null دائماً.
  case when p.id = t.driver_id then p.avatar_url else null end as avatar_url,

  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end as phone,

  -- من الملف لا من سجل السائق: يعمل للطرفين بمصدر واحد.
  p.rating_avg,
  p.rating_count,

  d.vehicle_type,
  d.vehicle_plate,
  d.vehicle_make,
  d.vehicle_model,
  d.vehicle_color

from public.trips t
join public.profiles p
  on p.id = t.rider_id or p.id = t.driver_id
left join public.drivers d on d.id = p.id
where t.rider_id = auth.uid() or t.driver_id = auth.uid();

comment on view public.trip_party_info is
  'الحقول الآمنة فقط عن طرفي الرحلة. صورة السائق دون الراكب، ولا يكشف '
  'رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;


-- -----------------------------------------------------------------------------
-- ٩) تقييماتي — بلا هويات
-- -----------------------------------------------------------------------------
-- **لماذا دالة لا سياسة قراءة على `ratings`؟** لأن سياسة SELECT تمنح
-- الصف كاملاً بأعمدته، ومنها `rater_id`. فيعرف السائق **من** أعطاه نجمة
-- واحدة — وذلك يفتح باب الانتقام ويجعل الراكب يخشى الصدق.
--
-- هذه تعيد النجوم والتعليق والتاريخ فقط. من قيّم يبقى مجهولاً أبداً.
create or replace function public.my_ratings(p_limit integer default 50)
returns table (
  stars      smallint,
  comment    text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select r.stars, r.comment, r.created_at
  from public.ratings r
  where r.ratee_id = auth.uid()
  order by r.created_at desc
  limit least(coalesce(p_limit, 50), 200);
$fn$;


-- -----------------------------------------------------------------------------
-- ١٠) سياسات الأمان والصلاحيات
-- -----------------------------------------------------------------------------
alter table public.topup_codes     enable row level security;
alter table public.payout_requests enable row level security;

-- الرموز: لا أحد يقرأ الجدول من التطبيق. المشرف يقرؤه بدالة `is_admin`.
--
-- **لماذا لا نسمح للسائق بقراءة رمزه بعد استهلاكه؟** لأن سياسة القراءة
-- تحتاج مطابقة الرمز، والمطابقة تعني القدرة على التخمين صفاً بصف.
drop policy if exists "topup_codes: للمشرف وحده" on public.topup_codes;
create policy "topup_codes: للمشرف وحده"
  on public.topup_codes for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "payouts: السائق يقرأ طلباته" on public.payout_requests;
create policy "payouts: السائق يقرأ طلباته"
  on public.payout_requests for select
  using (driver_id = auth.uid() or public.is_admin());

drop policy if exists "payouts: صلاحية كاملة للمشرف" on public.payout_requests;
create policy "payouts: صلاحية كاملة للمشرف"
  on public.payout_requests for all
  using (public.is_admin()) with check (public.is_admin());

-- الإدراج والحذف يمرّان بالدوال وحدها — لا سياسة للسائق عليهما.

revoke all on function public.generate_topup_codes    from public, anon;
revoke all on function public.redeem_topup_code       from public, anon;
revoke all on function public.request_payout          from public, anon;
revoke all on function public.cancel_payout_request   from public, anon;
revoke all on function public.mark_payout_paid        from public, anon;
revoke all on function public.reject_payout_request   from public, anon;
revoke all on function public.my_ratings              from public, anon;

grant execute on function public.generate_topup_codes(integer, numeric, text)
  to authenticated;
grant execute on function public.redeem_topup_code(text)        to authenticated;
grant execute on function public.request_payout(numeric)        to authenticated;
grant execute on function public.cancel_payout_request(uuid)    to authenticated;
grant execute on function public.mark_payout_paid(uuid, text)   to authenticated;
grant execute on function public.reject_payout_request(uuid, text) to authenticated;
grant execute on function public.my_ratings(integer)            to authenticated;
grant execute on function public.min_payout_iqd()               to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  (select min_wallet_balance_iqd from public.pricing_zones limit 1)
    as "حدّ الدين",
  public.min_payout_iqd()          as "أقل سحب (أكثر من)",
  (select count(*) from public.topup_codes)     as "رموز مولّدة",
  (select count(*) from public.payout_requests) as "طلبات سحب";


-- ##########################################################################
-- ملف: 0023_payout_reserve.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0023 — رصيد محجوز لا يُسحب
-- =============================================================================
-- **القاعدة السابقة كانت تحرس الرقم الخطأ.** كتبنا في 0022 أن مبلغ السحب
-- يجب أن يتجاوز خمسة آلاف، فحرسنا **حجم السحبة** لا **ما يبقى بعدها**.
-- والنتيجة أن سائقاً رصيده ٢٠٬٠٠٠ يسحبها كلها ويصفّر حسابه في لحظة.
--
-- **لماذا يهمّنا أن يبقى شيء؟** لأن العمولة تُقيَّد ديناً بعد كل رحلة،
-- والسائق الذي صفّر رصيده يبدأ الرحلة التالية من الصفر فيصير مديناً
-- فوراً، ويبلغ حدّ الدين (٣٬٠٠٠) بعد رحلتين فيتوقف عن العمل. الرصيد
-- المحجوز وسادةٌ تُبقيه يعمل بلا انقطاع.
--
-- الجديد: **يُحجز خمسة آلاف دائماً، ويُسحب ما فوقها.** سائق رصيده ٧٬٥٠٠
-- يسحب ٢٬٥٠٠ لا أكثر.
--
-- ولاحظ أن الشرط انقلب: لم نعد نمنع السحبة الصغيرة — سائق رصيده ٥٬٦٠٠
-- يسحب ٦٠٠ وهو حقّه، والقاعدة القديمة كانت تمنعه لأن ٦٠٠ أقل من ٥٬٠٠٠.
-- =============================================================================

-- الاسم يقول الآن ما تعنيه الدالة فعلاً: رصيد محجوز، لا حدّ أدنى لسحبة.
drop function if exists public.min_payout_iqd();

create or replace function public.payout_reserve_iqd()
returns numeric language sql immutable as $fn$ select 5000::numeric $fn$;

comment on function public.payout_reserve_iqd is
  'ما يجب أن يبقى في محفظة السائق بعد أي سحب.';


create or replace function public.request_payout(p_amount numeric)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_balance   numeric(12,2);
  v_pending   numeric(12,2);
  v_available numeric(12,2);
  v_phone     text;
  v_row       public.payout_requests;
begin
  select d.wallet_balance_iqd, p.phone
  into v_balance, v_phone
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.id = auth.uid()
  for update of d;

  if not found then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'أدخل مبلغاً صحيحاً';
  end if;

  -- الطلبات المعلّقة محجوزة هي الأخرى: بدون طرحها يطلب السائق سحب
  -- رصيده مرتين قبل أن ندفع له الأولى.
  select coalesce(sum(amount_iqd), 0) into v_pending
  from public.payout_requests
  where driver_id = auth.uid() and status = 'pending';

  v_available := v_balance - v_pending - public.payout_reserve_iqd();

  if v_available <= 0 then
    raise exception 'يجب أن يبقى % دينار في رصيدك. لا يوجد مبلغ متاح للسحب',
      public.payout_reserve_iqd()::bigint;
  end if;

  if p_amount > v_available then
    raise exception 'أقصى ما يمكن سحبه الآن % دينار — يجب أن يبقى % في رصيدك',
      v_available::bigint, public.payout_reserve_iqd()::bigint;
  end if;

  if v_phone is null or v_phone = '' then
    raise exception 'لا يوجد رقم هاتف في حسابك';
  end if;

  insert into public.payout_requests (driver_id, amount_iqd, zain_phone)
  values (auth.uid(), p_amount, v_phone)
  returning * into v_row;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- حارس ثانٍ عند الدفع
-- -----------------------------------------------------------------------------
-- **لماذا نفحص مرتين؟** لأن بين الطلب والدفع وقتاً قد تتغيّر فيه المحفظة:
-- عمولات رحلات جديدة تنقصها. الطلب صحيح يوم كُتب وقد يصير خاطئاً يوم
-- يُدفع، فيصفّر الدفعُ رصيداً لم يعد يحتمل.
create or replace function public.mark_payout_paid(p_id uuid, p_note text default null)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row     public.payout_requests;
  v_balance numeric(12,2);
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests where id = p_id for update;
  if not found then
    raise exception 'الطلب غير موجود';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'هذا الطلب مُعالج بالفعل';
  end if;

  select wallet_balance_iqd into v_balance
  from public.drivers where id = v_row.driver_id;

  if v_balance - v_row.amount_iqd < public.payout_reserve_iqd() then
    raise exception
      'رصيد السائق تغيّر منذ الطلب: % دينار. الدفع يُبقي أقل من % المطلوب حجزها',
      v_balance::bigint, public.payout_reserve_iqd()::bigint;
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'payout',
    p_amount_iqd  => -v_row.amount_iqd,
    p_description => 'سحب إلى زين كاش',
    p_created_by  => auth.uid()
  );

  update public.payout_requests
  set status = 'paid', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;


revoke all on function public.request_payout   from public, anon;
revoke all on function public.mark_payout_paid from public, anon;
grant execute on function public.request_payout(numeric)      to authenticated;
grant execute on function public.mark_payout_paid(uuid, text) to authenticated;
grant execute on function public.payout_reserve_iqd()         to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select public.payout_reserve_iqd() as "الرصيد المحجوز";


-- ##########################################################################
-- ملف: 0024_cancel_policy_and_geofence.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0024 — سياسة الإلغاء الجديدة، وحارس المسافة على تقدّم الرحلة
-- =============================================================================
-- ثلاثة تغييرات تخدم غرضاً واحداً: أن يكون ما يراه التطبيق مطابقاً لما
-- يحدث في الشارع.
--
--   ١) **الراكب يلغي بلا عواقب.** كنا نفرض عليه ٥٠٠ دينار إن ألغى بعد
--      مهلة السماح. المستخدم قرّر رفع ذلك: راكبٌ يخاف زر الإلغاء يترك
--      الطلب معلّقاً بدل إلغائه، فيضيع وقت السائق كاملاً بدل دقيقتين.
--
--   ٢) **السائق يلغي بعد القبول: مرّتان مجاناً كل يوم، ثم ٥٠٠ دينار.**
--      الإلغاء بعد القبول يترك الراكب واقفاً في الشارع وقد انتظر بالفعل،
--      وهو أسوأ من ألا يجد سائقاً أصلاً. لكن المنع التام قاسٍ: قد تُثقب
--      إطاراته أو يمرض. مرّتان مجاناً تحتملان العذر، والثالثة تكلّف.
--
--      **العدّاد يُصفَّر منتصف كل ليلة بتوقيت بغداد** لا بتوقيت الخادم
--      (وهو UTC). فرقٌ ثلاث ساعات يعني أن سائقاً يلغي في الحادية عشرة
--      ليلاً كان سيُحسب عليه في يوم الغد.
--
--   ٣) **حارس المسافة.** "وصلت" و"بدأت الرحلة" صارتا تشترطان أن يكون
--      السائق قريباً فعلاً من نقطة الانطلاق. بلا ذلك يضغط الأزرار وهو
--      في بيته، فيرى الراكب "وصل سائقك" ولا أحد عند الباب.
--
--      **الفحص في القاعدة لا في التطبيق:** ما يُفحص على الهاتف يُتجاوز
--      بتطبيق معدَّل. والقاعدة تعرف موقع السائق أصلاً — يرسله كل خمس
--      ثوانٍ.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) ضوابط جديدة في المنطقة
-- -----------------------------------------------------------------------------
alter table public.pricing_zones
  add column if not exists driver_free_cancels_per_day smallint not null default 2,
  add column if not exists driver_cancel_penalty_iqd   numeric(10,2) not null default 500,
  add column if not exists arrival_radius_m            integer not null default 200;

comment on column public.pricing_zones.driver_free_cancels_per_day is
  'كم إلغاءً بعد القبول يُسمح به مجاناً في اليوم الواحد (توقيت بغداد).';

comment on column public.pricing_zones.driver_cancel_penalty_iqd is
  'ما يُخصم من السائق عند تجاوز الإلغاءات المجانية.';

comment on column public.pricing_zones.arrival_radius_m is
  'كم متراً يُعدّ السائق فيها "وصل" إلى نقطة الانطلاق. ٢٠٠ متر تحتمل '
  'انحراف GPS في المدينة دون أن تسمح بالضغط من البيت.';

-- الراكب لا يدفع شيئاً بعد اليوم. نُبقي العمود لأن الرحلات القديمة
-- سجّلت فيه رسوماً فعلية، ومحوها يفسد كشوف الحساب.
update public.pricing_zones set cancellation_fee_iqd = 0;


-- -----------------------------------------------------------------------------
-- ٢) كم بقي للسائق من إلغاءات مجانية اليوم
-- -----------------------------------------------------------------------------
-- يستدعيها التطبيق ليُري السائق العاقبة **قبل** أن يضغط، لا بعدها.
create or replace function public.my_cancels_today()
returns table (
  used      integer,
  free      integer,
  penalty   numeric
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select
    (select count(*)::integer
     from public.trips t
     where t.driver_id = auth.uid()
       and t.cancelled_by = auth.uid()
       and t.cancelled_at is not null
       and timezone('Asia/Baghdad', t.cancelled_at)::date
           = timezone('Asia/Baghdad', now())::date),
    coalesce((select min(driver_free_cancels_per_day)::integer
              from public.pricing_zones where is_active), 2),
    coalesce((select min(driver_cancel_penalty_iqd)
              from public.pricing_zones where is_active), 500);
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الإلغاء: الراكب مجاناً، والسائق بعد مرّتين
-- -----------------------------------------------------------------------------
create or replace function public.cancel_trip(
  p_trip_id uuid,
  p_reason  text default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip     public.trips;
  v_zone     public.pricing_zones;
  v_is_rider boolean;
  v_fee      numeric(10,2) := 0;   -- ما يُخصم من السائق عقوبةً
  v_used     integer := 0;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'الرحلة غير موجودة';
  end if;

  v_is_rider := (v_trip.rider_id = auth.uid());

  if not v_is_rider and v_trip.driver_id is distinct from auth.uid() then
    raise exception 'لا تملك صلاحية إلغاء هذه الرحلة'
      using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status in ('completed', 'cancelled') then
    raise exception 'الرحلة منتهية بالفعل';
  end if;

  -- **السائق لا يلغي رحلة بدأت فعلاً.** الراكب على الدراجة حينها،
  -- وتركه في منتصف الطريق ليس إلغاءً بل هجراً.
  if not v_is_rider and v_trip.status = 'in_progress' then
    raise exception 'لا يمكن إلغاء رحلة بدأت. أنهِها من زر الإنهاء';
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  -- ---- عقوبة إلغاء السائق ----
  --
  -- تُحسب على الإلغاء **بعد القبول** وحده: رفض العرض قبل القبول حقٌّ
  -- كامل لا عقوبة فيه، وهو ما يبني عليه محرك المطابقة أصلاً.
  if not v_is_rider and v_trip.status in ('accepted', 'driver_arrived') then
    select count(*) into v_used
    from public.trips t
    where t.driver_id = auth.uid()
      and t.cancelled_by = auth.uid()
      and t.cancelled_at is not null
      and timezone('Asia/Baghdad', t.cancelled_at)::date
          = timezone('Asia/Baghdad', now())::date;

    if v_used >= coalesce(v_zone.driver_free_cancels_per_day, 2) then
      v_fee := coalesce(v_zone.driver_cancel_penalty_iqd, 500);
    end if;
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
        trips_cancelled = trips_cancelled
          + case when not v_is_rider then 1 else 0 end
    where id = v_trip.driver_id;

    -- **الخصم على السائق لا التعويض له.** كان هذا السطر يمنحه رسوم
    -- إلغاء الراكب؛ صار يخصم عقوبة إلغائه هو. الإشارة سالبة.
    if v_fee > 0 then
      perform public.post_wallet_transaction(
        p_driver_id   => v_trip.driver_id,
        p_txn_type    => 'cancellation_fee',
        p_amount_iqd  => -v_fee,
        p_trip_id     => v_trip.id,
        p_description => format('عقوبة إلغاء الرحلة رقم %s', v_trip.trip_number)
      );
    end if;
  end if;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) حارس المسافة على "وصلت" و"بدأت الرحلة"
-- -----------------------------------------------------------------------------
create or replace function public.advance_trip(
  p_trip_id uuid,
  p_to      public.trip_status
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip     public.trips;
  v_zone     public.pricing_zones;
  v_loc      geography;
  v_loc_age  integer;
  v_distance integer;
  v_radius   integer;
begin
  if p_to not in ('driver_arrived', 'in_progress') then
    raise exception 'استخدم complete_trip أو cancel_trip لهذه الحالة';
  end if;

  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك'
      using errcode = 'insufficient_privilege';
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  v_radius := coalesce(v_zone.arrival_radius_m, 200);

  select d.current_location,
         round(extract(epoch from (now() - d.location_updated_at)))::integer
  into v_loc, v_loc_age
  from public.drivers d where d.id = auth.uid();

  -- **موقع قديم يُرفض كما يُرفض غيابه.** موقع عمره خمس دقائق قد يكون
  -- بيت السائق لا موقعه الآن، وقبوله يفتح الباب لما جئنا نغلقه.
  if v_loc is null or v_loc_age is null or v_loc_age > 120 then
    raise exception
      'تعذّر تحديد موقعك. تأكد أن خدمة الموقع تعمل ثم أعد المحاولة';
  end if;

  v_distance := st_distance(v_loc, v_trip.pickup_location)::integer;

  if v_distance > v_radius then
    raise exception 'أنت على بعد % متر من نقطة الانطلاق. اقترب إلى أقل من % متر',
      v_distance, v_radius;
  end if;

  -- المُشغّل enforce_trip_transition يرفض الانتقالات غير المنطقية
  update public.trips set status = p_to where id = p_trip_id
  returning * into v_trip;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.my_cancels_today from public, anon;
grant execute on function public.my_cancels_today() to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar                as "المنطقة",
  cancellation_fee_iqd        as "رسوم إلغاء الراكب",
  driver_free_cancels_per_day as "إلغاءات السائق المجانية",
  driver_cancel_penalty_iqd   as "عقوبة السائق",
  arrival_radius_m            as "نطاق الوصول (م)"
from public.pricing_zones
order by city_name_ar
limit 5;


-- ##########################################################################
-- ملف: 0025_lower_pricing.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0025 — خفض سعر الكيلومتر: ٣٥٠ ← ٢٥٠
-- =============================================================================
-- **الملاحظة التي دفعت التغيير:** الدراجة كانت أغلى من سيارة الأجرة. وهذا
-- ينقض سبب وجود المنتج أصلاً — الناس تختار الدراجة لأنها أسرع في الزحام
-- **وأرخص**. فقدُ الميزة الثانية يترك الأولى وحدها، ولا تكفي.
--
--   قبل:  500 + (كم × 350)   حد أدنى 1000
--   بعد:  500 + (كم × 250)   حد أدنى 1000
--
-- **لماذا الكيلومتر لا أجرة البداية؟** لأن أثره يتضاعف مع الطول. أجرة
-- البداية تضيف ٥٠٠ مرة واحدة مهما بعدت الوجهة، أما سعر الكيلومتر فيضرب
-- في المسافة كلها — وهناك كان الفارق يتضخّم أمام سيارة الأجرة.
--
-- **ولماذا بقي الحد الأدنى ١٠٠٠؟** أقل من ذلك لا يغطي وقت السائق ووقوده
-- ومجيئه إلى الراكب. وسائق يرى رحلة بـ٧٥٠ يرفضها، فلا يجد الراكب أحداً —
-- وحدٌّ أدنى منخفض بلا سائقين أسوأ من حدٍّ عادل.
--
-- السلّم الناتج (بعد التقريب لأقرب ٢٥٠):
--   ١.٥كم = 1000 · ٣كم = 1250 · ٥كم = 1750 · ٨كم = 2500 · ٢٠كم = 5500
--
-- حصة السائق من رحلة ٥ كم بعد عمولة ١٥٪: ١٤٨٧ ديناراً.
--
-- **لا يحتاج هذا تعديل كود ولا إعادة بناء التطبيقات.** التسعير بيانات في
-- `pricing_zones` لا ثوابت في الدوال، وهو قرار من اليوم الأول يسدّد
-- نفسه اليوم: تغيير سعر السوق كله سطر `update` واحد.
-- =============================================================================

update public.pricing_zones
set per_km_iqd = 250
where is_active;


-- =============================================================================
-- السلّم الناتج — محسوباً بالدالة الحقيقية لا يدوياً
-- =============================================================================
-- نستعمل `calculate_fare` نفسها التي يستعملها التطبيق، فلو غيّرنا المعادلة
-- لاحقاً عكس هذا التقرير التغيير فوراً بدل أن يكذب علينا.
-- =============================================================================
select
  d.km || ' كم'                                              as "المسافة",
  (public.calculate_fare(z.id, (d.km * 1000)::int, 0) ->> 'total')::numeric
                                                             as "الأجرة",
  (public.calculate_fare(z.id, (d.km * 1000)::int, 0) ->> 'commission')::numeric
                                                             as "العمولة",
  (public.calculate_fare(z.id, (d.km * 1000)::int, 0) ->> 'driver_earning')::numeric
                                                             as "للسائق"
from (values (1.5), (3.0), (5.0), (8.0), (12.0), (20.0)) as d(km)
cross join (select id from public.pricing_zones where city_name = 'Nasiriyah') z
order by d.km;


-- ##########################################################################
-- ملف: 0026_payout_hold.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0026 — المبلغ المطلوب سحبه يُحجز فوراً
-- =============================================================================
-- **تصحيح قرار اتخذتُه في 0022 وكان خاطئاً.** كتبتُ حينها أن الخصم يحدث
-- عند إعلان الدفع لا عند الطلب، بحجة أن "الطلب نيّة والدفع فعل".
--
-- والخطأ فيه: السائق الذي طلب سحب ١٠٬٠٠٠ من ٢٠٬٠٠٠ يبقى رصيده ٢٠٬٠٠٠
-- في نظر النظام كله — يعمل به، ويحتسبه ضمن حدّ الدين، وقد ينفقه في
-- عمولات رحلات جديدة. ثم ندفع له العشرة آلاف فيصير رصيده أقل مما يجب،
-- أو سالباً.
--
-- **الصواب: المبلغ يُحجز لحظة الطلب.** يخرج من رصيده العامل ويبقى
-- محجوزاً، فما يراه هو ما يملك فعلاً. وإن أُلغي الطلب أو رُفض عاد إليه
-- كاملاً.
--
-- والفرق ظاهر في كشف الحساب أيضاً، وهذا مقصود: حركة "حجز طلب سحب" يوم
-- الطلب، وحركة "إلغاء طلب سحب" يوم التراجع. السائق يقرأ قصة ماله كاملة
-- بدل أن يجد رقماً تبدّل بلا سبب مكتوب.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) الطلب يحجز
-- -----------------------------------------------------------------------------
create or replace function public.request_payout(p_amount numeric)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_balance   numeric(12,2);
  v_available numeric(12,2);
  v_phone     text;
  v_row       public.payout_requests;
begin
  select d.wallet_balance_iqd, p.phone
  into v_balance, v_phone
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.id = auth.uid()
  for update of d;

  if not found then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'أدخل مبلغاً صحيحاً';
  end if;

  -- **لم نعد نطرح الطلبات المعلّقة هنا.** صارت مخصومة من الرصيد نفسه،
  -- فطرحها ثانيةً يخصمها مرتين. هذا ما يبسّطه الحجز.
  v_available := v_balance - public.payout_reserve_iqd();

  if v_available <= 0 then
    raise exception 'يجب أن يبقى % دينار في رصيدك. لا يوجد مبلغ متاح للسحب',
      public.payout_reserve_iqd()::bigint;
  end if;

  if p_amount > v_available then
    raise exception 'أقصى ما يمكن سحبه الآن % دينار — يجب أن يبقى % في رصيدك',
      v_available::bigint, public.payout_reserve_iqd()::bigint;
  end if;

  if v_phone is null or v_phone = '' then
    raise exception 'لا يوجد رقم هاتف في حسابك';
  end if;

  insert into public.payout_requests (driver_id, amount_iqd, zain_phone)
  values (auth.uid(), p_amount, v_phone)
  returning * into v_row;

  -- الحجز: يخرج من الرصيد العامل فوراً
  perform public.post_wallet_transaction(
    p_driver_id   => auth.uid(),
    p_txn_type    => 'payout',
    p_amount_iqd  => -p_amount,
    p_description => 'حجز طلب سحب'
  );

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الإلغاء يعيد المحجوز
-- -----------------------------------------------------------------------------
create or replace function public.cancel_payout_request(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  select * into v_row from public.payout_requests
  where id = p_id and driver_id = auth.uid() and status = 'pending'
  for update;

  if not found then
    raise exception 'الطلب غير موجود أو عُولج بالفعل';
  end if;

  -- الردّ قبل الحذف: لو انهارت المعاملة بينهما ضاع المال بلا أثر.
  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'adjustment',
    p_amount_iqd  => v_row.amount_iqd,
    p_description => 'إلغاء طلب سحب'
  );

  -- الحذف لا التعليم: طلبٌ ألغاه صاحبه لا يعني المدير، ووجوده في لوحته
  -- ضجيج يُخفي الطلبات التي تنتظره فعلاً.
  delete from public.payout_requests where id = p_id;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الرفض يعيد المحجوز كذلك
-- -----------------------------------------------------------------------------
create or replace function public.reject_payout_request(p_id uuid, p_note text)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests
  where id = p_id and status = 'pending'
  for update;

  if not found then
    raise exception 'الطلب غير موجود أو مُعالج بالفعل';
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'adjustment',
    p_amount_iqd  => v_row.amount_iqd,
    p_description => coalesce(nullif(p_note, ''), 'رُفض طلب السحب')
  );

  update public.payout_requests
  set status = 'rejected', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) الدفع صار تعليماً فقط — المال خرج يوم الطلب
-- -----------------------------------------------------------------------------
create or replace function public.mark_payout_paid(p_id uuid, p_note text default null)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests where id = p_id for update;
  if not found then
    raise exception 'الطلب غير موجود';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'هذا الطلب مُعالج بالفعل';
  end if;

  -- **لا خصم هنا بعد اليوم.** المبلغ خرج من رصيد السائق لحظة طلبه،
  -- والخصم مرتين كان سيأكل ضعف ما طلب. ولهذا سقط أيضاً فحص الرصيد
  -- المحجوز الذي كان هنا: الرصيد فُحص يوم الطلب ولا يمكن أن يتغيّر
  -- بهذا الطلب بعده.
  update public.payout_requests
  set status = 'paid', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;


revoke all on function public.request_payout        from public, anon;
revoke all on function public.cancel_payout_request from public, anon;
revoke all on function public.reject_payout_request from public, anon;
revoke all on function public.mark_payout_paid      from public, anon;

grant execute on function public.request_payout(numeric)           to authenticated;
grant execute on function public.cancel_payout_request(uuid)       to authenticated;
grant execute on function public.reject_payout_request(uuid, text) to authenticated;
grant execute on function public.mark_payout_paid(uuid, text)      to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) الطلبات المعلّقة القديمة — تصحيح أثر رجعي
-- -----------------------------------------------------------------------------
-- **طلبات أُنشئت قبل هذا الملف لم تُخصم من الرصيد.** لو تركناها لصارت
-- النماذج مختلطة: بعض الطلبات محجوزة وبعضها لا، ولا شيء في الصف يميّزها.
-- نحجزها الآن بأثر رجعي فيصير الجميع على قاعدة واحدة.
--
-- نتعرّف على غير المحجوز بغياب حركة محفظة تحمل وصف الحجز — لا بتاريخ
-- الطلب: التاريخ يخمّن، وغياب الحركة يقين.
do $do$
declare
  r record;
begin
  for r in
    select pr.* from public.payout_requests pr
    where pr.status = 'pending'
      and not exists (
        select 1 from public.wallet_transactions w
        where w.driver_id = pr.driver_id
          and w.description = 'حجز طلب سحب'
          and w.amount_iqd = -pr.amount_iqd
          and w.created_at >= pr.requested_at - interval '1 minute'
      )
  loop
    perform public.post_wallet_transaction(
      p_driver_id   => r.driver_id,
      p_txn_type    => 'payout',
      p_amount_iqd  => -r.amount_iqd,
      p_description => 'حجز طلب سحب'
    );
  end loop;
end
$do$;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.payout_requests where status = 'pending')
    as "طلبات معلّقة",
  public.payout_reserve_iqd() as "الرصيد المحجوز";


-- ##########################################################################
-- ملف: 0027_settings_welcome_coupons.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0027 — إعدادات عامة، ورصيد ترحيبي، وكوبونات الخصم
-- =============================================================================
-- ثلاث ميزات يجمعها أنها **بيانات يديرها المدير لا ثوابت في الكود**:
-- رقم شراء الرصيد، وقيمة الرصيد الترحيبي، وكوبونات الخصم بكل شروطها.
-- تغييرها لا يحتاج إعادة بناء تطبيق ولا نشر دالة.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) إعدادات عامة يقرؤها الجميع
-- -----------------------------------------------------------------------------
-- **لماذا جدول جديد ولا نستعمل `app_config`؟** لأن `app_config` يحمل
-- `service_role key` — مفتاحاً يتجاوز كل سياسات الأمان. جدوله بلا سياسات
-- قراءة عمداً، ولا يجوز أن نفتحه لأننا نحتاج رقم هاتف.
--
-- الفصل هنا ليس ترتيباً بل حماية: سرٌّ واحد في جدول مقروء يُسقط النظام كله.
create table if not exists public.public_settings (
  key         text primary key,
  value       text not null,
  label       text,                 -- اسم الإعداد كما يظهر في لوحة التحكم
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles(id)
);

alter table public.public_settings enable row level security;

drop policy if exists "settings: يقرأ الجميع" on public.public_settings;
create policy "settings: يقرأ الجميع"
  on public.public_settings for select to authenticated
  using (true);

drop policy if exists "settings: يكتب المشرف" on public.public_settings;
create policy "settings: يكتب المشرف"
  on public.public_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

comment on table public.public_settings is
  'إعدادات غير سرّية يقرؤها كل مستخدم مسجّل. لا تضع فيها مفاتيح إطلاقاً.';

insert into public.public_settings (key, value, label) values
  ('topup_whatsapp', '+9647801711922', 'رقم شراء الرصيد (واتساب)'),
  ('welcome_credit_iqd', '5000', 'الرصيد الترحيبي للسائق الجديد')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- ٢) الرصيد الترحيبي
-- -----------------------------------------------------------------------------
-- **مُشغّل على `drivers` لا داخل `handle_new_user`.** السائق قد يُنشأ من
-- مسار آخر لاحقاً (استيراد، إنشاء يدوي من اللوحة)، ومنطقٌ داخل دالة
-- التسجيل وحدها يفوته ذلك صامتاً.
create or replace function public.grant_welcome_credit()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_amount numeric;
begin
  select value::numeric into v_amount
  from public.public_settings where key = 'welcome_credit_iqd';

  if coalesce(v_amount, 0) > 0 then
    perform public.post_wallet_transaction(
      p_driver_id   => new.id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_amount,
      p_description => 'رصيد ترحيبي'
    );
  end if;

  return new;
end;
$fn$;

drop trigger if exists drivers_welcome_credit on public.drivers;
create trigger drivers_welcome_credit
  after insert on public.drivers
  for each row execute function public.grant_welcome_credit();


-- -----------------------------------------------------------------------------
-- ٣) الكوبونات
-- -----------------------------------------------------------------------------
create table if not exists public.coupons (
  id            uuid primary key default gen_random_uuid(),

  -- نخزّنه كما يكتبه المدير ونقارن بلا حساسية لحالة الأحرف: الراكب يكتب
  -- الرمز بيده على هاتف، و"ZANBOUR" و"zanbour" شيء واحد عنده.
  code          text not null unique,

  discount_pct  smallint not null check (discount_pct between 1 and 100),

  -- الجمهور. اليوم قيمة واحدة، والعمود موجود ليتوسّع بلا تغيير مخطط:
  -- ركّاب جدد، مدينة بعينها، من لم يركب منذ شهر…
  audience      text not null default 'all_riders',

  -- كم مرة يستعمله **الراكب الواحد**، لا الكوبون كله.
  max_uses_per_rider smallint not null default 1 check (max_uses_per_rider > 0),

  valid_from    timestamptz not null default now(),
  valid_until   timestamptz,          -- فارغ = بلا انتهاء
  is_active     boolean not null default true,

  note          text,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

create index if not exists coupons_active_idx
  on public.coupons (created_at desc) where is_active;

comment on table public.coupons is
  'كوبونات خصم بنسبة مئوية. الخصم يتحمّله المنصة ويُعوَّض للسائق كاملاً.';


create table if not exists public.coupon_redemptions (
  id           uuid primary key default gen_random_uuid(),
  coupon_id    uuid not null references public.coupons(id) on delete cascade,
  rider_id     uuid not null references public.profiles(id) on delete cascade,
  trip_id      uuid not null references public.trips(id) on delete cascade,
  discount_iqd numeric(10,2) not null default 0,
  created_at   timestamptz not null default now(),

  -- استعمال واحد لكل رحلة مهما تكرر الطلب
  unique (trip_id)
);

create index if not exists coupon_redemptions_rider_idx
  on public.coupon_redemptions (coupon_id, rider_id);


-- الرحلة تحمل أثر الكوبون: بلا ذلك لا نعرف عند الإنهاء كم نخصم ولمن نعوّض
alter table public.trips
  add column if not exists coupon_id    uuid references public.coupons(id),
  add column if not exists discount_iqd numeric(10,2) not null default 0;

comment on column public.trips.discount_iqd is
  'ما خُصم عن الراكب. يدفعه المنصة للسائق تعويضاً عند الإنهاء.';


alter table public.coupons            enable row level security;
alter table public.coupon_redemptions enable row level security;

-- **الراكب لا يقرأ جدول الكوبونات.** قراءته تعني تصفّح الرموز الصالحة
-- كلها. التحقق يمرّ بدالة تأخذ رمزاً وتردّ نعم أو لا.
drop policy if exists "coupons: للمشرف وحده" on public.coupons;
create policy "coupons: للمشرف وحده"
  on public.coupons for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "redemptions: يقرأ صاحبها والمشرف" on public.coupon_redemptions;
create policy "redemptions: يقرأ صاحبها والمشرف"
  on public.coupon_redemptions for select to authenticated
  using (rider_id = auth.uid() or public.is_admin());


-- -----------------------------------------------------------------------------
-- ٤) التحقق من كوبون — يستدعيه الراكب قبل الطلب
-- -----------------------------------------------------------------------------
-- تعيد نسبة الخصم وقيمته والأجرة بعده، أو ترفع خطأً بالعربية يشرح السبب.
create or replace function public.check_coupon(p_code text, p_fare numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_c    public.coupons;
  v_used integer;
  v_disc numeric(10,2);
begin
  if auth.uid() is null then
    raise exception 'سجّل دخولك أولاً' using errcode = 'insufficient_privilege';
  end if;

  select * into v_c from public.coupons
  where lower(code) = lower(btrim(coalesce(p_code, '')));

  if not found then
    raise exception 'رمز غير صحيح';
  end if;

  if not v_c.is_active then
    raise exception 'هذا الكوبون موقوف';
  end if;

  if now() < v_c.valid_from then
    raise exception 'هذا الكوبون لم يبدأ بعد';
  end if;

  if v_c.valid_until is not null and now() > v_c.valid_until then
    raise exception 'انتهت صلاحية هذا الكوبون';
  end if;

  select count(*) into v_used
  from public.coupon_redemptions r
  where r.coupon_id = v_c.id and r.rider_id = auth.uid();

  if v_used >= v_c.max_uses_per_rider then
    raise exception 'استعملت هذا الكوبون % مرة', v_c.max_uses_per_rider;
  end if;

  -- التقريب لأقرب ٢٥٠ كما في الأجرة نفسها: نقود العراق لا تعرف الوحدات
  -- الصغيرة، وخصم ١٨٧ ديناراً لا يُدفع في الشارع.
  v_disc := round((p_fare * v_c.discount_pct / 100.0) / 250) * 250;

  return jsonb_build_object(
    'coupon_id',    v_c.id,
    'code',         v_c.code,
    'discount_pct', v_c.discount_pct,
    'discount_iqd', v_disc,
    'fare_after',   greatest(p_fare - v_disc, 0),
    'uses_left',    v_c.max_uses_per_rider - v_used
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) طلب الرحلة يقبل كوبوناً
-- -----------------------------------------------------------------------------
-- **نحذف كل نسخ الدالة لا نسخةً بعينها.** `create or replace` لا يستبدل
-- دالة إن اختلف عدد معاملاتها بل يُنشئ نسخة ثانية بجانبها، فتتراكم
-- النسخ ويصير كل نداء بالاسم المجرّد غامضاً — وهو ما فشل به هذا الملف
-- في أول تشغيل. الحلقة تمسح ما وُجد أياً كان توقيعه.
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname = 'request_trip' and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

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
  p_note            text default null,
  p_coupon_code     text default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_rider   public.profiles;
  v_pickup  geography;
  v_dropoff geography;
  v_zone_id uuid;
  v_fare    jsonb;
  v_trip    public.trips;
  v_coupon  jsonb;
  v_cid     uuid;
  v_disc    numeric(10,2) := 0;
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

  -- **نتحقق من الكوبون هنا ثانيةً وإن تحقق التطبيق منه.** ما يُفحص على
  -- الهاتف يُتجاوز بتطبيق معدَّل، والخصم مالٌ حقيقي يخرج من جيبنا.
  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    v_coupon := public.check_coupon(p_coupon_code, (v_fare ->> 'total')::numeric);
    v_cid    := (v_coupon ->> 'coupon_id')::uuid;
    v_disc   := (v_coupon ->> 'discount_iqd')::numeric;
  end if;

  begin
    insert into public.trips (
      rider_id, pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note, coupon_id, discount_iqd
    ) values (
      auth.uid(), v_pickup, p_pickup_address,
      v_dropoff, p_dropoff_address,
      p_distance_m, p_duration_s,
      (v_fare ->> 'total')::numeric,
      (v_fare ->> 'surge_multiplier')::numeric,
      v_fare,
      p_payment_method, p_note, v_cid, v_disc
    )
    returning * into v_trip;
  exception when unique_violation then
    raise exception 'لديك رحلة نشطة بالفعل' using errcode = 'unique_violation';
  end;

  perform public.dispatch_next_offer(v_trip.id);

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) الإنهاء: الراكب يدفع أقل، والسائق يُعوَّض كاملاً
-- -----------------------------------------------------------------------------
-- **العمولة تُحسب على الأجرة الكاملة لا على المدفوع نقداً.** الخصم حملة
-- تسويقية نتحمّلها نحن، لا تخفيضٌ لحصة السائق. فحساب رحلة بألف وخصم ٢٥٪:
--
--   الراكب يدفع نقداً        750
--   عمولتنا (١٥٪ من 1000)    150  ← دَين على السائق كالعادة
--   تعويض الخصم             +250  ← يدخل محفظته
--   ──────────────────────────────
--   صافي ما ناله السائق      850  = تماماً كرحلة بلا كوبون
--
-- وتكلفة الحملة علينا ٢٥٠ ديناراً، وهي رقم نعرفه ونقيسه.
create or replace function public.complete_trip(
  p_trip_id          uuid,
  p_actual_distance_m integer default null,
  p_actual_duration_s integer default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip  public.trips;
  v_zone  uuid;
  v_fare  jsonb;
  v_dist  integer;
  v_dur   integer;
  v_disc  numeric(10,2);
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
  v_fare := public.calculate_fare(v_zone, v_dist, v_dur, v_trip.surge_multiplier);

  -- الخصم محسوب على تقدير الطلب. **لا نعيد حسابه على الأجرة النهائية:**
  -- الراكب رأى رقماً ووافق عليه، وتغييره بعد الركوب خيانة للتوقّع.
  -- ونحرسه من تجاوز الأجرة كي لا يصير الراكب دائناً لنا.
  v_disc := least(coalesce(v_trip.discount_iqd, 0),
                  (v_fare ->> 'total')::numeric);

  update public.trips
  set status             = 'completed',
      actual_distance_m  = v_dist,
      actual_duration_s  = v_dur,
      fare_final_iqd     = (v_fare ->> 'total')::numeric,
      commission_iqd     = (v_fare ->> 'commission')::numeric,
      driver_earning_iqd = (v_fare ->> 'driver_earning')::numeric,
      discount_iqd       = v_disc,
      fare_breakdown     = v_fare,
      payment_status     = case when v_trip.payment_method = 'cash'
                                then 'paid'::public.payment_status
                                else 'pending'::public.payment_status end
  where id = p_trip_id
  returning * into v_trip;

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

  -- تعويض الخصم: ما لم يقبضه السائق نقداً يدخل محفظته
  if v_disc > 0 then
    perform public.post_wallet_transaction(
      p_driver_id   => v_trip.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_disc,
      p_trip_id     => v_trip.id,
      p_description => format('تعويض خصم كوبون — رحلة %s', v_trip.trip_number)
    );

    -- نسجّل الاستعمال بعد نجاح الرحلة لا عند الطلب: رحلة أُلغيت لا تستهلك
    -- كوبوناً، والراكب الذي ألغى مرة لا يُعاقب بضياع خصمه.
    insert into public.coupon_redemptions
      (coupon_id, rider_id, trip_id, discount_iqd)
    values (v_trip.coupon_id, v_trip.rider_id, v_trip.id, v_disc)
    on conflict (trip_id) do nothing;
  end if;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.check_coupon(text, numeric) from public, anon;
revoke all on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text
) from public, anon;
revoke all on function public.complete_trip(uuid, integer, integer)
  from public, anon;

grant execute on function public.check_coupon(text, numeric) to authenticated;
grant execute on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text
) to authenticated;
grant execute on function public.complete_trip(uuid, integer, integer)
  to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select key as "الإعداد", value as "القيمة", label as "الاسم"
from public.public_settings
order by key;



-- ##########################################################################
-- ملف: 0028_stops_and_destination_change.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0028 — محطات متعددة، وتوقف في الطريق، وتغيير الوجهة أثناء الرحلة
-- =============================================================================
-- ثلاث ميزات تشترك في شيء واحد: **الرحلة لم تعد نقطتين.**
--
-- **قرار معماري يحكم الملف كله: لا حالات جديدة في `trip_status`.** كان
-- المغري إضافة `at_stop_1` و`at_stop_2`، لكن الحالة تدخل في المُشغّل
-- الحارس للانتقالات، وفي موجّهَي التطبيقين، وفي محرك المطابقة، وفي شاشة
-- التتبع، وفي كل استعلام يسأل "هل الرحلة نشطة؟". كل حالة جديدة تضرب في
-- خمسة مواضع.
--
-- البديل: **المحطات بيانات، والحالة تبقى خمساً.** جدول محطات مرتّب،
-- وعمود `current_leg` يقول أين نحن منها. الرحلة `in_progress` سواء كانت
-- في مرحلتها الأولى أو الثانية.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) ضوابط التسعير الجديدة
-- -----------------------------------------------------------------------------
alter table public.pricing_zones
  add column if not exists second_leg_discount_pct smallint not null default 10,
  add column if not exists stopover_surcharge_pct  smallint not null default 15,
  add column if not exists stopover_free_minutes   smallint not null default 10;

comment on column public.pricing_zones.second_leg_discount_pct is
  'خصم على المرحلة الثانية. تُسعَّر بالمسافة وحدها بلا أجرة بداية ولا حد '
  'أدنى، لأن السائق لم يأتِ من جديد ولم ينتظر راكباً آخر.';

comment on column public.pricing_zones.stopover_surcharge_pct is
  'زيادة التوقف في الطريق، تُحسب على مجموع الأجرة.';

comment on column public.pricing_zones.stopover_free_minutes is
  'كم دقيقة يشملها بدل التوقف. بلا حدٍّ يصير ١٥٪ ثمناً لانتظار نصف ساعة، '
  'والسائق سيرفض هذه الطلبات.';


-- -----------------------------------------------------------------------------
-- ٢) المحطات
-- -----------------------------------------------------------------------------
-- `seq = 1` هي الوجهة الأولى، و`seq = 2` الثانية. عمود `dropoff_location`
-- في `trips` يبقى **الوجهة الأخيرة**: عليه تعتمد شاشة التتبع وسجل الرحلات
-- والملاحة، وتغييره كان سيعيد كتابة نصف التطبيقين بلا مقابل.
create table if not exists public.trip_stops (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.trips(id) on delete cascade,
  seq         smallint not null check (seq >= 1),

  location    geography(Point, 4326) not null,
  address     text,

  -- مسافة وزمن **المرحلة المنتهية عند هذه المحطة**، لا من نقطة الانطلاق.
  leg_distance_m integer not null default 0,
  leg_duration_s integer not null default 0,
  leg_fare_iqd   numeric(10,2) not null default 0,

  arrived_at  timestamptz,

  unique (trip_id, seq)
);

create index if not exists trip_stops_trip_idx on public.trip_stops (trip_id, seq);

-- إحداثيات مسطّحة للقراءة من التطبيق: PostgREST يعيد عمود geography
-- بصيغة WKB سداسية عشرية لا يفهمها الهاتف. نفس نمط `trips` في 0014.
alter table public.trip_stops
  add column if not exists lat double precision
    generated always as (st_y(location::geometry)) stored,
  add column if not exists lng double precision
    generated always as (st_x(location::geometry)) stored;

alter table public.trip_stops enable row level security;

drop policy if exists "stops: طرفا الرحلة" on public.trip_stops;
create policy "stops: طرفا الرحلة"
  on public.trip_stops for select to authenticated
  using (public.is_trip_participant(trip_id) or public.is_admin());


alter table public.trips
  add column if not exists stop_count   smallint not null default 1,
  add column if not exists current_leg  smallint not null default 1,
  add column if not exists has_stopover boolean  not null default false,

  -- **الأجرة المجمَّدة.** حين تُحسب الأجرة من عناصر لا يستطيع
  -- `complete_trip` إعادة اشتقاقها — مراحل متعددة، أو تغيير وجهة في
  -- المنتصف — نخزّنها هنا ويحترمها الإنهاء بدل أن يعيد حسابها خطأً.
  add column if not exists fare_locked_iqd numeric(10,2);

comment on column public.trips.fare_locked_iqd is
  'أجرة نهائية محسوبة مسبقاً. حين تكون موجودة لا يعيد complete_trip الحساب.';


-- -----------------------------------------------------------------------------
-- ٣) حساب أجرة رحلة متعددة المراحل
-- -----------------------------------------------------------------------------
-- المرحلة الأولى تُسعَّر كرحلة كاملة (أجرة بداية + مسافة + حد أدنى).
-- والثانية **بالمسافة وحدها** ثم خصم، ثم تُضاف الزيادة إن كان هناك توقف.
create or replace function public.calculate_multi_fare(
  p_zone_id   uuid,
  p_leg1_m    integer,
  p_leg1_s    integer,
  p_leg2_m    integer default null,
  p_leg2_s    integer default null,
  p_stopover  boolean default false,
  p_surge     numeric default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  z          public.pricing_zones;
  v_first    jsonb;
  v_leg1     numeric;
  v_leg2     numeric := 0;
  v_stop_add numeric := 0;
  v_total    numeric;
  v_comm     numeric;
begin
  select * into z from public.pricing_zones where id = p_zone_id;
  if not found then
    raise exception 'المنطقة غير معروفة';
  end if;

  v_first := public.calculate_fare(p_zone_id, p_leg1_m, p_leg1_s, p_surge);
  v_leg1  := (v_first ->> 'total')::numeric;

  if coalesce(p_leg2_m, 0) > 0 then
    v_leg2 := (p_leg2_m / 1000.0) * z.per_km_iqd
              * (1 - z.second_leg_discount_pct / 100.0);
  end if;

  v_total := v_leg1 + v_leg2;

  if p_stopover then
    v_stop_add := v_total * z.stopover_surcharge_pct / 100.0;
    v_total := v_total + v_stop_add;
  end if;

  -- التقريب لأقرب ٢٥٠ كما في الأجرة العادية: نقود العراق لا تعرف ما دونها.
  v_total := round(v_total / 250) * 250;
  v_comm  := round(v_total * z.commission_rate, 2);

  return jsonb_build_object(
    'leg1_fare',      round(v_leg1, 2),
    'leg2_fare',      round(v_leg2, 2),
    'stopover_add',   round(v_stop_add, 2),
    'stopover',       p_stopover,
    'stopover_free_minutes', z.stopover_free_minutes,
    'total',          v_total,
    'commission',     v_comm,
    'driver_earning', v_total - v_comm,
    'surge_multiplier', (v_first ->> 'surge_multiplier')::numeric
  );
end;
$fn$;


-- تقدير يستدعيه الراكب قبل الطلب — يعيد الأجرة وتفصيلها بلا إنشاء رحلة.
create or replace function public.estimate_multi_trip(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_leg1_m     integer,
  p_leg1_s     integer,
  p_leg2_m     integer default null,
  p_leg2_s     integer default null,
  p_stopover   boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_pickup geography;
  v_zone   uuid;
begin
  v_pickup := st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography;
  v_zone   := public.zone_for_point(v_pickup);

  if v_zone is null then
    return jsonb_build_object(
      'available', false,
      'message', 'نقطة الانطلاق خارج نطاق الخدمة'
    );
  end if;

  return public.calculate_multi_fare(
    v_zone, p_leg1_m, p_leg1_s, p_leg2_m, p_leg2_s, p_stopover
  ) || jsonb_build_object('available', true);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) طلب الرحلة يقبل محطة ثانية وتوقفاً
-- -----------------------------------------------------------------------------
-- **نحذف كل نسخ الدالة لا نسخةً بعينها.** `create or replace` لا يستبدل
-- دالة إن اختلف عدد معاملاتها بل يُنشئ نسخة ثانية بجانبها، فتتراكم
-- النسخ ويصير كل نداء بالاسم المجرّد غامضاً — وهو ما فشل به هذا الملف
-- في أول تشغيل. الحلقة تمسح ما وُجد أياً كان توقيعه.
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname = 'request_trip' and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

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
  p_note            text default null,
  p_coupon_code     text default null,
  -- المحطة الثانية، إن وُجدت. `p_leg2_m` مسافة المرحلة من الوجهة الأولى
  -- إليها لا من نقطة الانطلاق.
  p_stop2_lat       double precision default null,
  p_stop2_lng       double precision default null,
  p_stop2_address   text default null,
  p_leg2_m          integer default null,
  p_leg2_s          integer default null,
  p_stopover        boolean default false
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_rider    public.profiles;
  v_pickup   geography;
  v_dropoff  geography;
  v_stop2    geography;
  v_zone_id  uuid;
  v_fare     jsonb;
  v_trip     public.trips;
  v_coupon   jsonb;
  v_cid      uuid;
  v_disc     numeric(10,2) := 0;
  v_multi    boolean;
  v_final    geography;
  v_final_ad text;
begin
  select * into v_rider from public.profiles where id = auth.uid();
  if not found or v_rider.is_blocked then
    raise exception 'غير مصرّح لك بطلب رحلة' using errcode = 'insufficient_privilege';
  end if;

  v_pickup  := st_setsrid(st_makepoint(p_pickup_lng,  p_pickup_lat),  4326)::geography;
  v_dropoff := st_setsrid(st_makepoint(p_dropoff_lng, p_dropoff_lat), 4326)::geography;

  v_multi := p_stop2_lat is not null and p_stop2_lng is not null
             and coalesce(p_leg2_m, 0) > 0;

  if v_multi then
    v_stop2 := st_setsrid(st_makepoint(p_stop2_lng, p_stop2_lat), 4326)::geography;
  end if;

  v_zone_id := public.zone_for_point(v_pickup);
  if v_zone_id is null then
    raise exception 'نقطة الانطلاق خارج نطاق الخدمة';
  end if;

  v_fare := public.calculate_multi_fare(
    v_zone_id, p_distance_m, p_duration_s,
    case when v_multi then p_leg2_m else null end,
    case when v_multi then p_leg2_s else null end,
    coalesce(p_stopover, false)
  );

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    v_coupon := public.check_coupon(p_coupon_code, (v_fare ->> 'total')::numeric);
    v_cid    := (v_coupon ->> 'coupon_id')::uuid;
    v_disc   := (v_coupon ->> 'discount_iqd')::numeric;
  end if;

  -- **`dropoff` يحمل الوجهة الأخيرة** لا الأولى: شاشة التتبع وسجل
  -- الرحلات والملاحة كلها تقرؤه، ووضع الوجهة الأولى فيه يجعل الراكب
  -- يرى رحلته منتهية عند منتصفها.
  v_final    := case when v_multi then v_stop2 else v_dropoff end;
  v_final_ad := case when v_multi then p_stop2_address else p_dropoff_address end;

  begin
    insert into public.trips (
      rider_id, pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note, coupon_id, discount_iqd,
      stop_count, current_leg, has_stopover, fare_locked_iqd
    ) values (
      auth.uid(), v_pickup, p_pickup_address,
      v_final, v_final_ad,
      p_distance_m + coalesce(case when v_multi then p_leg2_m end, 0),
      p_duration_s + coalesce(case when v_multi then p_leg2_s end, 0),
      (v_fare ->> 'total')::numeric,
      (v_fare ->> 'surge_multiplier')::numeric,
      v_fare,
      p_payment_method, p_note, v_cid, v_disc,
      case when v_multi then 2 else 1 end, 1,
      coalesce(p_stopover, false),
      (v_fare ->> 'total')::numeric
    )
    returning * into v_trip;
  exception when unique_violation then
    raise exception 'لديك رحلة نشطة بالفعل' using errcode = 'unique_violation';
  end;

  insert into public.trip_stops
    (trip_id, seq, location, address, leg_distance_m, leg_duration_s, leg_fare_iqd)
  values
    (v_trip.id, 1, v_dropoff, p_dropoff_address,
     p_distance_m, p_duration_s, (v_fare ->> 'leg1_fare')::numeric);

  if v_multi then
    insert into public.trip_stops
      (trip_id, seq, location, address, leg_distance_m, leg_duration_s, leg_fare_iqd)
    values
      (v_trip.id, 2, v_stop2, p_stop2_address,
       p_leg2_m, p_leg2_s, (v_fare ->> 'leg2_fare')::numeric);
  end if;

  perform public.dispatch_next_offer(v_trip.id);

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) الوصول إلى محطة وسيطة
-- -----------------------------------------------------------------------------
-- **زر مستقل عن الإنهاء عمداً.** لو تركنا زر "إنهاء الرحلة" وحده لضغطه
-- السائق عند الوجهة الأولى بحكم العادة، فتُقفل الرحلة وتضيع المرحلة
-- الثانية وأجرتها.
create or replace function public.arrive_at_stop(p_trip_id uuid)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip public.trips;
  v_stop public.trip_stops;
  v_loc  geography;
  v_age  integer;
  v_dist integer;
  v_rad  integer;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك'
      using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status <> 'in_progress' then
    raise exception 'الرحلة لم تبدأ بعد';
  end if;

  if v_trip.current_leg >= v_trip.stop_count then
    raise exception 'هذه آخر محطة — استعمل زر الإنهاء';
  end if;

  select * into v_stop from public.trip_stops
  where trip_id = p_trip_id and seq = v_trip.current_leg;

  -- الحارس نفسه المستعمل في "وصلت إلى الراكب": ما يُفحص على الهاتف
  -- يُتجاوز بتطبيق معدَّل.
  select round(z.arrival_radius_m * 1.5)::integer into v_rad
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  select d.current_location,
         round(extract(epoch from (now() - d.location_updated_at)))::integer
  into v_loc, v_age
  from public.drivers d where d.id = auth.uid();

  if v_loc is null or v_age is null or v_age > 120 then
    raise exception 'تعذّر تحديد موقعك. تأكد أن خدمة الموقع تعمل';
  end if;

  v_dist := st_distance(v_loc, v_stop.location)::integer;
  if v_dist > coalesce(v_rad, 300) then
    raise exception 'أنت على بعد % متر من المحطة. اقترب إلى أقل من % متر',
      v_dist, coalesce(v_rad, 300);
  end if;

  update public.trip_stops set arrived_at = now()
  where trip_id = p_trip_id and seq = v_trip.current_leg;

  update public.trips set current_leg = current_leg + 1
  where id = p_trip_id
  returning * into v_trip;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) تغيير الوجهة أثناء الرحلة
-- -----------------------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from pg_type where typname = 'change_status') then
    create type public.change_status as enum ('pending', 'approved', 'rejected');
  end if;
end
$do$;

create table if not exists public.trip_change_requests (
  id           uuid primary key default gen_random_uuid(),
  trip_id      uuid not null references public.trips(id) on delete cascade,

  new_location geography(Point, 4326) not null,
  new_address  text,

  -- ما قطعه السائق فعلاً حتى لحظة الطلب، ومسار الوجهة الجديدة من هناك.
  travelled_m  integer not null,
  new_leg_m    integer not null,
  new_leg_s    integer not null,

  -- الأجرة المقترحة كاملةً بعد التغيير. الراكب يراها قبل أن يطلب،
  -- والسائق يراها قبل أن يوافق — لا مفاجآت عند التسليم.
  quoted_fare_iqd numeric(10,2) not null,

  status       public.change_status not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz
);

create index if not exists change_requests_trip_idx
  on public.trip_change_requests (trip_id, created_at desc);

create unique index if not exists change_requests_one_pending_idx
  on public.trip_change_requests (trip_id) where status = 'pending';

alter table public.trip_change_requests enable row level security;

drop policy if exists "changes: طرفا الرحلة" on public.trip_change_requests;
create policy "changes: طرفا الرحلة"
  on public.trip_change_requests for select to authenticated
  using (public.is_trip_participant(trip_id) or public.is_admin());


-- الراكب يطلب التغيير
create or replace function public.request_destination_change(
  p_trip_id     uuid,
  p_new_lat     double precision,
  p_new_lng     double precision,
  p_new_address text,
  p_travelled_m integer,
  p_new_leg_m   integer,
  p_new_leg_s   integer
)
returns public.trip_change_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip   public.trips;
  v_zone   uuid;
  v_earned jsonb;
  v_extra  numeric;
  v_quote  numeric;
  v_row    public.trip_change_requests;
  z        public.pricing_zones;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and rider_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك'
      using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status <> 'in_progress' then
    raise exception 'تغيير الوجهة متاح أثناء الرحلة فقط';
  end if;

  if exists (select 1 from public.trip_change_requests
             where trip_id = p_trip_id and status = 'pending') then
    raise exception 'لديك طلب تغيير بانتظار ردّ السائق';
  end if;

  v_zone := public.zone_for_point(v_trip.pickup_location);
  select * into z from public.pricing_zones where id = v_zone;

  -- **المستحق حتى نقطة التغيير يُسعَّر كرحلة كاملة**: أجرة بداية وحد
  -- أدنى. السائق أتى من مكانه وانتظر وحمل الراكب — كل ذلك حدث فعلاً
  -- ولا يُلغيه تغيير الوجهة.
  v_earned := public.calculate_fare(v_zone, greatest(p_travelled_m, 0), 0,
                                    v_trip.surge_multiplier);

  -- **والمسار الجديد بالمسافة وحدها**: لا أجرة بداية ثانية، فالسائق لم
  -- يبدأ رحلة جديدة بل واصل واحدة. وبلا خصم المرحلة الثانية أيضاً —
  -- ذلك الخصم مقابل التخطيط المسبق، والتغيير المفاجئ عكسه.
  v_extra := (greatest(p_new_leg_m, 0) / 1000.0) * z.per_km_iqd;

  v_quote := (v_earned ->> 'total')::numeric + v_extra;
  if v_trip.has_stopover then
    v_quote := v_quote * (1 + z.stopover_surcharge_pct / 100.0);
  end if;
  v_quote := round(v_quote / 250) * 250;

  insert into public.trip_change_requests (
    trip_id, new_location, new_address,
    travelled_m, new_leg_m, new_leg_s, quoted_fare_iqd
  ) values (
    p_trip_id,
    st_setsrid(st_makepoint(p_new_lng, p_new_lat), 4326)::geography,
    p_new_address,
    greatest(p_travelled_m, 0), greatest(p_new_leg_m, 0),
    greatest(p_new_leg_s, 0), v_quote
  )
  returning * into v_row;

  return v_row;
end;
$fn$;


-- السائق يردّ
create or replace function public.respond_destination_change(
  p_id     uuid,
  p_accept boolean
)
returns public.trip_change_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row  public.trip_change_requests;
  v_trip public.trips;
begin
  select * into v_row from public.trip_change_requests
  where id = p_id and status = 'pending'
  for update;

  if not found then
    raise exception 'الطلب غير موجود أو رُدّ عليه';
  end if;

  select * into v_trip from public.trips
  where id = v_row.trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'هذه الرحلة ليست لك' using errcode = 'insufficient_privilege';
  end if;

  if not p_accept then
    update public.trip_change_requests
    set status = 'rejected', responded_at = now()
    where id = p_id
    returning * into v_row;
    -- **الرحلة تمضي كما هي.** لا رسوم ولا إلغاء: الراكب طلب واعتذر
    -- السائق، وهذا ليس خطأً من أحد.
    return v_row;
  end if;

  update public.trip_change_requests
  set status = 'approved', responded_at = now()
  where id = p_id
  returning * into v_row;

  -- الوجهة الجديدة تحلّ محل القديمة، والأجرة تُجمَّد على ما وافق عليه
  -- الطرفان. `arrive_at_stop` لا يعود له معنى بعدها — المحطة واحدة.
  update public.trips
  set dropoff_location     = v_row.new_location,
      dropoff_address      = v_row.new_address,
      estimated_distance_m = v_row.travelled_m + v_row.new_leg_m,
      fare_estimated_iqd   = v_row.quoted_fare_iqd,
      fare_locked_iqd      = v_row.quoted_fare_iqd,
      stop_count           = 1,
      current_leg          = 1
  where id = v_row.trip_id;

  -- المحطات القديمة لم تعد تصف الرحلة. نحذف ما لم يُوصَل إليه ونُبقي
  -- ما وصله السائق فعلاً — سجلٌّ صادق لما جرى.
  delete from public.trip_stops
  where trip_id = v_row.trip_id and arrived_at is null;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الإنهاء يحترم الأجرة المجمَّدة
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
as $fn$
declare
  v_trip  public.trips;
  v_zone  uuid;
  v_fare  jsonb;
  v_dist  integer;
  v_dur   integer;
  v_disc  numeric(10,2);
  v_total numeric(10,2);
  v_comm  numeric(10,2);
  v_rate  numeric;
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

  -- **لا إنهاء قبل بلوغ المحطة الأخيرة.** بلا هذا يُقفل السائق رحلةً
  -- متعددة المحطات عند أولاها فتضيع مرحلة كاملة وأجرتها.
  if v_trip.current_leg < v_trip.stop_count then
    raise exception 'بقيت محطة أخرى. اضغط "وصلت إلى المحطة" أولاً';
  end if;

  v_dist := coalesce(p_actual_distance_m, v_trip.estimated_distance_m);
  v_dur  := coalesce(
    p_actual_duration_s,
    extract(epoch from (now() - v_trip.started_at))::integer,
    v_trip.estimated_duration_s
  );

  v_zone := public.zone_for_point(v_trip.pickup_location);
  v_fare := public.calculate_fare(v_zone, v_dist, v_dur, v_trip.surge_multiplier);

  -- **الأجرة المجمَّدة تسبق إعادة الحساب.** رحلة بمرحلتين أو غُيّرت
  -- وجهتها لا يستطيع هذا السطر اشتقاق سعرها من المسافة الكلية: خصمُ
  -- المرحلة الثانية وزيادةُ التوقف والمستحقُّ قبل التغيير كلها عناصر
  -- حُسبت مرة ووافق عليها الطرفان.
  if v_trip.fare_locked_iqd is not null then
    select commission_rate into v_rate
    from public.pricing_zones where id = v_zone;

    v_total := v_trip.fare_locked_iqd;
    v_comm  := round(v_total * coalesce(v_rate, 0.15), 2);
  else
    v_total := (v_fare ->> 'total')::numeric;
    v_comm  := (v_fare ->> 'commission')::numeric;
  end if;

  v_disc := least(coalesce(v_trip.discount_iqd, 0), v_total);

  update public.trips
  set status             = 'completed',
      actual_distance_m  = v_dist,
      actual_duration_s  = v_dur,
      fare_final_iqd     = v_total,
      commission_iqd     = v_comm,
      driver_earning_iqd = v_total - v_comm,
      discount_iqd       = v_disc,
      fare_breakdown     = coalesce(v_trip.fare_breakdown, v_fare),
      payment_status     = case when v_trip.payment_method = 'cash'
                                then 'paid'::public.payment_status
                                else 'pending'::public.payment_status end
  where id = p_trip_id
  returning * into v_trip;

  perform set_config('app.bypass_guards', 'on', true);

  update public.drivers
  set status          = 'online',
      trips_completed = trips_completed + 1
  where id = v_trip.driver_id;

  perform set_config('app.bypass_guards', 'off', true);

  perform public.post_wallet_transaction(
    p_driver_id   => v_trip.driver_id,
    p_txn_type    => 'commission',
    p_amount_iqd  => -v_trip.commission_iqd,
    p_trip_id     => v_trip.id,
    p_description => format('عمولة الرحلة رقم %s', v_trip.trip_number)
  );

  if v_disc > 0 then
    perform public.post_wallet_transaction(
      p_driver_id   => v_trip.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_disc,
      p_trip_id     => v_trip.id,
      p_description => format('تعويض خصم كوبون — رحلة %s', v_trip.trip_number)
    );

    insert into public.coupon_redemptions
      (coupon_id, rider_id, trip_id, discount_iqd)
    values (v_trip.coupon_id, v_trip.rider_id, v_trip.id, v_disc)
    on conflict (trip_id) do nothing;
  end if;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٨) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.calculate_multi_fare(
  uuid, integer, integer, integer, integer, boolean, numeric) from public, anon;
revoke all on function public.estimate_multi_trip(double precision, double precision, integer, integer, integer, integer, boolean)
  from public, anon;
revoke all on function public.arrive_at_stop(uuid) from public, anon;
revoke all on function public.request_destination_change(uuid, double precision, double precision, text, integer, integer, integer)
  from public, anon;
revoke all on function public.respond_destination_change(uuid, boolean)
  from public, anon;
revoke all on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text,
  double precision, double precision, text, integer, integer, boolean
) from public, anon;
revoke all on function public.complete_trip(uuid, integer, integer)
  from public, anon;

grant execute on function public.calculate_multi_fare(
  uuid, integer, integer, integer, integer, boolean, numeric) to authenticated;
grant execute on function public.estimate_multi_trip(
  double precision, double precision, integer, integer, integer, integer, boolean)
  to authenticated;
grant execute on function public.arrive_at_stop(uuid) to authenticated;
grant execute on function public.request_destination_change(
  uuid, double precision, double precision, text, integer, integer, integer)
  to authenticated;
grant execute on function public.respond_destination_change(uuid, boolean)
  to authenticated;
grant execute on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text,
  double precision, double precision, text, integer, integer, boolean
) to authenticated;
grant execute on function public.complete_trip(uuid, integer, integer)
  to authenticated;

-- البثّ اللحظي لطلبات التغيير: السائق يجب أن يراها فور إرسالها
do $do$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'trip_change_requests'
  ) then
    alter publication supabase_realtime add table public.trip_change_requests;
  end if;
end
$do$;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar             as "المنطقة",
  second_leg_discount_pct  as "خصم المرحلة ٢",
  stopover_surcharge_pct   as "زيادة التوقف",
  stopover_free_minutes    as "دقائق التوقف"
from public.pricing_zones
order by city_name_ar
limit 3;


-- ##########################################################################
-- ملف: 0029_staff_and_audit.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0029 — الموظفون وصلاحياتهم، وسجلّ التدقيق
-- =============================================================================
-- حتى اليوم كان في النظام رتبتان: مستخدم ومشرف. والمشرف يملك كل شيء —
-- يعتمد السائقين، ويولّد المال (رموز التعبئة)، ويدفع السحوبات.
--
-- **هذا لا يصمد مع موظف واحد.** من يراجع الوثائق لا يجب أن يولّد رموزاً،
-- ومن يدفع السحوبات لا يجب أن ينشئ كوبونات. وحين يختلف رقمان في آخر
-- الشهر يجب أن نعرف **من** فعل ماذا ومتى.
--
-- فهذا الملف يضيف طبقتين: **صلاحيات مفصّلة**، و**سجلّ لا يُمحى**.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) المالك
-- -----------------------------------------------------------------------------
-- **بريدٌ واحد لا يُمنح ولا يُسحب.** لو جعلنا الملكية صلاحيةً في جدول
-- لأمكن لمشرفٍ أن يمنحها نفسه، أو أن يسحبها من الجميع فيُقفل النظام على
-- لا أحد. ربطها بالبريد يجعلها ثابتة خارج متناول الجدول.
create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and lower(email) = 'ali.alkawary@gmail.com'
  );
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الصلاحيات
-- -----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists staff_permissions text[] not null default '{}';

comment on column public.profiles.staff_permissions is
  'صلاحيات الموظف. المالك يملك كل شيء بلا حاجة إليها.';

-- الصلاحيات المعروفة — تُقرأ في لوحة التحكم لبناء قائمة الاختيار،
-- فلا تتفرّق أسماؤها بين الخادم والواجهة.
create or replace function public.known_permissions()
returns table (code text, label text)
language sql
immutable
as $fn$
  values
    ('drivers.review',  'مراجعة السائقين واعتمادهم'),
    ('drivers.view',    'عرض السائقين وأرصدتهم'),
    ('trips.view',      'عرض الرحلات'),
    ('trips.cancel',    'إلغاء رحلة جارية'),
    ('topups.generate', 'توليد رموز التعبئة'),
    ('topups.view',     'عرض رموز التعبئة'),
    ('payouts.process', 'معالجة طلبات السحب'),
    ('coupons.manage',  'إنشاء الكوبونات وإيقافها'),
    ('settings.manage', 'تعديل الإعدادات العامة')
$fn$;


create or replace function public.has_perm(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select public.is_owner()
      or exists (
        select 1 from public.profiles
        where id = auth.uid()
          and role = 'admin'
          and p_code = any(staff_permissions)
      );
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) سجلّ التدقيق
-- -----------------------------------------------------------------------------
-- **لا حذف ولا تعديل، حتى للمالك.** سجلٌّ يستطيع صاحبه محوه ليس سجلاً.
create table if not exists public.audit_log (
  id         bigserial primary key,
  actor_id   uuid references public.profiles(id),
  actor_name text,          -- منسوخ وقت الفعل: الحساب قد يُحذف والسجل يبقى
  action     text not null, -- 'topup.generate' · 'coupon.create' …
  entity     text,
  entity_id  text,
  summary    text,          -- وصف عربي جاهز للعرض بلا تفسير في الواجهة
  created_at timestamptz not null default now()
);

create index if not exists audit_log_recent_idx on public.audit_log (created_at desc);
create index if not exists audit_log_actor_idx  on public.audit_log (actor_id, created_at desc);

alter table public.audit_log enable row level security;

drop policy if exists "audit: يقرأ المشرف" on public.audit_log;
create policy "audit: يقرأ المشرف"
  on public.audit_log for select to authenticated
  using (public.is_admin());

-- لا سياسة إدراج ولا تحديث ولا حذف: الكتابة تمرّ بالدالة وحدها.

create or replace function public.log_action(
  p_action  text,
  p_entity  text default null,
  p_id      text default null,
  p_summary text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_name text;
begin
  select full_name into v_name from public.profiles where id = auth.uid();
  insert into public.audit_log (actor_id, actor_name, action, entity, entity_id, summary)
  values (auth.uid(), v_name, p_action, p_entity, p_id, p_summary);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) تسجيل الأفعال المالية
-- -----------------------------------------------------------------------------
-- **مُشغّلات لا نداءات من الواجهة.** لو تركنا التسجيل للتطبيق لنسيه أول
-- مسار جديد، ولاستطاع من ينادي الدالة مباشرةً تخطّيه. المُشغّل يلتقط
-- الفعل من مصدره مهما كان الطريق.
create or replace function public.audit_topup_code()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if tg_op = 'INSERT' then
    perform public.log_action('topup.generate', 'topup_code', new.id::text,
      format('ولّد رمز تعبئة بقيمة %s دينار', new.amount_iqd::bigint));
  elsif new.redeemed_by is distinct from old.redeemed_by
        and new.redeemed_by is not null then
    perform public.log_action('topup.redeem', 'topup_code', new.id::text,
      format('استُهلك رمز بقيمة %s دينار', new.amount_iqd::bigint));
  end if;
  return new;
end;
$fn$;

drop trigger if exists topup_codes_audit on public.topup_codes;
create trigger topup_codes_audit
  after insert or update of redeemed_by on public.topup_codes
  for each row execute function public.audit_topup_code();


create or replace function public.audit_coupon()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if tg_op = 'INSERT' then
    perform public.log_action('coupon.create', 'coupon', new.id::text,
      format('أنشأ كوبون %s بخصم %s٪', new.code, new.discount_pct));
  elsif new.is_active is distinct from old.is_active then
    perform public.log_action(
      case when new.is_active then 'coupon.enable' else 'coupon.disable' end,
      'coupon', new.id::text,
      format('%s الكوبون %s',
             case when new.is_active then 'فعّل' else 'أوقف' end, new.code));
  end if;
  return new;
end;
$fn$;

drop trigger if exists coupons_audit on public.coupons;
create trigger coupons_audit
  after insert or update of is_active on public.coupons
  for each row execute function public.audit_coupon();


create or replace function public.audit_payout()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.status is distinct from old.status then
    perform public.log_action('payout.' || new.status, 'payout', new.id::text,
      format('%s طلب سحب بقيمة %s دينار',
             case new.status when 'paid' then 'دفع' else 'رفض' end,
             new.amount_iqd::bigint));
  end if;
  return new;
end;
$fn$;

drop trigger if exists payout_requests_audit on public.payout_requests;
create trigger payout_requests_audit
  after update of status on public.payout_requests
  for each row execute function public.audit_payout();


-- -----------------------------------------------------------------------------
-- ٥) إدارة الموظفين — للمالك وحده
-- -----------------------------------------------------------------------------
create or replace function public.staff_list()
returns table (
  id          uuid,
  full_name   text,
  email       text,
  phone       text,
  permissions text[],
  is_owner    boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select p.id, p.full_name, p.email, p.phone, p.staff_permissions,
         lower(p.email) = 'ali.alkawary@gmail.com'
  from public.profiles p
  where p.role = 'admin'
    and public.is_owner()
  order by lower(p.email) = 'ali.alkawary@gmail.com' desc, p.full_name;
$fn$;


-- يرقّي حساباً قائماً إلى موظف بصلاحيات محددة.
--
-- **لا ننشئ حساباً هنا.** إنشاء المستخدمين يمرّ بنظام المصادقة وحده،
-- وتقليدُه من جدول `profiles` يترك حساباً بلا كلمة مرور ولا بريد مؤكَّد.
-- الموظف يسجّل كراكب أولاً، ثم يُرقّى.
create or replace function public.set_staff(p_email text, p_permissions text[])
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_id uuid; v_name text;
begin
  if not public.is_owner() then
    raise exception 'للمالك وحده' using errcode = 'insufficient_privilege';
  end if;

  select id, full_name into v_id, v_name from public.profiles
  where lower(email) = lower(btrim(p_email));

  if v_id is null then
    raise exception 'لا يوجد حساب بهذا البريد. اطلب منه التسجيل في التطبيق أولاً';
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.profiles
  set role = 'admin', staff_permissions = coalesce(p_permissions, '{}')
  where id = v_id;
  perform set_config('app.bypass_guards', 'off', true);

  perform public.log_action('staff.set', 'profile', v_id::text,
    format('منح %s صلاحيات موظف (%s)', coalesce(v_name, p_email),
           array_length(coalesce(p_permissions,'{}'), 1)));
end;
$fn$;


create or replace function public.remove_staff(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_email text; v_name text;
begin
  if not public.is_owner() then
    raise exception 'للمالك وحده' using errcode = 'insufficient_privilege';
  end if;

  select email, full_name into v_email, v_name
  from public.profiles where id = p_id;

  -- **المالك لا يُنزَع.** بلا هذا الحارس يستطيع المالك أن يسحب صلاحيته
  -- من نفسه بضغطة، فيُقفل النظام على لا أحد ولا سبيل للعودة.
  if lower(coalesce(v_email, '')) = 'ali.alkawary@gmail.com' then
    raise exception 'لا يمكن نزع صلاحيات المالك';
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.profiles
  set role = 'rider', staff_permissions = '{}'
  where id = p_id;
  perform set_config('app.bypass_guards', 'off', true);

  perform public.log_action('staff.remove', 'profile', p_id::text,
    format('نزع صلاحيات %s', coalesce(v_name, v_email)));
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) إلغاء رحلة من اللوحة
-- -----------------------------------------------------------------------------
-- `cancel_trip` تشترط أن يكون المنادي راكب الرحلة أو سائقها. المدير ليس
-- أياً منهما، فيحتاج باباً خاصاً — ولا رسوم ولا عقوبة على أحد: إلغاء
-- إداري لا خطأ من طرف.
create or replace function public.admin_cancel_trip(p_trip_id uuid, p_reason text)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_trip public.trips;
begin
  if not public.has_perm('trips.cancel') then
    raise exception 'لا تملك صلاحية إلغاء الرحلات'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'الرحلة غير موجودة';
  end if;
  if v_trip.status in ('completed', 'cancelled') then
    raise exception 'الرحلة منتهية بالفعل';
  end if;

  update public.trips
  set status = 'cancelled', cancelled_by = auth.uid(),
      cancellation_reason = coalesce(p_reason, 'إلغاء إداري'),
      cancellation_fee_iqd = 0
  where id = p_trip_id
  returning * into v_trip;

  update public.trip_offers set status = 'cancelled', responded_at = now()
  where trip_id = p_trip_id and status = 'pending';

  if v_trip.driver_id is not null then
    perform set_config('app.bypass_guards', 'on', true);
    update public.drivers
    set status = case when status = 'on_trip' then 'online' else status end
    where id = v_trip.driver_id;
    perform set_config('app.bypass_guards', 'off', true);
  end if;

  perform public.log_action('trip.cancel', 'trip', p_trip_id::text,
    format('ألغى الرحلة رقم %s — %s', v_trip.trip_number,
           coalesce(p_reason, 'بلا سبب')));

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.set_staff        from public, anon;
revoke all on function public.remove_staff     from public, anon;
revoke all on function public.admin_cancel_trip from public, anon;
revoke all on function public.log_action       from public, anon;

grant execute on function public.is_owner()                        to authenticated;
grant execute on function public.has_perm(text)                    to authenticated;
grant execute on function public.known_permissions()               to authenticated;
grant execute on function public.staff_list()                      to authenticated;
grant execute on function public.set_staff(text, text[])           to authenticated;
grant execute on function public.remove_staff(uuid)                to authenticated;
grant execute on function public.admin_cancel_trip(uuid, text)     to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.known_permissions()) as "صلاحيات معرّفة",
  (select count(*) from public.profiles where role = 'admin') as "حسابات إدارية",
  (select count(*) from public.audit_log) as "سجلات تدقيق";


-- ##########################################################################
-- ملف: 0030_support_and_zone_gating.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0030 — أرقام الدعم، وحصر العمل بالناصرية
-- =============================================================================
-- تعديلان قبل الإطلاق:
--
--   ١) **رقما دعم منفصلان** للسائقين وللركّاب. سؤال السائق عن عمولة أو
--      رمز تعبئة لا يشبه سؤال الراكب عن أجرة أو سائق تأخّر، وخلطهما في
--      رقم واحد يجعل الرد على الاثنين أبطأ.
--
--   ٢) **العمل في الناصرية وحدها.** المحافظات الثماني عشرة كلها معرّفة
--      في القاعدة لكن **معطّلة**، ولكلٍّ منها مفتاح تفعيل في اللوحة.
--
-- **لماذا نعرّفها كلها ونعطّلها بدل حذفها؟** لأن التوسّع حينها قرارٌ
-- بضغطة لا ترحيلٌ جديد. ولأن الحدود مرسومة ومراجَعة الآن، لا في يومٍ
-- نكون فيه مستعجلين.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) أرقام الدعم
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('support_whatsapp_driver', '', 'رقم دعم السائقين (واتساب)'),
  ('support_whatsapp_rider',  '', 'رقم دعم الركّاب (واتساب)')
on conflict (key) do nothing;

-- **فارغان عمداً لا مملوءان برقمك.** زرُّ دعم يفتح رقماً خاطئاً أسوأ من
-- غياب الزر: الراكب يظن أنه راسل الدعم ويبقى ينتظر رداً لا يأتي.
-- التطبيقان يخفيان الزر ما دام الرقم فارغاً.


-- -----------------------------------------------------------------------------
-- ٢) المحافظات الأربع الناقصة
-- -----------------------------------------------------------------------------
-- كانت أربع عشرة. هذه تكمل الثماني عشرة.
--
-- **مستطيلات كما في 0012 لا مضلعات دقيقة.** والقيد نفسه قائم: تغطّي
-- المدينة وشيئاً من الصحراء حولها. مقبول لمنطقة **معطّلة** — وقبل تفعيل
-- أيٍّ منها ارسم لها مضلعاً حقيقياً على geojson.io.
insert into public.pricing_zones (
  city_name, city_name_ar, boundary,
  base_fare_iqd, per_km_iqd, per_minute_iqd, minimum_fare_iqd,
  cancellation_fee_iqd, commission_rate,
  search_radius_m, max_search_radius_m, is_active
) values
  ('Duhok', 'دهوك',
   st_geogfromtext('POLYGON((42.79 36.66, 43.19 36.66, 43.19 37.08, 42.79 37.08, 42.79 36.66))'),
   500, 250, 0, 1000, 0, 0.150, 4000, 10000, false),
  ('Baquba', 'بعقوبة',
   st_geogfromtext('POLYGON((44.44 33.54, 44.84 33.54, 44.84 33.96, 44.44 33.96, 44.44 33.54))'),
   500, 250, 0, 1000, 0, 0.150, 4000, 10000, false),
  ('Ramadi', 'الرمادي',
   st_geogfromtext('POLYGON((43.11 33.21, 43.51 33.21, 43.51 33.63, 43.11 33.63, 43.11 33.21))'),
   500, 250, 0, 1000, 0, 0.150, 4000, 10000, false),
  ('Tikrit', 'تكريت',
   st_geogfromtext('POLYGON((43.48 34.40, 43.88 34.40, 43.88 34.82, 43.48 34.82, 43.48 34.40))'),
   500, 250, 0, 1000, 0, 0.150, 4000, 10000, false)
on conflict do nothing;


-- -----------------------------------------------------------------------------
-- ٣) الناصرية وحدها تعمل
-- -----------------------------------------------------------------------------
-- **التركيز قرار لا قصور.** مشكلة الدجاجة والبيضة تُحلّ بحيٍّ مكتظ فيه
-- عشرون سائقاً، لا بثماني عشرة محافظة فيها سائق أو اثنان. وراكبٌ في
-- بغداد يطلب فلا يجد أحداً لا يعود أبداً.
update public.pricing_zones
set is_active = (city_name = 'Nasiriyah');


-- -----------------------------------------------------------------------------
-- ٤) تفعيل منطقة من اللوحة
-- -----------------------------------------------------------------------------
-- دالة لا تحديث مباشر: التفعيل قرار له أثر تجاري، فيمرّ بفحص صلاحية
-- ويُسجَّل في سجلّ التدقيق كغيره من الأفعال.
create or replace function public.set_zone_active(p_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_name text;
begin
  if not public.has_perm('settings.manage') then
    raise exception 'لا تملك صلاحية تعديل المناطق'
      using errcode = 'insufficient_privilege';
  end if;

  update public.pricing_zones set is_active = p_active
  where id = p_id
  returning city_name_ar into v_name;

  if v_name is null then
    raise exception 'المنطقة غير موجودة';
  end if;

  perform public.log_action(
    case when p_active then 'zone.enable' else 'zone.disable' end,
    'zone', p_id::text,
    format('%s منطقة %s', case when p_active then 'فعّل' else 'عطّل' end, v_name));
end;
$fn$;

revoke all on function public.set_zone_active from public, anon;
grant execute on function public.set_zone_active(uuid, boolean) to authenticated;


-- اللوحة تحتاج قراءة المناطق. الجدول محميّ بـ RLS منذ 0007، ولا سياسة
-- قراءة عليه للمشرف — فنضيفها هنا بدل أن تعود الصفحة فارغة بلا خطأ.
drop policy if exists "zones: يقرأ المشرف" on public.pricing_zones;
create policy "zones: يقرأ المشرف"
  on public.pricing_zones for select to authenticated
  using (public.is_admin());


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar as "المحافظة",
  case when is_active then 'تعمل' else 'معطّلة' end as "الحالة"
from public.pricing_zones
order by is_active desc, city_name_ar;


-- ##########################################################################
-- ملف: 0031_tuktuk.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0031 — التكتك: نوع مركبة ثانٍ
-- =============================================================================
-- **القاعدة الحاكمة، ومنها يتفرّع كل ما تحتها:**
--
--   الزيادة تتبع **نوع الطلب** لا نوع مركبة السائق.
--
-- سائق تكتك يقبل طلب دراجة يأخذ سعر الدراجة كاملاً بلا زيادة. وهذا عدل
-- لا تقتير: الراكب طلب دراجة ودفع سعرها، وما ركبه بعد ذلك شأن السائق.
-- ولو ربطنا الزيادة بالمركبة لصار الراكب يدفع ٤٥٪ إضافية لأن السائق
-- الأقرب صادف أن يملك تكتكاً — وهو ما يجعله يلغي ويعيد الطلب.
--
-- ولذلك السعر يُجمَّد لحظة الطلب في `fare_locked_iqd` (0028): الراكب رأى
-- رقماً ووافق عليه قبل أن يُعرف من سيأتيه أصلاً.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) النوع
-- -----------------------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from pg_type where typname = 'vehicle_kind') then
    create type public.vehicle_kind as enum ('bike', 'tuktuk');
  end if;
end
$do$;

alter table public.drivers
  add column if not exists vehicle_kind public.vehicle_kind not null default 'bike',

  -- **يخصّ سائق التكتك وحده.** سائق الدراجة لا يستطيع خدمة طلب تكتك
  -- مهما فعل، فالعمود بلا معنى عنده ويبقى على قيمته الافتراضية.
  add column if not exists accepts_bike_trips boolean not null default true;

comment on column public.drivers.accepts_bike_trips is
  'سائق التكتك يقبل طلبات الدراجات أيضاً. بلا أثر على سائق الدراجة.';

alter table public.trips
  add column if not exists vehicle_kind public.vehicle_kind not null default 'bike';

comment on column public.trips.vehicle_kind is
  'ما طلبه الراكب. عليه تُحسب الزيادة، لا على مركبة من جاءه.';

alter table public.pricing_zones
  add column if not exists tuktuk_surcharge_pct smallint not null default 45;


-- -----------------------------------------------------------------------------
-- ٢) التسجيل يلتقط نوع المركبة
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  requested_role public.user_role;
  v_full_name text;
  v_phone     text;
  v_address   text;
  v_dob       date;
  v_age       integer;
  v_kind      public.vehicle_kind;
begin
  requested_role := coalesce(
    nullif(new.raw_user_meta_data ->> 'role', '')::public.user_role, 'rider');

  v_full_name := btrim(new.raw_user_meta_data ->> 'full_name');
  v_phone     := nullif(btrim(new.raw_user_meta_data ->> 'phone'), '');
  v_address   := nullif(btrim(new.raw_user_meta_data ->> 'address'), '');
  v_dob       := (nullif(new.raw_user_meta_data ->> 'date_of_birth', ''))::date;

  if v_full_name is null or v_full_name = '' then
    raise exception 'الاسم الكامل مطلوب للتسجيل';
  end if;

  if array_length(regexp_split_to_array(v_full_name, '\s+'), 1) < 3 then
    raise exception 'الاسم الثلاثي مطلوب: الاسم واسم الأب واسم الجد';
  end if;

  if v_phone is null then
    raise exception 'رقم الهاتف مطلوب للتسجيل';
  end if;

  if v_address is null then
    raise exception 'العنوان مطلوب للتسجيل';
  end if;

  if v_dob is null then
    raise exception 'تاريخ الميلاد مطلوب للتسجيل';
  end if;

  v_age := extract(year from age(current_date, v_dob))::integer;
  if requested_role = 'driver' and v_age < 18 then
    raise exception 'العمر الأدنى لتسجيل السائق ١٨ سنة';
  elsif v_age < 16 then
    raise exception 'العمر الأدنى للتسجيل ١٦ سنة';
  end if;

  if exists (select 1 from public.profiles where phone = v_phone) then
    raise exception 'رقم الهاتف مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;
  if exists (select 1 from public.profiles where full_name = v_full_name) then
    raise exception 'الاسم مسجّل مسبقاً' using errcode = 'unique_violation';
  end if;

  insert into public.profiles (
    id, full_name, email, date_of_birth, address, phone, role, locale
  ) values (
    new.id, v_full_name, new.email, v_dob, v_address, v_phone, requested_role,
    coalesce(nullif(new.raw_user_meta_data ->> 'locale', ''), 'ar')
  );

  if requested_role = 'driver' then
    v_kind := coalesce(
      nullif(new.raw_user_meta_data ->> 'vehicle_kind', '')::public.vehicle_kind,
      'bike');

    insert into public.drivers (
      id, vehicle_type, vehicle_plate, vehicle_color, vehicle_kind
    ) values (
      new.id,
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_type'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_plate'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'vehicle_color'), ''),
      v_kind
    );
  end if;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) البحث يحترم النوع
-- -----------------------------------------------------------------------------
-- **غير المتماثل مقصود:** طلب التكتك لا يصل إلا سائق تكتك، وطلب الدراجة
-- يصل سائقي الدراجات **وسائقي التكتك الذين فتحوا ذلك**. عكسه مستحيل
-- مادياً — لا يستطيع سائق دراجة أن يخدم من طلب تكتكاً.
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname = 'find_nearby_drivers' and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

create or replace function public.find_nearby_drivers(
  p_pickup     geography,
  p_radius_m   integer default 3000,
  p_limit      integer default 10,
  p_exclude    uuid[]  default '{}',
  p_kind       public.vehicle_kind default 'bike'
)
returns table (
  driver_id     uuid,
  distance_m    integer,
  rating_avg    numeric,
  full_name     text,
  vehicle_plate text
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
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
    and (
      case p_kind
        when 'tuktuk' then d.vehicle_kind = 'tuktuk'
        else d.vehicle_kind = 'bike'
             or (d.vehicle_kind = 'tuktuk' and d.accepts_bike_trips)
      end
    )
    and not exists (
      select 1 from public.trips t
      where t.driver_id = d.id
        and t.status in ('accepted', 'driver_arrived', 'in_progress')
    )
  order by st_distance(d.current_location, p_pickup)
  limit p_limit;
$fn$;


-- الإرسال يمرّر نوع الرحلة إلى البحث
create or replace function public.dispatch_next_offer(p_trip_id uuid)
returns public.trip_offers
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip      public.trips;
  v_zone      public.pricing_zones;
  v_tried     uuid[];
  v_sent      integer;
  v_live      integer;
  v_need      integer;
  v_radius    integer;
  v_candidate record;
  v_offer     public.trip_offers;
  v_elapsed   integer;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  v_elapsed := extract(epoch from (now() - v_trip.requested_at))::integer;
  if v_elapsed > v_zone.max_search_seconds then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  select count(*) into v_live
  from public.trip_offers
  where trip_id = p_trip_id and status = 'pending' and expires_at > now();

  v_need := v_zone.max_concurrent_offers - v_live;
  if v_need <= 0 then
    return null;
  end if;

  select coalesce(array_agg(driver_id), array[]::uuid[])
  into v_tried
  from public.trip_offers
  where trip_id = p_trip_id
    and sent_at > now() - make_interval(secs => v_zone.offer_round_seconds);

  select count(*) into v_sent
  from public.trip_offers where trip_id = p_trip_id;

  v_radius := least(
    v_zone.search_radius_m * (1 + (v_sent / 5)),
    v_zone.max_search_radius_m
  );

  for v_candidate in
    select * from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried, v_trip.vehicle_kind
    )
  loop
    insert into public.trip_offers
      (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
    values (
      p_trip_id, v_candidate.driver_id, v_sent + 1, v_candidate.distance_m,
      (v_candidate.distance_m / 6.9)::integer,
      now() + make_interval(secs => v_zone.offer_timeout_s)
    )
    on conflict do nothing
    returning * into v_offer;

    v_sent := v_sent + 1;
  end loop;

  return v_offer;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) التسعير: زيادة التكتك قبل التقريب
-- -----------------------------------------------------------------------------
-- **ترتيب العمليات يهمّ:** الزيادة تُحسب على المجموع قبل التقريب لأقرب
-- ٢٥٠. لو قرّبنا ثم زدنا لتراكم خطأ التقريب مرتين على الرحلة الواحدة.
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname in ('calculate_multi_fare', 'estimate_multi_trip')
      and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

create or replace function public.calculate_multi_fare(
  p_zone_id   uuid,
  p_leg1_m    integer,
  p_leg1_s    integer,
  p_leg2_m    integer default null,
  p_leg2_s    integer default null,
  p_stopover  boolean default false,
  p_surge     numeric default null,
  p_kind      public.vehicle_kind default 'bike'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  z          public.pricing_zones;
  v_first    jsonb;
  v_leg1     numeric;
  v_leg2     numeric := 0;
  v_stop_add numeric := 0;
  v_kind_add numeric := 0;
  v_total    numeric;
  v_comm     numeric;
begin
  select * into z from public.pricing_zones where id = p_zone_id;
  if not found then
    raise exception 'المنطقة غير معروفة';
  end if;

  v_first := public.calculate_fare(p_zone_id, p_leg1_m, p_leg1_s, p_surge);
  v_leg1  := (v_first ->> 'total')::numeric;

  if coalesce(p_leg2_m, 0) > 0 then
    v_leg2 := (p_leg2_m / 1000.0) * z.per_km_iqd
              * (1 - z.second_leg_discount_pct / 100.0);
  end if;

  v_total := v_leg1 + v_leg2;

  if p_stopover then
    v_stop_add := v_total * z.stopover_surcharge_pct / 100.0;
    v_total := v_total + v_stop_add;
  end if;

  if p_kind = 'tuktuk' then
    v_kind_add := v_total * z.tuktuk_surcharge_pct / 100.0;
    v_total := v_total + v_kind_add;
  end if;

  v_total := round(v_total / 250) * 250;
  v_comm  := round(v_total * z.commission_rate, 2);

  return jsonb_build_object(
    'leg1_fare',      round(v_leg1, 2),
    'leg2_fare',      round(v_leg2, 2),
    'stopover_add',   round(v_stop_add, 2),
    'stopover',       p_stopover,
    'stopover_free_minutes', z.stopover_free_minutes,
    'vehicle_kind',   p_kind,
    'tuktuk_add',     round(v_kind_add, 2),
    'tuktuk_pct',     z.tuktuk_surcharge_pct,
    'total',          v_total,
    'commission',     v_comm,
    'driver_earning', v_total - v_comm,
    'surge_multiplier', (v_first ->> 'surge_multiplier')::numeric
  );
end;
$fn$;


create or replace function public.estimate_multi_trip(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_leg1_m     integer,
  p_leg1_s     integer,
  p_leg2_m     integer default null,
  p_leg2_s     integer default null,
  p_stopover   boolean default false,
  p_kind       public.vehicle_kind default 'bike'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_pickup geography;
  v_zone   uuid;
begin
  v_pickup := st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography;
  v_zone   := public.zone_for_point(v_pickup);

  if v_zone is null then
    return jsonb_build_object('available', false,
      'message', 'نقطة الانطلاق خارج نطاق الخدمة');
  end if;

  return public.calculate_multi_fare(
    v_zone, p_leg1_m, p_leg1_s, p_leg2_m, p_leg2_s, p_stopover, null, p_kind
  ) || jsonb_build_object('available', true);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) الطلب يحمل النوع
-- -----------------------------------------------------------------------------
do $do$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
    where proname = 'request_trip' and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end
$do$;

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
  p_note            text default null,
  p_coupon_code     text default null,
  p_stop2_lat       double precision default null,
  p_stop2_lng       double precision default null,
  p_stop2_address   text default null,
  p_leg2_m          integer default null,
  p_leg2_s          integer default null,
  p_stopover        boolean default false,
  p_vehicle_kind    public.vehicle_kind default 'bike'
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_rider    public.profiles;
  v_pickup   geography;
  v_dropoff  geography;
  v_stop2    geography;
  v_zone_id  uuid;
  v_fare     jsonb;
  v_trip     public.trips;
  v_coupon   jsonb;
  v_cid      uuid;
  v_disc     numeric(10,2) := 0;
  v_multi    boolean;
  v_final    geography;
  v_final_ad text;
begin
  select * into v_rider from public.profiles where id = auth.uid();
  if not found or v_rider.is_blocked then
    raise exception 'غير مصرّح لك بطلب رحلة' using errcode = 'insufficient_privilege';
  end if;

  v_pickup  := st_setsrid(st_makepoint(p_pickup_lng,  p_pickup_lat),  4326)::geography;
  v_dropoff := st_setsrid(st_makepoint(p_dropoff_lng, p_dropoff_lat), 4326)::geography;

  v_multi := p_stop2_lat is not null and p_stop2_lng is not null
             and coalesce(p_leg2_m, 0) > 0;
  if v_multi then
    v_stop2 := st_setsrid(st_makepoint(p_stop2_lng, p_stop2_lat), 4326)::geography;
  end if;

  v_zone_id := public.zone_for_point(v_pickup);
  if v_zone_id is null then
    raise exception 'نقطة الانطلاق خارج نطاق الخدمة';
  end if;

  v_fare := public.calculate_multi_fare(
    v_zone_id, p_distance_m, p_duration_s,
    case when v_multi then p_leg2_m else null end,
    case when v_multi then p_leg2_s else null end,
    coalesce(p_stopover, false), null, coalesce(p_vehicle_kind, 'bike')
  );

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    v_coupon := public.check_coupon(p_coupon_code, (v_fare ->> 'total')::numeric);
    v_cid    := (v_coupon ->> 'coupon_id')::uuid;
    v_disc   := (v_coupon ->> 'discount_iqd')::numeric;
  end if;

  v_final    := case when v_multi then v_stop2 else v_dropoff end;
  v_final_ad := case when v_multi then p_stop2_address else p_dropoff_address end;

  begin
    insert into public.trips (
      rider_id, pickup_location, pickup_address,
      dropoff_location, dropoff_address,
      estimated_distance_m, estimated_duration_s,
      fare_estimated_iqd, surge_multiplier, fare_breakdown,
      payment_method, rider_note, coupon_id, discount_iqd,
      stop_count, current_leg, has_stopover, fare_locked_iqd, vehicle_kind
    ) values (
      auth.uid(), v_pickup, p_pickup_address,
      v_final, v_final_ad,
      p_distance_m + coalesce(case when v_multi then p_leg2_m end, 0),
      p_duration_s + coalesce(case when v_multi then p_leg2_s end, 0),
      (v_fare ->> 'total')::numeric,
      (v_fare ->> 'surge_multiplier')::numeric,
      v_fare,
      p_payment_method, p_note, v_cid, v_disc,
      case when v_multi then 2 else 1 end, 1,
      coalesce(p_stopover, false),
      (v_fare ->> 'total')::numeric,
      coalesce(p_vehicle_kind, 'bike')
    )
    returning * into v_trip;
  exception when unique_violation then
    raise exception 'لديك رحلة نشطة بالفعل' using errcode = 'unique_violation';
  end;

  insert into public.trip_stops
    (trip_id, seq, location, address, leg_distance_m, leg_duration_s, leg_fare_iqd)
  values
    (v_trip.id, 1, v_dropoff, p_dropoff_address,
     p_distance_m, p_duration_s, (v_fare ->> 'leg1_fare')::numeric);

  if v_multi then
    insert into public.trip_stops
      (trip_id, seq, location, address, leg_distance_m, leg_duration_s, leg_fare_iqd)
    values
      (v_trip.id, 2, v_stop2, p_stop2_address,
       p_leg2_m, p_leg2_s, (v_fare ->> 'leg2_fare')::numeric);
  end if;

  perform public.dispatch_next_offer(v_trip.id);

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) سائق التكتك يفتح طلبات الدراجات
-- -----------------------------------------------------------------------------
create or replace function public.set_accepts_bike_trips(p_value boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_kind public.vehicle_kind;
begin
  select vehicle_kind into v_kind from public.drivers where id = auth.uid();
  if not found then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  if v_kind <> 'tuktuk' then
    raise exception 'هذا الخيار لسائقي التكتك';
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.drivers set accepts_bike_trips = p_value where id = auth.uid();
  perform set_config('app.bypass_guards', 'off', true);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.find_nearby_drivers(
  geography, integer, integer, uuid[], public.vehicle_kind) from public, anon;
revoke all on function public.dispatch_next_offer(uuid) from public, anon;
revoke all on function public.set_accepts_bike_trips(boolean) from public, anon;

grant execute on function public.calculate_multi_fare(
  uuid, integer, integer, integer, integer, boolean, numeric,
  public.vehicle_kind) to authenticated;
grant execute on function public.estimate_multi_trip(
  double precision, double precision, integer, integer, integer, integer,
  boolean, public.vehicle_kind) to authenticated;
grant execute on function public.request_trip(
  double precision, double precision, double precision, double precision,
  text, text, integer, integer, public.payment_method, text, text,
  double precision, double precision, text, integer, integer, boolean,
  public.vehicle_kind) to authenticated;
grant execute on function public.set_accepts_bike_trips(boolean) to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  d.km || ' كم' as "المسافة",
  (public.calculate_multi_fare(z.id, (d.km*1000)::int, 0, null, null, false,
     null, 'bike') ->> 'total')::numeric   as "دراجة",
  (public.calculate_multi_fare(z.id, (d.km*1000)::int, 0, null, null, false,
     null, 'tuktuk') ->> 'total')::numeric as "تكتك"
from (values (3.0), (5.0), (8.0)) as d(km)
cross join (select id from public.pricing_zones where city_name = 'Nasiriyah') z
order by d.km;


-- ##########################################################################
-- ملف: 0032_fare_boost.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0032 — رفع السعر لتسريع البحث
-- =============================================================================
-- الراكب الذي طال انتظاره يملك خياراً واحداً اليوم: الإلغاء. وهذا خسارة
-- للطرفين — هو لا يصل، ونحن نفقد رحلة كان مستعداً أن يدفع أكثر مقابلها.
--
-- الزر يمنحه خياراً ثالثاً: **يرفع الأجرة ٢٠٪ فيصير الطلب أجذب.**
--
-- **مرة واحدة لكل رحلة.** الراكب المتوتّر يضغط ثلاثاً فيصير السعر ضعفاً،
-- ثم يندم عند الوصول ويرفض الدفع — والدفع نقدي فلا ضمان لنا. مرة واحدة
-- تكفي لتحريك القرار ولا تفتح باب ندمٍ نتحمّله نحن.
-- =============================================================================


alter table public.pricing_zones
  add column if not exists search_boost_pct smallint not null default 20;

comment on column public.pricing_zones.search_boost_pct is
  'كم يرفع الراكب أجرته مرة واحدة لتسريع البحث.';

alter table public.trips
  add column if not exists fare_boost_pct smallint not null default 0,

  -- **لحظة إعادة ضبط الجولة.** `dispatch_next_offer` يستبعد من عُرضت
  -- عليه الرحلة خلال آخر دقيقة. بعد رفع السعر نريد أن يراه **الجميع
  -- الآن** لا بعد انقضاء تلك الدقيقة — فمن دفع أكثر دفع ليصل أسرع.
  add column if not exists offers_reset_at timestamptz;

comment on column public.trips.fare_boost_pct is
  'كم رفع الراكب أجرته. صفر = لم يرفع. يُضبط مرة واحدة.';


-- -----------------------------------------------------------------------------
-- ١) الرفع
-- -----------------------------------------------------------------------------
create or replace function public.boost_trip_fare(p_trip_id uuid)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip public.trips;
  v_zone public.pricing_zones;
  v_new  numeric(10,2);
begin
  select * into v_trip from public.trips
  where id = p_trip_id and rider_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك'
      using errcode = 'insufficient_privilege';
  end if;

  -- **أثناء البحث وحده.** بعد أن يقبل سائق صار السعر عقداً بين طرفين،
  -- ورفعُه حينها هبة لا تسريع.
  if v_trip.status <> 'searching' then
    raise exception 'رفع السعر متاح أثناء البحث عن سائق فقط';
  end if;

  if v_trip.fare_boost_pct > 0 then
    raise exception 'رفعت السعر لهذه الرحلة بالفعل';
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  v_new := round(
    (coalesce(v_trip.fare_locked_iqd, v_trip.fare_estimated_iqd)
       * (1 + v_zone.search_boost_pct / 100.0)) / 250
  ) * 250;

  update public.trips
  set fare_estimated_iqd = v_new,
      -- الأجرة مجمَّدة منذ 0028، فرفعُها يجب أن يمسّ النسختين معاً
      -- وإلا أنهى `complete_trip` الرحلة بالسعر القديم.
      fare_locked_iqd    = v_new,
      fare_boost_pct     = v_zone.search_boost_pct,
      offers_reset_at    = now()
  where id = p_trip_id
  returning * into v_trip;

  -- نُبطل العروض المعلّقة: السائق الذي يقرأ عرضاً الآن يرى السعر القديم،
  -- وقبولُه بذلك السعر يظلمه. العرض التالي يحمل الجديد.
  update public.trip_offers
  set status = 'cancelled', responded_at = now()
  where trip_id = p_trip_id and status = 'pending';

  -- وإرسال فوري بالسعر الجديد بدل انتظار النبضة
  perform public.dispatch_next_offer(p_trip_id);

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الإرسال يحترم إعادة ضبط الجولة
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_next_offer(p_trip_id uuid)
returns public.trip_offers
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip      public.trips;
  v_zone      public.pricing_zones;
  v_tried     uuid[];
  v_sent      integer;
  v_live      integer;
  v_need      integer;
  v_radius    integer;
  v_since     timestamptz;
  v_candidate record;
  v_offer     public.trip_offers;
  v_elapsed   integer;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  v_elapsed := extract(epoch from (now() - v_trip.requested_at))::integer;
  if v_elapsed > v_zone.max_search_seconds then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  select count(*) into v_live
  from public.trip_offers
  where trip_id = p_trip_id and status = 'pending' and expires_at > now();

  v_need := v_zone.max_concurrent_offers - v_live;
  if v_need <= 0 then
    return null;
  end if;

  -- نافذة الجولة: آخر `offer_round_seconds`، **أو منذ رفع السعر إن كان
  -- أحدث**. رفعُ السعر يبدأ جولة جديدة فوراً — من دفع أكثر دفع ليصل
  -- أسرع، لا لينتظر انقضاء دقيقة بدأت قبل أن يدفع.
  v_since := greatest(
    now() - make_interval(secs => v_zone.offer_round_seconds),
    coalesce(v_trip.offers_reset_at, '-infinity'::timestamptz)
  );

  select coalesce(array_agg(driver_id), array[]::uuid[])
  into v_tried
  from public.trip_offers
  where trip_id = p_trip_id and sent_at > v_since;

  select count(*) into v_sent
  from public.trip_offers where trip_id = p_trip_id;

  v_radius := least(
    v_zone.search_radius_m * (1 + (v_sent / 5)),
    v_zone.max_search_radius_m
  );

  for v_candidate in
    select * from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried, v_trip.vehicle_kind
    )
  loop
    insert into public.trip_offers
      (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
    values (
      p_trip_id, v_candidate.driver_id, v_sent + 1, v_candidate.distance_m,
      (v_candidate.distance_m / 6.9)::integer,
      now() + make_interval(secs => v_zone.offer_timeout_s)
    )
    on conflict do nothing
    returning * into v_offer;

    v_sent := v_sent + 1;
  end loop;

  return v_offer;
end;
$fn$;


revoke all on function public.boost_trip_fare from public, anon;
grant execute on function public.boost_trip_fare(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar     as "المنطقة",
  search_boost_pct as "رفع البحث ٪"
from public.pricing_zones
where is_active;


-- ##########################################################################
-- ملف: 0033_boost_priority.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0033 — الطلب المرفوع سعره: أولوية، وعشرة سائقين بدل خمسة
-- =============================================================================
-- رفعُ السعر في 0032 كان يبدأ جولة جديدة فوراً — وهذا نصف ما يستحقه من
-- دفع أكثر. النصف الآخر: **أن يراه سائقون أكثر، وقبل غيره.**
--
-- ثلاثة تغييرات لغرض واحد:
--
--   ١) **عشرة مقاعد بدل خمسة.** ضِعف الفرص في الجولة الواحدة.
--   ٢) **أولوية في العامل الدوري.** الطلبات المرفوعة تُخدَم أولاً حين
--      تتزاحم عدة رحلات على السائقين أنفسهم.
--   ٣) **أولوية في شاشة السائق.** يظهر أول ما يمرّر لا آخره.
--
-- **ولماذا لا نرفع الجميع إلى عشرة؟** لأن العشرة تعني إشعاراً لعشرة
-- سائقين لطلب واحد، وتسعة منهم يفتحون التطبيق ليجدوه ذهب. تكرار ذلك
-- يعلّمهم تجاهل الإشعارات. نحتفظ بالإزعاج للحظة التي يستحقها.
-- =============================================================================


alter table public.pricing_zones
  add column if not exists boosted_concurrent_offers smallint not null default 10;

comment on column public.pricing_zones.boosted_concurrent_offers is
  'كم سائقاً يرى الطلب معاً بعد أن يرفع الراكب سعره. ضِعف العادي.';


-- -----------------------------------------------------------------------------
-- ١) الإرسال: مقاعد أكثر للمرفوع
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_next_offer(p_trip_id uuid)
returns public.trip_offers
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip      public.trips;
  v_zone      public.pricing_zones;
  v_tried     uuid[];
  v_sent      integer;
  v_live      integer;
  v_need      integer;
  v_seats     integer;
  v_radius    integer;
  v_since     timestamptz;
  v_candidate record;
  v_offer     public.trip_offers;
  v_elapsed   integer;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.status <> 'searching' then
    return null;
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  v_elapsed := extract(epoch from (now() - v_trip.requested_at))::integer;
  if v_elapsed > v_zone.max_search_seconds then
    update public.trips set status = 'no_drivers' where id = p_trip_id;
    return null;
  end if;

  select count(*) into v_live
  from public.trip_offers
  where trip_id = p_trip_id and status = 'pending' and expires_at > now();

  -- من رفع سعره يُعرض على ضِعف العدد
  v_seats := case
    when coalesce(v_trip.fare_boost_pct, 0) > 0
      then v_zone.boosted_concurrent_offers
    else v_zone.max_concurrent_offers
  end;

  v_need := v_seats - v_live;
  if v_need <= 0 then
    return null;
  end if;

  v_since := greatest(
    now() - make_interval(secs => v_zone.offer_round_seconds),
    coalesce(v_trip.offers_reset_at, '-infinity'::timestamptz)
  );

  select coalesce(array_agg(driver_id), array[]::uuid[])
  into v_tried
  from public.trip_offers
  where trip_id = p_trip_id and sent_at > v_since;

  select count(*) into v_sent
  from public.trip_offers where trip_id = p_trip_id;

  v_radius := least(
    v_zone.search_radius_m * (1 + (v_sent / 5)),
    v_zone.max_search_radius_m
  );

  for v_candidate in
    select * from public.find_nearby_drivers(
      v_trip.pickup_location, v_radius, v_need, v_tried, v_trip.vehicle_kind
    )
  loop
    insert into public.trip_offers
      (trip_id, driver_id, rank, distance_m, eta_s, expires_at)
    values (
      p_trip_id, v_candidate.driver_id, v_sent + 1, v_candidate.distance_m,
      (v_candidate.distance_m / 6.9)::integer,
      now() + make_interval(secs => v_zone.offer_timeout_s)
    )
    on conflict do nothing
    returning * into v_offer;

    v_sent := v_sent + 1;
  end loop;

  return v_offer;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) العامل الدوري يخدم المرفوع أولاً
-- -----------------------------------------------------------------------------
-- **الترتيب يهمّ حين تتزاحم الرحلات.** رحلتان تبحثان في حيٍّ واحد
-- تتنافسان على السائقين أنفسهم، ومن يُخدَم أولاً يملأ المقاعد أولاً.
-- بلا ترتيب صريح تخدم القاعدة أيّهما صادف — فلا يشتري الرفعُ شيئاً.
create or replace function public.dispatch_tick()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_expired integer := 0;
  v_retried integer := 0;
  v_offline integer := 0;
  v_trip_id uuid;
begin
  with done as (
    update public.trip_offers
    set status = 'expired', responded_at = now()
    where status = 'pending' and expires_at < now()
    returning 1
  )
  select count(*) into v_expired from done;

  -- فصل السائقين الذين انقطع تحديث موقعهم. موقع عمره دقيقتان لا يُعتمد
  -- عليه — أسوأ من لا موقع لأنه يرسل الراكب إلى مكان غادره السائق.
  with gone as (
    update public.drivers
    set status = 'offline'
    where status = 'online'
      and (location_updated_at is null
           or location_updated_at < now() - interval '2 minutes')
    returning 1
  )
  select count(*) into v_offline from gone;

  for v_trip_id in
    select id from public.trips
    where status = 'searching'
    order by fare_boost_pct desc, requested_at
  loop
    perform public.dispatch_next_offer(v_trip_id);
    v_retried := v_retried + 1;
  end loop;

  return jsonb_build_object(
    'expired_offers', v_expired,
    'searching_trips', v_retried,
    'drivers_set_offline', v_offline,
    'at', now()
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar               as "المنطقة",
  max_concurrent_offers      as "عروض عادية",
  boosted_concurrent_offers  as "عروض بعد الرفع",
  search_boost_pct           as "نسبة الرفع ٪"
from public.pricing_zones
where is_active;


-- ##########################################################################
-- ملف: 0034_zone_tuning.sql
-- ##########################################################################

set search_path = public, extensions;

-- =============================================================================
-- 0034 — ضبط أرقام المنطقة من اللوحة
-- =============================================================================
-- أرقام المطابقة والتسعير كلها أعمدة في `pricing_zones` منذ اليوم الأول،
-- وهذا ما جعل كل تغيير سعر أو مهلة سطرَ `update` واحداً بلا إعادة بناء.
--
-- **لكنها بقيت في القاعدة وحدها.** ومن يريد تعديل عدد العروض المتزامنة
-- يفتح محرر SQL ويكتب استعلاماً — وهذا حاجزٌ يجعل الأرقام تبقى على
-- افتراضها لا لأنها صحيحة بل لأن تغييرها متعب.
--
-- الدالة هنا تنقلها إلى اللوحة، ومعها حارس صلاحية وسجلّ تدقيق.
-- =============================================================================

create or replace function public.set_zone_numbers(
  p_id      uuid,
  p_numbers jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_name text;
  v_key  text;
begin
  if not public.has_perm('settings.manage') then
    raise exception 'لا تملك صلاحية تعديل المناطق'
      using errcode = 'insufficient_privilege';
  end if;

  -- **قائمة بيضاء صريحة.** بلا هذا يستطيع من يملك الصلاحية أن يمرّر
  -- اسم أي عمود — ومنها `boundary` أو `is_active` — فيغيّر ما لم تُصمَّم
  -- هذه الدالة لتغييره.
  for v_key in select jsonb_object_keys(p_numbers) loop
    if v_key not in (
      'base_fare_iqd', 'per_km_iqd', 'minimum_fare_iqd', 'commission_rate',
      'search_radius_m', 'max_search_radius_m',
      'offer_timeout_s', 'offer_round_seconds', 'max_search_seconds',
      'max_concurrent_offers', 'boosted_concurrent_offers',
      'search_boost_pct', 'tuktuk_surcharge_pct',
      'second_leg_discount_pct', 'stopover_surcharge_pct',
      'stopover_free_minutes', 'arrival_radius_m',
      'driver_free_cancels_per_day', 'driver_cancel_penalty_iqd',
      'min_wallet_balance_iqd', 'cancellation_fee_iqd'
    ) then
      raise exception 'حقل غير مسموح بتعديله: %', v_key;
    end if;
  end loop;

  update public.pricing_zones z
  set base_fare_iqd    = coalesce((p_numbers->>'base_fare_iqd')::numeric, z.base_fare_iqd),
      per_km_iqd       = coalesce((p_numbers->>'per_km_iqd')::numeric, z.per_km_iqd),
      minimum_fare_iqd = coalesce((p_numbers->>'minimum_fare_iqd')::numeric, z.minimum_fare_iqd),
      commission_rate  = coalesce((p_numbers->>'commission_rate')::numeric, z.commission_rate),
      search_radius_m     = coalesce((p_numbers->>'search_radius_m')::integer, z.search_radius_m),
      max_search_radius_m = coalesce((p_numbers->>'max_search_radius_m')::integer, z.max_search_radius_m),
      offer_timeout_s     = coalesce((p_numbers->>'offer_timeout_s')::integer, z.offer_timeout_s),
      offer_round_seconds = coalesce((p_numbers->>'offer_round_seconds')::integer, z.offer_round_seconds),
      max_search_seconds  = coalesce((p_numbers->>'max_search_seconds')::integer, z.max_search_seconds),
      max_concurrent_offers     = coalesce((p_numbers->>'max_concurrent_offers')::smallint, z.max_concurrent_offers),
      boosted_concurrent_offers = coalesce((p_numbers->>'boosted_concurrent_offers')::smallint, z.boosted_concurrent_offers),
      search_boost_pct     = coalesce((p_numbers->>'search_boost_pct')::smallint, z.search_boost_pct),
      tuktuk_surcharge_pct = coalesce((p_numbers->>'tuktuk_surcharge_pct')::smallint, z.tuktuk_surcharge_pct),
      second_leg_discount_pct = coalesce((p_numbers->>'second_leg_discount_pct')::smallint, z.second_leg_discount_pct),
      stopover_surcharge_pct  = coalesce((p_numbers->>'stopover_surcharge_pct')::smallint, z.stopover_surcharge_pct),
      stopover_free_minutes   = coalesce((p_numbers->>'stopover_free_minutes')::smallint, z.stopover_free_minutes),
      arrival_radius_m        = coalesce((p_numbers->>'arrival_radius_m')::integer, z.arrival_radius_m),
      driver_free_cancels_per_day = coalesce((p_numbers->>'driver_free_cancels_per_day')::smallint, z.driver_free_cancels_per_day),
      driver_cancel_penalty_iqd   = coalesce((p_numbers->>'driver_cancel_penalty_iqd')::numeric, z.driver_cancel_penalty_iqd),
      min_wallet_balance_iqd      = coalesce((p_numbers->>'min_wallet_balance_iqd')::numeric, z.min_wallet_balance_iqd),
      cancellation_fee_iqd        = coalesce((p_numbers->>'cancellation_fee_iqd')::numeric, z.cancellation_fee_iqd)
  where z.id = p_id
  returning z.city_name_ar into v_name;

  if v_name is null then
    raise exception 'المنطقة غير موجودة';
  end if;

  perform public.log_action('zone.tune', 'zone', p_id::text,
    format('عدّل أرقام منطقة %s', v_name));
end;
$fn$;

revoke all on function public.set_zone_numbers from public, anon;
grant execute on function public.set_zone_numbers(uuid, jsonb) to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar              as "المنطقة",
  max_concurrent_offers     as "عروض معاً",
  boosted_concurrent_offers as "بعد الرفع",
  offer_timeout_s           as "مهلة العرض",
  offer_round_seconds       as "العودة بعد"
from public.pricing_zones
where is_active;
