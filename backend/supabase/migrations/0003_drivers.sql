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
