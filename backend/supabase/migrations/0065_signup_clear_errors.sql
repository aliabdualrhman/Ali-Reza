-- =============================================================================
-- 0065 — التسجيل يقول أيّ حقلٍ منع الحساب
-- =============================================================================
-- **العطل.** يملأ المستخدم الشاشة ويضغط، فتردّ:
--
--     تعذّر حفظ بياناتك — تحقّق من صيغة الهاتف والاسم الثلاثي
--
-- وهي رسالتنا نحن، مكتوبةٌ بالحدس لأن الحقيقة لا تصل. القيود في
-- `profiles` تُطلق أخطاءها، لكنّ GoTrue يبتلعها ويردّ نصّاً واحداً لكل
-- سبب: `Database error saving new user`. فيقرأ المستخدم تخميناً بدل
-- سبب، ويعيد المحاولة بنفس الخطأ حتى ييأس.
--
-- **وأسوأها المكرّرات.** `full_name` و`phone` فريدان في `profiles`،
-- و«محمد علي كاظم» اسمٌ يتكرّر في العراق كثيراً. فيُمنع الرجل من
-- التسجيل ويُقال له إن صيغة هاتفه خاطئة — وهاتفه سليم.
--
-- **والحل أن نفحص قبل أن تفحص القيود.** المُشغّل يعرف الحقل بعينه،
-- ورسائله بالعربية تمرّ إلى الشاشة كما هي (`AppError` يمرّر كل نصٍّ
-- عربي). فيرى المستخدم ما يُصلحه لا ما يُحيّره.

set search_path = public, extensions;


create or replace function public.validate_signup_fields()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_name  text := btrim(coalesce(new.full_name, ''));
  v_phone text := btrim(coalesce(new.phone, ''));
begin
  -- **المشرفون خارج الفحص.** حساباتهم تُنشأ من القاعدة لا من شاشة
  -- تسجيل، وقواعدها مختلفة.
  if new.role = 'admin' then return new; end if;

  -- ---- الاسم ----
  if array_length(regexp_split_to_array(v_name, '\s+'), 1) < 3 then
    raise exception 'الاسم يجب أن يكون ثلاثياً — اسمك واسم أبيك وجدّك';
  end if;

  if exists (select 1 from public.profiles
             where full_name = v_name and id <> new.id) then
    raise exception 'هذا الاسم مسجّل بحساب آخر. أضف اسم جدّك أو لقبك.';
  end if;

  -- ---- الهاتف ----
  -- **الصيغة تُفحص هنا وإن فحصها القيد.** لأن رسالة القيد لا تصل
  -- المستخدم، ورسالتنا تصل.
  if v_phone !~ '^\+9647[3-9][0-9]{8}$' then
    raise exception 'رقم الهاتف غير صحيح. اكتبه هكذا: 07701234567';
  end if;

  if exists (select 1 from public.profiles
             where phone = v_phone and id <> new.id) then
    raise exception 'رقم الهاتف مسجّل بحساب آخر. إن كان رقمك فسجّل دخولك.';
  end if;

  -- ---- العنوان ----
  if length(btrim(coalesce(new.address, ''))) < 5 then
    raise exception 'اكتب عنواناً أوضح — خمسة أحرف على الأقل';
  end if;

  return new;
end;
$fn$;


-- **قبل الإدراج وقبل مُشغّلات أخرى.** الترتيب أبجديّ في بوستغرس،
-- و`0_` تجعله أوّل ما يعمل — فيُردّ الخطأ الواضح قبل أن تُطلق القيود
-- خطأها الغامض.
drop trigger if exists "0_validate_signup" on public.profiles;
create trigger "0_validate_signup"
  before insert on public.profiles
  for each row execute function public.validate_signup_fields();


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select tgname as "المُشغّل"
from pg_trigger
where tgrelid = 'public.profiles'::regclass
  and not tgisinternal
order by tgname;
