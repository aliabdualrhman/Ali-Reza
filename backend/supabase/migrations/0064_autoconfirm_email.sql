-- =============================================================================
-- 0064 — لا إعداد خارج اللوحة
-- =============================================================================
-- **العائق.** وضع `phone` كان يتطلّب إطفاء «Confirm email» من لوحة
-- Supabase — إعدادٌ في موقعٍ آخر، بحسابٍ آخر، لا يعرفه من يدير المنصة
-- يوماً بعدنا. ومفتاحٌ في لوحتنا يشير إلى مفتاحٍ في لوحة غيرنا ليس
-- تحكّماً بل وعدٌ ناقص.
--
-- **والحل ألا نحتاجه.** GoTrue يمنع الدخول ما دام `email_confirmed_at`
-- فارغاً — فنملؤه نحن لحظة إنشاء الحساب حين يكون الهاتف هو الوضع
-- المفروض. لا إعداد يُطفأ، ولا موقع يُزار.
--
-- **ولماذا لا نُطفئه دائماً؟** لأن وضع `email` يحتاجه: التأكيد هناك هو
-- الحاجز نفسه. فالمُشغّل يقرأ الوضع ويقرّر، ويتبدّل سلوكه بضغطة في
-- لوحتنا.
--
-- ⚠️ **وهذا يلمس `auth.users`** كما فعلنا في 0044 — جدولٌ غير موثّق قد
-- تتغيّر بنيته. مقبولٌ لأننا نكتب عموداً واحداً معروفاً، وفشله لا يمنع
-- التسجيل.

set search_path = public, extensions;


create or replace function public.autoconfirm_when_phone_mode()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, auth
as $fn$
declare
  v_mode text;
begin
  select nullif(btrim(lower(value)), '') into v_mode
  from public.public_settings where key = 'verification_mode';

  -- الافتراضي `email` — فمن لم يضبط شيئاً يبقى على السلوك القديم.
  if coalesce(v_mode, 'email') <> 'phone' then
    return new;
  end if;

  -- **مؤكَّدٌ سلفاً؟ لا نلمسه.** حسابات اللوحة (0044) تُنشأ مؤكَّدة،
  -- والكتابة فوقها تُغيّر تاريخاً صحيحاً بلا سبب.
  if new.email_confirmed_at is not null then
    return new;
  end if;

  update auth.users
  set email_confirmed_at = now()
  where id = new.id;

  return new;
exception when others then
  -- **لا يُسقط التسجيل.** فشلٌ هنا يعني أن المستخدم سيؤكّد بريده كما
  -- كان — وهو إزعاج، لا حرمان من حساب.
  raise warning 'تعذّر تأكيد البريد تلقائياً للحساب %: %', new.id, sqlerrm;
  return new;
end;
$fn$;

drop trigger if exists users_autoconfirm_phone_mode on auth.users;
create trigger users_autoconfirm_phone_mode
  after insert on auth.users
  for each row execute function public.autoconfirm_when_phone_mode();


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select value from public.public_settings where key = 'verification_mode')
    as "الوضع",
  (select count(*) from pg_trigger where tgname = 'users_autoconfirm_phone_mode')
    as "المُشغّل مركَّب";
