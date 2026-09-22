-- =============================================================================
-- 0093 — حجز طلب السحب عاد: كان ساقطاً منذ 0051
-- =============================================================================
-- **الخلل.** 0026 جعل طلب السحب يحجز المبلغ من رصيد السائق فوراً: الموافقة
-- تُبقيه مخصوماً، والرفض يُعيده. ثم أعاد 0051 (رصيد الهدية) كتابة
-- `request_payout` **من نسخة 0023 الأقدم**، فسقط الحجز. ومنذ ٥ أيلول:
--
--   · الطلب لا يخصم شيئاً
--   · الموافقة لا تخصم شيئاً — **المبلغ لا يختفي من رصيد السائق أبداً**
--   · الرفض يُعيد مبلغاً لم يُحجز — **هديةٌ للسائق بقدر ما طلب**
--
-- اكتشفه علي حين وافق على سحبٍ فبقي الرصيد كما هو.
--
-- **هذا الملف لا يلمس رصيداً إلا المعلّق:** يصلح الدالة، ويحجز الطلبات
-- المعلّقة الآن، ويعرض في آخره قائمة بالطلبات المُعالجة التي تضرّرت.
-- وتصحيحها في 0094 — بعد أن تراجع القائمة.
--
-- **الدرس:** نسخ دالةٍ لتعديلها يكون من **آخر** تعريفٍ لها، لا من أيّ
-- نسخة. 0091 نسخ دالتيه بالبحث عن آخر ملفٍّ يعرّفهما لهذا السبب.
-- =============================================================================

set search_path = public, extensions;


-- **علامةٌ صريحة لا استنتاج.** كان الحجز يُعرف بحركة محفظةٍ بالمبلغ نفسه
-- قرب وقت الطلب؛ والحجز بأثرٍ رجعي أدناه يقع اليوم لا يوم الطلب — فيبدو
-- غير محجوز ويُخصم مرتين في التصحيح (0094). فالعلامة هي الحَكَم من الآن.
alter table public.payout_requests
  add column if not exists held boolean not null default false;


-- -----------------------------------------------------------------------------
-- ١) الطلب يحجز — نسخة 0051 كما هي، وأُعيد إليها الحجز
-- -----------------------------------------------------------------------------
create or replace function public.request_payout(p_amount numeric)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_balance   numeric(12,2);
  v_bonus     numeric(12,2);
  v_available numeric(12,2);
  v_phone     text;
  v_row       public.payout_requests;
begin
  select d.wallet_balance_iqd, d.bonus_balance_iqd, p.phone
  into v_balance, v_bonus, v_phone
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.id = auth.uid()
  for update of d;

  if not found then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'أدخل مبلغاً صحيحاً';
  end if;

  -- **لا نطرح المعلّق.** المعلّق محجوزٌ من الرصيد فعلاً (أدناه)، وطرحه
  -- ثانيةً يخصمه مرتين — كما شرح 0026.
  v_available := v_balance - public.payout_reserve_iqd();

  if v_available <= 0 then
    if v_bonus > 0 then
      raise exception
        'يجب أن يبقى % دينار في رصيدك. ورصيد الهدية (%) يُنفق على '
        'العمولة ولا يُسحب نقداً.',
        public.payout_reserve_iqd()::bigint, v_bonus::bigint;
    end if;
    raise exception 'يجب أن يبقى % دينار في رصيدك. لا يوجد مبلغ متاح للسحب',
      public.payout_reserve_iqd()::bigint;
  end if;

  if p_amount > v_available then
    raise exception 'أقصى ما يمكن سحبه الآن % دينار — يجب أن يبقى % في رصيدك',
      v_available::bigint, public.payout_reserve_iqd()::bigint;
  end if;

  if v_phone is null or v_phone = '' then
    raise exception 'لا يوجد رقم هاتف في حسابك';
  end if;

  insert into public.payout_requests (driver_id, amount_iqd, zain_phone, held)
  values (auth.uid(), p_amount, v_phone, true)
  returning * into v_row;

  -- **الحجز: يخرج من الرصيد فوراً.** الموافقة تُبقيه، والرفض يُعيده
  -- (`reject_payout_request` في 0026).
  perform public.post_wallet_transaction(
    p_driver_id   => auth.uid(),
    p_txn_type    => 'adjustment',
    p_amount_iqd  => -p_amount,
    p_description => 'حجز طلب سحب'
  );

  return v_row;
end;
$fn$;

revoke all on function public.request_payout(numeric) from public, anon;
grant execute on function public.request_payout(numeric) to authenticated;


-- -----------------------------------------------------------------------------
-- ٢) الطلبات المعلّقة الآن تُحجز
-- -----------------------------------------------------------------------------
-- **غير المحجوز = لا حركة حجزٍ بالمبلغ نفسه خلال دقيقتين من الطلب.** الحجز
-- الصحيح يقع في المعاملة نفسها؛ ودقيقتان هامشٌ لا يلتقط غيره.
-- وبعد ٥ أيلول وحده — ما قبله حجزه 0026 بأثر رجعي.
do $do$
declare
  r record;
begin
  for r in
    select pr.* from public.payout_requests pr
    where pr.status = 'pending'
      and pr.requested_at >= '2026-09-05'
      and not exists (
        select 1 from public.wallet_transactions w
        where w.driver_id = pr.driver_id
          and w.description = 'حجز طلب سحب'
          and w.amount_iqd = -pr.amount_iqd
          and w.created_at between pr.requested_at - interval '2 minutes'
                               and pr.requested_at + interval '2 minutes')
  loop
    perform public.post_wallet_transaction(
      p_driver_id   => r.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => -r.amount_iqd,
      p_description => 'حجز طلب سحب'
    );
    update public.payout_requests set held = true where id = r.id;
  end loop;

  -- ما حُجز في وقته (قبل 0051، أو بعده بحركةٍ قرب الطلب) يُعلَّم أيضاً،
  -- فلا يبقى ما يُستنتج.
  update public.payout_requests pr
  set held = true
  where not pr.held
    and (pr.requested_at < '2026-09-05'
         or exists (
           select 1 from public.wallet_transactions w
           where w.driver_id = pr.driver_id
             and w.description = 'حجز طلب سحب'
             and w.amount_iqd = -pr.amount_iqd
             and w.created_at between pr.requested_at - interval '2 minutes'
                                  and pr.requested_at + interval '2 minutes'));
end
$do$;


-- -----------------------------------------------------------------------------
-- ٣) القائمة — الطلبات المُعالجة التي تضرّرت (لا تغيير هنا)
-- -----------------------------------------------------------------------------
-- **كلا الحالتين تصحيحهما واحد: خصم المبلغ.**
--   · مدفوع: دُفع للسائق نقداً ولم يُخصم من رصيده قط
--   · مرفوض: أُعيد إليه مبلغٌ لم يُحجز منه — أي أُضيف إليه
select
  pr.requested_at::date                          as "التاريخ",
  p.full_name                                  as "السائق",
  pr.amount_iqd::bigint                        as "المبلغ",
  case pr.status when 'paid' then 'مدفوع — لم يُخصم'
                 else 'مرفوض — أُضيف له' end   as "ما حدث",
  d.wallet_balance_iqd::bigint                 as "رصيده الآن",
  (d.wallet_balance_iqd - pr.amount_iqd)::bigint as "رصيده بعد التصحيح"
from public.payout_requests pr
join public.drivers  d on d.id = pr.driver_id
join public.profiles p on p.id = pr.driver_id
where pr.status in ('paid', 'rejected')
  and not pr.held
order by pr.requested_at;
