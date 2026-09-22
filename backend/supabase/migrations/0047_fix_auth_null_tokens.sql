-- =============================================================================
-- 0047 — حسابات اللوحة تُنشأ فترفض الدخول
-- =============================================================================
-- **العطل.** حساب أنشأه المدير بـ0044 يُنشأ بنجاح، ثم كل محاولة دخول به
-- ترتدّ بخطأ ٥٠٠ يعرضه التطبيق «تعذّر إتمام العملية».
--
-- **والسبب ليس في كلمة المرور ولا في الهوية.** في `auth.users` أعمدة
-- رموز نصّية — `confirmation_token` و`recovery_token` وأخواتها. GoTrue
-- حين يسجّل مستخدماً يضعها **سلسلة فارغة**، ونحن حين أدرجنا الصفّ بأنفسنا
-- تركناها `NULL`.
--
-- وGoTrue مكتوب بلغة Go، وقارئه يعلن نوع هذه الحقول `string` لا
-- `*string`، فلا يقبل `NULL`:
--
--     Scan error on column "confirmation_token":
--     converting NULL to string is unsupported
--
-- **فالعطل في فرقٍ بين فراغين** — فراغ القاعدة وفراغ اللغة.
--
-- ولهذا لا يظهر إلا عند الدخول: الإدراج نجح، والقراءة هي التي تنكسر.
--
-- نصلح الأمرين: الصفوف المعطوبة الآن، والدالة كي لا تُنتج معطوباً بعدها.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) إصلاح الحسابات المُنشأة سلفاً
-- -----------------------------------------------------------------------------
-- **`coalesce` لا `= ''` مطلقاً.** حسابٌ ينتظر رمز استعادة فعلاً يحمل
-- رمزاً حقيقياً في `recovery_token`؛ مسحُه يُبطل رابطاً أرسله صاحبه
-- قبل دقيقة. نملأ الفارغ ولا نمسّ المملوء.
update auth.users
set confirmation_token       = coalesce(confirmation_token,       ''),
    recovery_token           = coalesce(recovery_token,           ''),
    email_change             = coalesce(email_change,             ''),
    email_change_token_new   = coalesce(email_change_token_new,   ''),
    email_change_token_current = coalesce(email_change_token_current, ''),
    phone_change             = coalesce(phone_change,             ''),
    phone_change_token       = coalesce(phone_change_token,       ''),
    reauthentication_token   = coalesce(reauthentication_token,   '')
where confirmation_token         is null
   or recovery_token             is null
   or email_change               is null
   or email_change_token_new     is null
   or email_change_token_current is null
   or phone_change               is null
   or phone_change_token         is null
   or reauthentication_token     is null;


-- -----------------------------------------------------------------------------
-- ٢) الدالة تملأ الرموز عند الإنشاء
-- -----------------------------------------------------------------------------
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

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    -- **الرموز فارغةً لا معدومة** — وهذا كل الفرق بين حساب يدخل وحساب
    -- يُرفض. انظر رأس الملف.
    confirmation_token, recovery_token,
    email_change, email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
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
    ),
    '', '', '', '', '', '', '', ''
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

revoke all on function
  public.admin_create_account(text, text, text, text, text, date, text)
  from public, anon;
grant execute on function
  public.admin_create_account(text, text, text, text, text, date, text)
  to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — يجب أن يكون العدد صفراً
-- -----------------------------------------------------------------------------
select count(*) as "حسابات ما زالت معطوبة"
from auth.users
where confirmation_token is null
   or recovery_token     is null
   or email_change       is null;
