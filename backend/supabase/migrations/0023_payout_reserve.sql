set search_path = public, extensions;

-- =============================================================================
-- 0023 — رصيد محجوز لا يُسحب
-- =============================================================================
-- **القاعدة السابقة كانت تحرس الرقم الخطأ.** كتبنا في 0022 أن مبلغ السحب
-- يجب أن يتجاوز خمسة آلاف، فحرسنا **حجم السحبة** لا **ما يبقى بعدها**.
-- والنتيجة أن سائقاً رصيده ٢٠٬٠٠٠ يسحبها كلها ويصفّر حسابه في لحظة.
--
-- **لماذا يهمّنا أن يبقى شيء؟** لأن العمولة تُقيَّد ديناً بعد كل رحلة،
-- والسائق الذي صفّر رصيده يبدأ الرحلة التالية من الصفر فيصير مديناً
-- فوراً، ويبلغ حدّ الدين (٣٬٠٠٠) بعد رحلتين فيتوقف عن العمل. الرصيد
-- المحجوز وسادةٌ تُبقيه يعمل بلا انقطاع.
--
-- الجديد: **يُحجز خمسة آلاف دائماً، ويُسحب ما فوقها.** سائق رصيده ٧٬٥٠٠
-- يسحب ٢٬٥٠٠ لا أكثر.
--
-- ولاحظ أن الشرط انقلب: لم نعد نمنع السحبة الصغيرة — سائق رصيده ٥٬٦٠٠
-- يسحب ٦٠٠ وهو حقّه، والقاعدة القديمة كانت تمنعه لأن ٦٠٠ أقل من ٥٬٠٠٠.
-- =============================================================================

-- الاسم يقول الآن ما تعنيه الدالة فعلاً: رصيد محجوز، لا حدّ أدنى لسحبة.
drop function if exists public.min_payout_iqd();

create or replace function public.payout_reserve_iqd()
returns numeric language sql immutable as $fn$ select 5000::numeric $fn$;

comment on function public.payout_reserve_iqd is
  'ما يجب أن يبقى في محفظة السائق بعد أي سحب.';


create or replace function public.request_payout(p_amount numeric)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_balance   numeric(12,2);
  v_pending   numeric(12,2);
  v_available numeric(12,2);
  v_phone     text;
  v_row       public.payout_requests;
begin
  select d.wallet_balance_iqd, p.phone
  into v_balance, v_phone
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

  -- الطلبات المعلّقة محجوزة هي الأخرى: بدون طرحها يطلب السائق سحب
  -- رصيده مرتين قبل أن ندفع له الأولى.
  select coalesce(sum(amount_iqd), 0) into v_pending
  from public.payout_requests
  where driver_id = auth.uid() and status = 'pending';

  v_available := v_balance - v_pending - public.payout_reserve_iqd();

  if v_available <= 0 then
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

  insert into public.payout_requests (driver_id, amount_iqd, zain_phone)
  values (auth.uid(), p_amount, v_phone)
  returning * into v_row;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- حارس ثانٍ عند الدفع
-- -----------------------------------------------------------------------------
-- **لماذا نفحص مرتين؟** لأن بين الطلب والدفع وقتاً قد تتغيّر فيه المحفظة:
-- عمولات رحلات جديدة تنقصها. الطلب صحيح يوم كُتب وقد يصير خاطئاً يوم
-- يُدفع، فيصفّر الدفعُ رصيداً لم يعد يحتمل.
create or replace function public.mark_payout_paid(p_id uuid, p_note text default null)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row     public.payout_requests;
  v_balance numeric(12,2);
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests where id = p_id for update;
  if not found then
    raise exception 'الطلب غير موجود';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'هذا الطلب مُعالج بالفعل';
  end if;

  select wallet_balance_iqd into v_balance
  from public.drivers where id = v_row.driver_id;

  if v_balance - v_row.amount_iqd < public.payout_reserve_iqd() then
    raise exception
      'رصيد السائق تغيّر منذ الطلب: % دينار. الدفع يُبقي أقل من % المطلوب حجزها',
      v_balance::bigint, public.payout_reserve_iqd()::bigint;
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'payout',
    p_amount_iqd  => -v_row.amount_iqd,
    p_description => 'سحب إلى زين كاش',
    p_created_by  => auth.uid()
  );

  update public.payout_requests
  set status = 'paid', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;


revoke all on function public.request_payout   from public, anon;
revoke all on function public.mark_payout_paid from public, anon;
grant execute on function public.request_payout(numeric)      to authenticated;
grant execute on function public.mark_payout_paid(uuid, text) to authenticated;
grant execute on function public.payout_reserve_iqd()         to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select public.payout_reserve_iqd() as "الرصيد المحجوز";
