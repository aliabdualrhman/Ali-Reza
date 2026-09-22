-- =============================================================================
-- 0063 — أيّهما إجباري: الهاتف أم البريد؟
-- =============================================================================
-- **مفتاحٌ واحد يقلب الشرط**، لا شرطان يتنازعان:
--
--   `phone` → توثيق الهاتف إجباري عند التسجيل، والبريد اختياريّ يؤكَّد
--             لاحقاً من إعدادات التطبيق.
--
--   `email` → تأكيد البريد إجباري، والهاتف اختياريّ يؤكَّد لاحقاً.
--
-- **ولماذا واحدٌ لا اثنان؟** لأن فرضهما معاً يعني حاجزين قبل أول رحلة،
-- وكلُّ حاجزٍ يفقدنا جزءاً من الناس. وواحدٌ يكفي لإثبات أن خلف الحساب
-- إنساناً.
--
-- **ولماذا في اللوحة لا في الكود؟** لأن التوثيق يمرّ بطرفٍ ثالث: رصيد
-- OTPIQ ينفد، أو خدمته تتوقف، أو الشبكة تحجبها. وشرطٌ مثبّتٌ في الكود
-- يجعل عطلاً عند غيرنا **يُقفل التطبيق على كل مستخدم جديد** — ولا فتح
-- إلا ببناءٍ ونشرٍ ومراجعةِ متجر تستغرق يوماً.
--
-- والمفتاح يجعل الإطفاء ثانيةً.
--
-- ⚠️ **وشرطٌ في لوحة Supabase لا يُغني عنه هذا الملف:** وضع `phone`
-- يتطلب إطفاء «Confirm email» من إعدادات المصادقة، وإلا منع GoTrue
-- الدخول حتى يؤكَّد البريد — فيصير الاثنان إجباريين رغم إعدادنا.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) المفتاح
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('verification_mode', 'email',
   'التوثيق الإجباري: phone (هاتف) أو email (بريد)')
on conflict (key) do nothing;

-- **الافتراضي `email`** — وهو ما يعمل اليوم. تغييرُ السلوك بمجرّد تطبيق
-- ترحيلٍ يفاجئ المستخدمين بحاجزٍ لم يُختبر بعد.


-- -----------------------------------------------------------------------------
-- ٢) قراءةٌ واحدة يقرؤها التطبيقان
-- -----------------------------------------------------------------------------
create or replace function public.verification_policy()
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select jsonb_build_object(
    'mode',
      coalesce(
        (select nullif(btrim(lower(value)), '')
         from public.public_settings where key = 'verification_mode'),
        'email'),

    -- **الهاتف قد يُطفأ استقلالاً عن الوضع.** رصيدٌ نفد ليلاً يجب أن
    -- يُوقف الطلب فوراً حتى لو بقي الوضع `phone` — فلا يقف مستخدمٌ أمام
    -- شاشةٍ لا يصلها رمز.
    'otp_enabled',
      coalesce(
        (select lower(btrim(value)) in ('1','true','yes','on')
         from public.public_settings where key = 'otp_enabled'),
        true)
  );
$fn$;

revoke all on function public.verification_policy() from public, anon;
grant execute on function public.verification_policy() to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) حالة توثيقي
-- -----------------------------------------------------------------------------
-- **يجمع الطرفين في نداءٍ واحد.** الموجّه يقرأه عند كل انتقال، ونداءان
-- يعنيان تأخّراً مرئياً في كل ضغطة.
create or replace function public.my_verification()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, auth
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_phone boolean;
  v_mail  timestamptz;
begin
  if v_uid is null then
    return jsonb_build_object('phone', false, 'email', false);
  end if;

  select phone_verified into v_phone from public.profiles where id = v_uid;
  select email_confirmed_at into v_mail from auth.users where id = v_uid;

  return public.verification_policy() || jsonb_build_object(
    'phone', coalesce(v_phone, false),
    'email', v_mail is not null
  );
end;
$fn$;

revoke all on function public.my_verification() from public, anon;
grant execute on function public.my_verification() to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  value as "الوضع الحالي",
  (select value from public.public_settings where key = 'otp_enabled')
        as "الهاتف مفعَّل"
from public.public_settings
where key = 'verification_mode';
