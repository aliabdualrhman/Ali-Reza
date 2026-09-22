-- =============================================================================
-- 0081 — المدير يفكّ حارس إلغاء التسوّق
-- =============================================================================
-- **كتبتُ في 0077 أن «المدير وحده يفكّه» ثم لم أكتب ذلك في الكود.**
-- فالحارس يمنع الجميع بلا استثناء، ورسالته تقول «تواصل مع الدعم» —
-- والدعم يفتح اللوحة فيُمنع هو أيضاً. بابٌ مغلقٌ على الطرفين، ومكتوبٌ
-- عليه اسم من يملك المفتاح وهو لا يملكه.
--
-- **والمنع في محلّه، والاستثناء كذلك.** الراكب لا يلغي بعد أن يشتري
-- السائق — ذلك سرقةٌ لا انسحاب. لكنّ الحالات تتشعّب: بضاعةٌ فسدت،
-- أو عنوانٌ خاطئ، أو خلافٌ يحكم فيه إنسان. فمن يحكم يجب أن يستطيع
-- أن ينفّذ حكمه.
--
-- **ويبقى الأثر.** الإلغاء يُسجَّل باسم من ألغاه في `audit_log` كما كل
-- فعلٍ إداري، فلا يضيع من ألغى ولا متى.

set search_path = public, extensions;


create or replace function public.guard_shopping_cancel()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.status <> 'cancelled' or old.status = 'cancelled' then
    return new;
  end if;
  if old.kind <> 'shopping' then return new; end if;

  -- **المدير أولاً.** هو المخرج الوحيد من هذا الباب، وقد نسيتُه.
  if public.is_admin() then
    perform public.log_action(
      'shopping.admin_cancel', 'trips', new.id::text,
      format('ألغى المدير طلب تسوّقٍ مشترى — %s دينار بضاعة',
             coalesce(old.goods_actual_iqd, 0)::bigint)
    );
    return new;
  end if;

  -- **المنع يبدأ حين يُنفق السائق مالاً.** قبل ذلك لا أحد خسر شيئاً،
  -- ومن لم يجد سائقاً يجب أن يستطيع الانصراف.
  if old.goods_actual_iqd is not null
     and coalesce(current_setting('app.bypass_guards', true), 'off') <> 'on'
  then
    raise exception
      'اشترى السائق الطلب فعلاً — لا يمكن الإلغاء. تواصل مع الدعم.';
  end if;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select count(*) as "استثناء المدير مثبَّت (يجب ١)"
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname = 'guard_shopping_cancel'
  and prosrc like '%is_admin()%';
