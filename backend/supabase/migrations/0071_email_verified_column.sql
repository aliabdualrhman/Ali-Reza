-- =============================================================================
-- 0071 — «بريدك مؤكَّد» كانت تكذب
-- =============================================================================
-- **خلطتُ شيئين في عمودٍ واحد.** في وضع الهاتف يضع مُشغّل `0064` قيمةً
-- في `auth.users.email_confirmed_at` لحظة الإنشاء، لأن GoTrue يرفض
-- الدخول ما دام البريد غير مؤكَّد — ولولا ذلك لما حصل المستخدم على
-- جلسة، ولما استطاع طلب رمز الواتساب أصلاً (`request_phone_code` تعمل
-- بـ`auth.uid()`).
--
-- فصار العمود يحمل معنيين لا يجتمعان:
--
--   • **إذن الدخول** — تقنيّ، يخصّ GoTrue وحده.
--   • **هل أكّد الرجل بريده فعلاً؟** — حقيقةٌ عن المستخدم.
--
-- و`my_verification` تقرأ الأول وتعرضه على أنه الثاني. فيرى من وثّق
-- هاتفه للتوّ أن بريده «مؤكَّد» وهو لم يفتحه — وهذا كذبٌ في وجهه.
--
-- **فنفصلهما.** عمودٌ مستقلّ كما لـ`phone_verified`، ولا نلمس
-- `email_confirmed_at` إطلاقاً: العبث به يقفل الحساب.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) العمود
-- -----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists email_verified boolean not null default false;

comment on column public.profiles.email_verified is
  'أكّد صاحبه بريده برمزٍ فعلاً. غير email_confirmed_at الذي يمنحه '
  'مُشغّل 0064 آلياً في وضع الهاتف ليُسمح بالدخول.';


-- -----------------------------------------------------------------------------
-- ٢) الترحيل التاريخي
-- -----------------------------------------------------------------------------
-- **من أكّد قبل 0064 أكّد حقاً.** المُشغّل بدأ عمله في ٢٠٢٦-٠٩-٠٦، وكل
-- بريدٍ مؤكَّد قبل ذلك التاريخ مرّ برسالةٍ فتحها صاحبه. أما بعده فلا
-- نستطيع التمييز — فنتركه `false`، وهو الأصحّ: أن نطلب توثيقاً تمّ
-- أهونُ من أن نمنح توثيقاً لم يتمّ.
update public.profiles p
set email_verified = true
where p.email_verified = false
  and p.created_at < timestamptz '2026-09-06 00:00:00+03'
  and exists (
    select 1 from auth.users u
    where u.id = p.id and u.email_confirmed_at is not null
  );


-- -----------------------------------------------------------------------------
-- ٣) القراءة تقول الحقيقة
-- -----------------------------------------------------------------------------
create or replace function public.my_verification()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_phone boolean;
  v_mail  boolean;
begin
  if v_uid is null then
    return jsonb_build_object('phone', false, 'email', false);
  end if;

  select phone_verified, email_verified
    into v_phone, v_mail
  from public.profiles where id = v_uid;

  return public.verification_policy() || jsonb_build_object(
    'phone', coalesce(v_phone, false),
    'email', coalesce(v_mail, false)
  );
end;
$fn$;

revoke all on function public.my_verification() from public, anon;
grant execute on function public.my_verification() to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) تثبيت التوثيق بعد نجاح رمز البريد
-- -----------------------------------------------------------------------------
-- **يُنادى بعد أن يتحقّق GoTrue من الرمز**، لا قبله. فالتحقّق الحقيقي
-- يقع عنده: `verifyOTP` لا تنجح إلا لمن يملك صندوق البريد.
--
-- **وحدّ ما تستطيعه هذه الدالة إن أُسيء استعمالها:** أن يرفع صاحب
-- الحساب شارةً على بريد حسابه هو. ولا تفتح باباً: استعادة كلمة المرور
-- تذهب إلى بريد الحساب المسجَّل دائماً، رفع الشارة أم لم تُرفع. ولذلك
-- قبلنا أن يكون الحارس عند GoTrue لا هنا — ولو كان الأثر أخطر لبنينا
-- جدول رموزٍ خاصاً بنا كما في الهاتف.
create or replace function public.mark_email_verified()
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.profiles set email_verified = true where id = v_uid;
  perform set_config('app.bypass_guards', 'off', true);

  return true;
end;
$fn$;

revoke all on function public.mark_email_verified() from public, anon;
grant execute on function public.mark_email_verified() to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) ومن أكّد بريده وقت التسجيل في وضع البريد يُرفع له العمود
-- -----------------------------------------------------------------------------
-- **وإلا لظهر «بريدك غير مؤكَّد» لمن أكّده قبل دقيقة.** في وضع البريد
-- لا يحصل على جلسة إلا بعد أن يفتح الرسالة فعلاً، فتأكيد GoTrue هنا
-- دليلٌ كافٍ.
create or replace function public.sync_email_verified()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.email_confirmed_at is not null
     and (old.email_confirmed_at is null)
     and public.verification_policy() ->> 'mode' = 'email' then
    perform set_config('app.bypass_guards', 'on', true);
    update public.profiles set email_verified = true where id = new.id;
    perform set_config('app.bypass_guards', 'off', true);
  end if;
  return new;
end;
$fn$;

drop trigger if exists users_sync_email_verified on auth.users;
create trigger users_sync_email_verified
  after update of email_confirmed_at on auth.users
  for each row execute function public.sync_email_verified();


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  count(*) filter (where email_verified)     as "بريد موثَّق",
  count(*) filter (where not email_verified) as "بريد غير موثَّق",
  count(*) filter (where phone_verified)     as "هاتف موثَّق"
from public.profiles
where deleted_at is null;
