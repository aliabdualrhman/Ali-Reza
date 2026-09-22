-- =============================================================================
-- 0109 — إنشاء حساب موظف ببريدٍ وكلمة مرور
-- =============================================================================
-- رصد علي: «عند إضافة موظف أكتب له البريد وكلمة المرور — ولا يوجد حقل
-- كلمة مرور، فكيف يدخل؟»
--
-- وهو محقّ: `set_staff` تمنح الصلاحيات **لحسابٍ موجود أصلاً**، ولا تُنشئ
-- حساباً. فكان على الموظف أن يسجّل في تطبيق الراكب أولاً بهاتفٍ وعنوانٍ
-- وتاريخ ميلاد — ثم يُرفَّع مشرفاً. طريقٌ ملتوٍ لمن كل عمله لوحةُ ويب.
--
-- فدالةٌ واحدة تُنشئ الحساب وتمنح الصلاحيات معاً.
--
-- **للمالك وحده.** من يُنشئ موظفين يستطيع أن يُنشئ لنفسه حساباً بكل
-- صلاحية — فهي كـ`set_staff` تماماً: بيد صاحب المشروع لا غير.
--
-- **والهاتف والاسم الثلاثي مطلوبان.** جرّبتُ إسقاطهما فوجدتُ أن مُشغّل
-- `handle_new_user` يفحصهما قبل أن ينظر إلى الدور، وأن `profiles` لا
-- تقبلهما فارغين. وتعطيلُ الفحص لحساب موظفٍ يفتح ثغرةً في مسار التسجيل
-- كلّه — فالأسلم أن نعطيه ما يطلب. والعنوان وتاريخ الميلاد يُملآن قيمةً
-- إدارية، فهما بلا معنى لموظف مكتب.

set search_path = public, extensions;


create or replace function public.admin_create_staff(
  p_email       text,
  p_password    text,
  p_full_name   text,
  p_phone       text,
  p_permissions text[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_id    uuid := gen_random_uuid();
  v_email text := lower(btrim(p_email));
  v_phone text;
  v_bad   text[];
begin
  if not public.is_owner() then
    raise exception 'إنشاء الموظفين للمالك وحده'
      using errcode = 'insufficient_privilege';
  end if;

  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'صيغة البريد غير صحيحة';
  end if;
  if length(coalesce(p_password, '')) < 8 then
    raise exception 'كلمة المرور ٨ أحرف على الأقل';
  end if;
  if array_length(regexp_split_to_array(btrim(coalesce(p_full_name, '')),
                                        '\s+'), 1) < 3 then
    raise exception 'الاسم ثلاثيّ: الاسم واسم الأب واسم الجد';
  end if;

  -- توحيد صيغة الرقم: 07…، و00964…، و+964… كلّها إلى +9647XXXXXXXX
  v_phone := regexp_replace(btrim(coalesce(p_phone, '')), '[^0-9+]', '', 'g');
  v_phone := case
    when v_phone ~ '^00964' then '+' || substring(v_phone from 3)
    when v_phone ~ '^\+964'  then v_phone
    when v_phone ~ '^964'    then '+' || v_phone
    when v_phone ~ '^0'      then '+964' || substring(v_phone from 2)
    when v_phone ~ '^7'      then '+964' || v_phone
    else v_phone
  end;
  if v_phone !~ '^\+9647[3-9][0-9]{8}$' then
    raise exception 'رقم الهاتف غير صحيح. اكتبه هكذا: 07701234567';
  end if;

  -- **صلاحيةٌ غير معروفة تُرفض.** خطأٌ مطبعيّ في رمزٍ يعني موظفاً يظنّ
  -- أنه يملك صلاحيةً وهي لا تُفحص في مكان.
  select array_agg(c) into v_bad
  from unnest(coalesce(p_permissions, '{}')) c
  where c not in (select code from public.permission_catalog);
  if v_bad is not null then
    raise exception 'صلاحيات غير معروفة: %', array_to_string(v_bad, ', ');
  end if;

  if exists (select 1 from auth.users where email = v_email) then
    raise exception 'هذا البريد مسجَّل بالفعل — امنحه الصلاحيات من القائمة';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    -- **الرموز فارغةً لا معدومة** — وهذا كل الفرق بين حساب يدخل وحساب
    -- يُرفض عند تسجيل الدخول.
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
      -- **مشرفاً من أول لحظة.** لو أُنشئ راكباً ثم رُفِّع لاعترضه فحص
      -- تفرّد الاسم في `validate_signup_fields` — وهو يستثني المشرفين.
      'role',          'admin',
      'full_name',     btrim(p_full_name),
      'phone',         v_phone,
      'address',       'إدارة زنبور',
      'date_of_birth', '1990-01-01',
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

  -- الصلاحيات بعد إنشاء الملف — مُشغّل التسجيل أنشأه مشرفاً بلا صلاحية.
  update public.profiles
  set staff_permissions = coalesce(p_permissions, '{}')
  where id = v_id;

  perform public.log_action(
    'staff.create', 'profiles', v_id::text,
    format('أنشأ موظفاً: %s — %s صلاحية',
           v_email, coalesce(array_length(p_permissions, 1), 0))
  );

  return v_id;
end;
$fn$;

revoke all on function public.admin_create_staff(text, text, text, text, text[])
  from public, anon;
grant execute on function public.admin_create_staff(text, text, text, text, text[])
  to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select count(*) as "دالة إنشاء الموظف (١)"
from pg_proc
where pronamespace = 'public'::regnamespace and proname = 'admin_create_staff';
