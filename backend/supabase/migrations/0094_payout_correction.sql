-- =============================================================================
-- 0094 — تصحيح أرصدة السحب المتضرّرة من خلل 0051
-- =============================================================================
-- ⚠️ **يغيّر أرصدة سائقين حقيقية. طبّقه بعد 0093، وبعد أن تراجع القائمة
-- التي أظهرها 0093 في آخره.** إن كان في القائمة ما لا تريد تصحيحه (سائقٌ
-- سوّيت معه يدوياً مثلاً)، فلا تطبّق هذا الملف — أخبر المساعد ليستثنيه.
--
-- **التصحيح واحدٌ للحالتين: خصم المبلغ.**
--   · مدفوع: السائق قبض المال نقداً ولم يُخصم من رصيده قط
--   · مرفوض: أُعيد إليه مبلغٌ لم يُحجز منه أصلاً — أي أُضيف إليه
--
-- ويُعلَّم كل طلبٍ صُحّح (`held = true`)، فتشغيل الملف مرتين لا يخصم مرتين.
-- =============================================================================

set search_path = public, extensions;

do $do$
declare
  r record;
begin
  for r in
    select pr.* from public.payout_requests pr
    where pr.status in ('paid', 'rejected') and not pr.held
    for update
  loop
    perform public.post_wallet_transaction(
      p_driver_id   => r.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => -r.amount_iqd,
      p_description => case r.status
        when 'paid' then 'تسوية: سحبٌ مدفوع لم يُخصم (خلل ٥ أيلول)'
        else 'تسوية: رفضٌ أعاد مبلغاً لم يُحجز (خلل ٥ أيلول)'
      end
    );
    update public.payout_requests set held = true where id = r.id;
  end loop;
end
$do$;

-- يجب أن يكون صفراً
select count(*) as "طلبات ما زالت بلا تصحيح (يجب ٠)"
from public.payout_requests
where status in ('paid', 'rejected') and not held;
