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
