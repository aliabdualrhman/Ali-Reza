-- =============================================================================
-- 0082 — الخدمات تُفتح وتُغلق من اللوحة
-- =============================================================================
-- خدمتان اليوم — نقل الركّاب والتسوّق — وثالثةٌ قادمة. ولا يجوز أن يكون
-- إطلاق واحدةٍ أو إيقافها بناءً ونشراً ومراجعةَ متجرٍ تستغرق يوماً.
--
-- **والإغلاق يُخفي لا يُعطّل.** مفتاحٌ رماديّ في شاشة السائق سؤالٌ بلا
-- جواب: يضغطه فلا يقع شيء، فيظنّ التطبيق معطوباً ويتصل بالدعم. أما
-- الغياب فلا يُسأل عنه — ومكانه رسالةٌ تكتبها أنت: «قريباً» أو «تحت
-- الصيانة» أو ما شئت.
--
-- ------------------------------------------------------------------
-- والحارس في القاعدة لا في الشاشة
-- ------------------------------------------------------------------
-- إخفاء الزرّ ليس منعاً: من يحمل نسخةً قديمة من التطبيق لا يعرف أن
-- الخدمة أُغلقت، ويظلّ يطلب. فالمنع مُشغّلٌ على `trips` يحرس **كل**
-- المداخل — `request_trip` و`request_shopping` وأيّ دالةٍ نكتبها غداً.
--
-- **ولا نلمس `request_trip`.** أعدتُ كتابة `dispatch_next_offer` من
-- الذاكرة أمس فأتلفتُ نصف منطقها؛ والمُشغّل يضيف الحراسة بلا أن يقترب
-- من دالةٍ قائمة.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الإعدادات
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('rides_enabled',       '1', 'تفعيل خدمة نقل الركّاب'),
  ('rides_closed_msg',    'خدمة نقل الركّاب متوقّفة مؤقّتاً.',
                               'رسالة إيقاف نقل الركّاب'),
  ('shopping_closed_msg', 'خدمة التسوّق قريباً.',
                               'رسالة إيقاف التسوّق')
on conflict (key) do nothing;

-- `shopping_enabled` موجودٌ من 0077.


-- -----------------------------------------------------------------------------
-- ٢) ما تقرؤه التطبيقات
-- -----------------------------------------------------------------------------
-- **نداءٌ واحد لا أربعة.** الشاشة تحتاج الحالتين ورسالتيهما معاً، ولو
-- قرأت كل إعدادٍ وحده لأربعة نداءاتٍ في كل فتحة.
create or replace function public.service_status()
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select jsonb_build_object(
    'rides',        public.referral_setting('rides_enabled', 1) <> 0,
    'shopping',     public.referral_setting('shopping_enabled', 1) <> 0,
    'rides_msg',    coalesce(
      (select nullif(btrim(value), '') from public.public_settings
       where key = 'rides_closed_msg'),
      'خدمة نقل الركّاب متوقّفة مؤقّتاً.'),
    'shopping_msg', coalesce(
      (select nullif(btrim(value), '') from public.public_settings
       where key = 'shopping_closed_msg'),
      'خدمة التسوّق قريباً.')
  );
$fn$;

revoke all on function public.service_status() from public;
grant execute on function public.service_status() to anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٣) الحارس
-- -----------------------------------------------------------------------------
create or replace function public.guard_service_open()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_msg text;
begin
  if new.kind = 'shopping' then
    if public.referral_setting('shopping_enabled', 1) = 0 then
      select coalesce(nullif(btrim(value), ''), 'خدمة التسوّق متوقّفة حالياً.')
      into v_msg
      from public.public_settings where key = 'shopping_closed_msg';
      raise exception '%', coalesce(v_msg, 'خدمة التسوّق متوقّفة حالياً.');
    end if;
  else
    if public.referral_setting('rides_enabled', 1) = 0 then
      select coalesce(nullif(btrim(value), ''),
                      'خدمة نقل الركّاب متوقّفة حالياً.')
      into v_msg
      from public.public_settings where key = 'rides_closed_msg';
      raise exception '%', coalesce(v_msg, 'خدمة نقل الركّاب متوقّفة حالياً.');
    end if;
  end if;

  return new;
end;
$fn$;

-- **قبل الإدراج، وأوّلَ المُشغّلات.** الترتيب أبجديّ في بوستغرس،
-- و`0_` تجعله يسبق ما عداه — فلا يُحسب سعرٌ ولا يُوزَّع عرضٌ لطلبٍ
-- مرفوض أصلاً.
drop trigger if exists "0_guard_service_open" on public.trips;
create trigger "0_guard_service_open"
  before insert on public.trips
  for each row execute function public.guard_service_open();


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select public.service_status() as "حالة الخدمات";
