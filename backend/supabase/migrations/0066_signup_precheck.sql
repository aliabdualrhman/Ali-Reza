-- =============================================================================
-- 0066 — نفحص قبل التسجيل لا بعده
-- =============================================================================
-- **افتراضٌ كان خاطئاً.** بنينا في 0065 مُشغّلاً يرمي أخطاءً عربية
-- واضحة، ظنّاً أنها تصل التطبيق. وهي لا تصل: GoTrue **يستبدل** نصّ خطأ
-- القاعدة كلياً ويردّ سطراً واحداً لكل سبب:
--
--     Database error saving new user
--
-- فيبقى المستخدم أمام رسالةٍ تخمينية مهما أتقنّا صياغة الخطأ في
-- القاعدة. والطريق الوحيد أن نسأل قبل أن نُسجّل.
--
-- **وهذا يكشف وجود حساب برقمٍ أو اسم.** وهو ثمنٌ مقبول: الاسم الثلاثي
-- والهاتف يُعرفان بالسؤال في مدينةٍ صغيرة، والبديل أن يقف رجلٌ أمام
-- شاشةٍ لا تخبره لماذا رُفض فيترك التطبيق. ولا نكشف البريد إلا بما
-- يكشفه أيّ نظامٍ عند «استعادة كلمة المرور».
--
-- ولا نُعيد أسماء أصحاب الحسابات ولا أرقامهم — بل نعم/لا فحسب.

set search_path = public, extensions;


create or replace function public.check_signup_conflicts(
  p_full_name text,
  p_phone     text,
  p_email     text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_name  text := regexp_replace(btrim(coalesce(p_full_name, '')), '\s+', ' ', 'g');
  v_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_phone text;
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  -- **نوحّد الرقم كما توحّده القاعدة حرفياً.** لو اختلف المنطقان لقال
  -- الفحص «سليم» ثم رفض الإدراج — وهو أسوأ من ألا نفحص.
  if v_digits ~ '^07[3-9][0-9]{8}$' then
    v_phone := '+964' || substring(v_digits from 2);
  elsif v_digits ~ '^9647[3-9][0-9]{8}$' then
    v_phone := '+' || v_digits;
  elsif v_digits ~ '^7[3-9][0-9]{8}$' then
    v_phone := '+964' || v_digits;
  else
    v_phone := null;
  end if;

  return jsonb_build_object(
    'phone_invalid', v_phone is null,
    'name_short',
      array_length(regexp_split_to_array(v_name, '\s+'), 1) < 3,
    'name_taken',
      exists (select 1 from public.profiles where full_name = v_name),
    'phone_taken',
      v_phone is not null
      and exists (select 1 from public.profiles where phone = v_phone),
    'email_taken',
      exists (select 1 from public.profiles where email = v_email)
  );
end;
$fn$;


-- **`anon` تحتاجها.** الفحص يجري قبل أن يوجد حساب، فلا جلسة بعد.
revoke all on function public.check_signup_conflicts(text, text, text)
  from public;
grant execute on function public.check_signup_conflicts(text, text, text)
  to anon, authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — بدّل القيم ببيانات التسجيل التي تفشل
-- -----------------------------------------------------------------------------
select public.check_signup_conflicts(
  'علي رضا علي',
  '07801711922',
  'ali.alkawary22@gmail.com'
) as "ما الذي يمنع التسجيل";
