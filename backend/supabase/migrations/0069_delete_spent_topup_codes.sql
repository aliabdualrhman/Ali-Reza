-- =============================================================================
-- 0069 — حذف رموز التعبئة المستهلكة والملغاة
-- =============================================================================
-- الجدول يتراكم: كل دفعةٍ تُولَّد تبقى فيه أبداً، فتغرق الرموز الصالحة
-- بين مئاتٍ ماتت. والمشرف يبحث عن رمزٍ ليرسله فيمرّ على ما لا يُرسَل.
--
-- **والمستهلك وحده والملغى وحده.** الرمز الصالح لا يُحذف من هنا: قد
-- يكون في هاتف سائقٍ ينتظر أن يعبّئ به، وحذفه يُسقط رصيده بلا أثرٍ
-- يشرح ما جرى — وهو سرقةٌ صامتة لا تنظيف. من أراد إبطاله فله `is_void`،
-- وهو يبقى مرئياً بحالته حتى يُحذف بعد ذلك.
--
-- **ولماذا دالة لا حذفٌ مباشر؟** سياسة `for all` تسمح للمشرف بالحذف
-- أصلاً، لكن المباشر يمرّ بلا سجلّ. والمال لا يُمسّ بلا أثر: من حذف
-- وكم حذف ومتى.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) حذف رمزٍ واحد
-- -----------------------------------------------------------------------------
create or replace function public.admin_delete_topup_code(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.topup_codes;
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح';
  end if;

  select * into v_row from public.topup_codes where id = p_id;
  if v_row.id is null then
    raise exception 'الرمز غير موجود';
  end if;

  if v_row.redeemed_by is null and not v_row.is_void then
    raise exception 'هذا الرمز ما زال صالحاً. أبطله أولاً ثم احذفه.';
  end if;

  -- **يُسجَّل قبل الحذف لا بعده.** بعده لا يبقى صفٌّ نقرأ منه المبلغ.
  perform public.log_action(
    'topup.delete', 'topup_code', v_row.id::text,
    format('حذف رمز %s بقيمة %s دينار',
           case when v_row.is_void then 'مُلغى' else 'مستهلك' end,
           v_row.amount_iqd::bigint)
  );

  delete from public.topup_codes where id = p_id;
end;
$fn$;

revoke all on function public.admin_delete_topup_code(uuid) from public, anon;
grant execute on function public.admin_delete_topup_code(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- ٢) كنس الميّت كله دفعةً
-- -----------------------------------------------------------------------------
-- **لأن الحذف واحداً واحداً لا يُنجَز.** من عنده أربعمئة رمزٍ مستهلك لن
-- يضغط أربعمئة مرة، فيترك الجدول كما هو ويبقى العطل قائماً.
--
-- ويعيد العدد ليعرف المشرف ما جرى: «حُذف صفر» و«حُذف ثلاثمئة» رسالتان
-- مختلفتان تماماً، والصمت يُخفي أيّهما وقع.
create or replace function public.admin_purge_topup_codes(
  p_used boolean default true,
  p_void boolean default true
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_count integer;
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح';
  end if;

  if not p_used and not p_void then
    return 0;
  end if;

  with gone as (
    delete from public.topup_codes
    where (p_used and redeemed_by is not null)
       or (p_void and is_void)
    returning 1
  )
  select count(*) into v_count from gone;

  if v_count > 0 then
    perform public.log_action(
      'topup.purge', 'topup_code', null,
      format('حذف %s رمزاً (%s)', v_count,
             case
               when p_used and p_void then 'مستهلكة وملغاة'
               when p_used            then 'مستهلكة'
               else                        'ملغاة'
             end)
    );
  end if;

  return v_count;
end;
$fn$;

revoke all on function public.admin_purge_topup_codes(boolean, boolean)
  from public, anon;
grant execute on function public.admin_purge_topup_codes(boolean, boolean)
  to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — كم رمزاً قابلاً للحذف عندك الآن
-- -----------------------------------------------------------------------------
select
  count(*) filter (where redeemed_by is not null) as "مستهلكة",
  count(*) filter (where is_void)                 as "ملغاة",
  count(*) filter (where redeemed_by is null and not is_void) as "صالحة"
from public.topup_codes;
