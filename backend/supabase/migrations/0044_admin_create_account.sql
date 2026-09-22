-- =============================================================================
-- 0044 — المدير يُنشئ حسابات من اللوحة
-- =============================================================================
-- **الحاجتان اللتان تولّدت منهما:**
--
--   ١) الاختبار المغلق يشترط اثني عشر مختبِراً يستعملون التطبيق فعلاً.
--      وكل واحد يحتاج حساباً مستقلاً — القيد `trips_one_active_per_rider`
--      يمنع اثني عشر شخصاً من مشاركة حساب واحد: أولهم يطلب والباقون
--      يُرفضون. فيقع المدير بين إحراج طلب التسجيل من كل مختبِر، وبين
--      حساب مشترك يشلّ التجربة.
--
--   ٢) وسائق في موقف الدراجات لا يُحسن التسجيل ولا يملك بريداً. اليوم
--      يُترك، وغداً يذهب إلى منافس. وإنشاء حسابه في دقيقة أمام عينيه
--      يكسبه.
--
-- **لماذا SQL لا Edge Function؟** الطريق الرسمي لإنشاء مستخدم هو
-- `auth.admin.createUser` بمفتاح `service_role` — ومكانه خادم لا لوحة
-- ويب، فمن يفتح اللوحة يستخرج المفتاح ويملك القاعدة كلها. والبديل دالة
-- حافة تحتاج نشراً بأدوات غير مثبّتة على جهاز المطوّر.
--
-- ⚠️ **وهذا يلمس جداول `auth` الداخلية، وهي غير موثّقة رسمياً.** قد
-- تتغيّر بنيتها في تحديث من Supabase فتتعطّل الدالة. مقبول لأداة إدارية
-- تفشل بصوت عالٍ ولا تمسّ مساراً يستعمله المستخدمون — وإن تعطّلت يوماً
-- بقي التسجيل من التطبيق يعمل كما هو.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) صلاحية جديدة
-- -----------------------------------------------------------------------------
-- **أثقل صلاحية في اللوحة** — من يملكها يصنع حسابات بكلمات مرور يعرفها.
-- تُمنح للمالك ولمن يثق به وحده.
create or replace function public.known_permissions()
returns table (code text, label text)
language sql
immutable
as $fn$
  values
    ('drivers.review',  'مراجعة السائقين واعتمادهم'),
    ('drivers.view',    'عرض السائقين وأرصدتهم'),
    ('riders.view',     'عرض الركّاب وبياناتهم'),
    ('profiles.edit',   'تعديل بيانات المستخدمين مباشرةً'),
    ('accounts.create', 'إنشاء حسابات جديدة من اللوحة'),
    ('trips.view',      'عرض الرحلات'),
    ('trips.cancel',    'إلغاء رحلة جارية'),
    ('topups.generate', 'توليد رموز التعبئة'),
    ('topups.view',     'عرض رموز التعبئة'),
    ('payouts.process', 'معالجة طلبات السحب'),
    ('coupons.manage',  'إنشاء الكوبونات وإيقافها'),
    ('settings.manage', 'تعديل الإعدادات العامة')
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) إنشاء حساب
-- -----------------------------------------------------------------------------
-- **البريد مؤكَّد فوراً** (`email_confirmed_at = now()`): حسابٌ ينشئه
-- المدير لا معنى لأن ينتظر صاحبه رمزاً في بريد قد لا يملكه. وهذا هو
-- الفرق الجوهري بين هذا الباب وباب التسجيل العادي.
--
-- **ولا ننشئ صفّ `profiles` بأنفسنا:** مُشغّل `handle_new_user` يلتقط
-- الإدراج ويبنيه من `raw_user_meta_data`، ويفرض القيود نفسها — الاسم
-- الثلاثي وصيغة الهاتف والعمر الأدنى. فمسار واحد للتحقق لا مساران
-- يتباعدان.
--
-- **ولا يقبل `admin`:** المُشغّل يرفضها أصلاً، ونكرّر المنع هنا لتكون
-- الرسالة مفهومة. ترقية مشرف تبقى بيد قاعدة البيانات وحدها.
create or replace function public.admin_create_account(
  p_email         text,
  p_password      text,
  p_full_name     text,
  p_phone         text,
  p_address       text,
  p_date_of_birth date,
  p_role          text default 'rider'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_id    uuid := gen_random_uuid();
  v_email text := lower(btrim(p_email));
begin
  if not public.has_perm('accounts.create') then
    raise exception 'لا تملك صلاحية إنشاء الحسابات'
      using errcode = 'insufficient_privilege';
  end if;

  if p_role not in ('rider', 'driver') then
    raise exception 'الدور يجب أن يكون rider أو driver';
  end if;

  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'صيغة البريد غير صحيحة';
  end if;

  if length(coalesce(p_password, '')) < 8 then
    raise exception 'كلمة المرور ٨ أحرف على الأقل';
  end if;

  if exists (select 1 from auth.users where email = v_email) then
    raise exception 'هذا البريد مسجَّل بالفعل';
  end if;

  -- **الحساب ثم الهوية.** GoTrue يشترط صفّاً في `auth.identities`
  -- ليقبل الدخول بالبريد؛ وحسابٌ بلا هوية يُنشأ بنجاح ثم يرفض كل
  -- محاولة دخول برسالة «بيانات غير صحيحة» — عطلٌ محيّر لا يدلّ على
  -- سببه.
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_id, 'authenticated', 'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object(
      'role',          p_role,
      'full_name',     btrim(p_full_name),
      'phone',         btrim(p_phone),
      'address',       btrim(p_address),
      'date_of_birth', to_char(p_date_of_birth, 'YYYY-MM-DD'),
      'locale',        'ar'
    )
  );

  insert into auth.identities (
    provider_id, user_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) values (
    v_email, v_id,
    jsonb_build_object(
      'sub',            v_id::text,
      'email',          v_email,
      'email_verified', true,
      'phone_verified', false
    ),
    'email', now(), now(), now()
  );

  perform public.log_action(
    'account.create', 'profiles', v_id::text,
    btrim(p_full_name) || ' — ' || p_role || ' — ' || v_email
  );

  return v_id;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function
  public.admin_create_account(text, text, text, text, text, date, text)
  from public, anon;
grant execute on function
  public.admin_create_account(text, text, text, text, text, date, text)
  to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) امنح المالك الصلاحية
-- -----------------------------------------------------------------------------
-- **لا تُمنح لأحد غيره.** موظف يصنع حسابات بكلمات مرور يعرفها يستطيع
-- أن يدخل بها متى شاء — والسجلّ يقول إنه أنشأها لا إنه استعملها.
update public.profiles
set staff_permissions = array(
      select distinct unnest(staff_permissions || array['accounts.create'])
    )
where role = 'admin'
  and lower(email) = 'ali.alkawary@gmail.com'
  and not ('accounts.create' = any(staff_permissions));


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select code as "الصلاحية", label as "الوصف"
from public.known_permissions()
where code in ('accounts.create', 'profiles.edit', 'riders.view');
