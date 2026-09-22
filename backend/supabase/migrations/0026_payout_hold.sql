set search_path = public, extensions;

-- =============================================================================
-- 0026 — المبلغ المطلوب سحبه يُحجز فوراً
-- =============================================================================
-- **تصحيح قرار اتخذتُه في 0022 وكان خاطئاً.** كتبتُ حينها أن الخصم يحدث
-- عند إعلان الدفع لا عند الطلب، بحجة أن "الطلب نيّة والدفع فعل".
--
-- والخطأ فيه: السائق الذي طلب سحب ١٠٬٠٠٠ من ٢٠٬٠٠٠ يبقى رصيده ٢٠٬٠٠٠
-- في نظر النظام كله — يعمل به، ويحتسبه ضمن حدّ الدين، وقد ينفقه في
-- عمولات رحلات جديدة. ثم ندفع له العشرة آلاف فيصير رصيده أقل مما يجب،
-- أو سالباً.
--
-- **الصواب: المبلغ يُحجز لحظة الطلب.** يخرج من رصيده العامل ويبقى
-- محجوزاً، فما يراه هو ما يملك فعلاً. وإن أُلغي الطلب أو رُفض عاد إليه
-- كاملاً.
--
-- والفرق ظاهر في كشف الحساب أيضاً، وهذا مقصود: حركة "حجز طلب سحب" يوم
-- الطلب، وحركة "إلغاء طلب سحب" يوم التراجع. السائق يقرأ قصة ماله كاملة
-- بدل أن يجد رقماً تبدّل بلا سبب مكتوب.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) الطلب يحجز
-- -----------------------------------------------------------------------------
create or replace function public.request_payout(p_amount numeric)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_balance   numeric(12,2);
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

  -- **لم نعد نطرح الطلبات المعلّقة هنا.** صارت مخصومة من الرصيد نفسه،
  -- فطرحها ثانيةً يخصمها مرتين. هذا ما يبسّطه الحجز.
  v_available := v_balance - public.payout_reserve_iqd();

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

  -- الحجز: يخرج من الرصيد العامل فوراً
  perform public.post_wallet_transaction(
    p_driver_id   => auth.uid(),
    p_txn_type    => 'payout',
    p_amount_iqd  => -p_amount,
    p_description => 'حجز طلب سحب'
  );

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الإلغاء يعيد المحجوز
-- -----------------------------------------------------------------------------
create or replace function public.cancel_payout_request(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  select * into v_row from public.payout_requests
  where id = p_id and driver_id = auth.uid() and status = 'pending'
  for update;

  if not found then
    raise exception 'الطلب غير موجود أو عُولج بالفعل';
  end if;

  -- الردّ قبل الحذف: لو انهارت المعاملة بينهما ضاع المال بلا أثر.
  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'adjustment',
    p_amount_iqd  => v_row.amount_iqd,
    p_description => 'إلغاء طلب سحب'
  );

  -- الحذف لا التعليم: طلبٌ ألغاه صاحبه لا يعني المدير، ووجوده في لوحته
  -- ضجيج يُخفي الطلبات التي تنتظره فعلاً.
  delete from public.payout_requests where id = p_id;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الرفض يعيد المحجوز كذلك
-- -----------------------------------------------------------------------------
create or replace function public.reject_payout_request(p_id uuid, p_note text)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests
  where id = p_id and status = 'pending'
  for update;

  if not found then
    raise exception 'الطلب غير موجود أو مُعالج بالفعل';
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'adjustment',
    p_amount_iqd  => v_row.amount_iqd,
    p_description => coalesce(nullif(p_note, ''), 'رُفض طلب السحب')
  );

  update public.payout_requests
  set status = 'rejected', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) الدفع صار تعليماً فقط — المال خرج يوم الطلب
-- -----------------------------------------------------------------------------
create or replace function public.mark_payout_paid(p_id uuid, p_note text default null)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
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

  -- **لا خصم هنا بعد اليوم.** المبلغ خرج من رصيد السائق لحظة طلبه،
  -- والخصم مرتين كان سيأكل ضعف ما طلب. ولهذا سقط أيضاً فحص الرصيد
  -- المحجوز الذي كان هنا: الرصيد فُحص يوم الطلب ولا يمكن أن يتغيّر
  -- بهذا الطلب بعده.
  update public.payout_requests
  set status = 'paid', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;


revoke all on function public.request_payout        from public, anon;
revoke all on function public.cancel_payout_request from public, anon;
revoke all on function public.reject_payout_request from public, anon;
revoke all on function public.mark_payout_paid      from public, anon;

grant execute on function public.request_payout(numeric)           to authenticated;
grant execute on function public.cancel_payout_request(uuid)       to authenticated;
grant execute on function public.reject_payout_request(uuid, text) to authenticated;
grant execute on function public.mark_payout_paid(uuid, text)      to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) الطلبات المعلّقة القديمة — تصحيح أثر رجعي
-- -----------------------------------------------------------------------------
-- **طلبات أُنشئت قبل هذا الملف لم تُخصم من الرصيد.** لو تركناها لصارت
-- النماذج مختلطة: بعض الطلبات محجوزة وبعضها لا، ولا شيء في الصف يميّزها.
-- نحجزها الآن بأثر رجعي فيصير الجميع على قاعدة واحدة.
--
-- نتعرّف على غير المحجوز بغياب حركة محفظة تحمل وصف الحجز — لا بتاريخ
-- الطلب: التاريخ يخمّن، وغياب الحركة يقين.
do $do$
declare
  r record;
begin
  for r in
    select pr.* from public.payout_requests pr
    where pr.status = 'pending'
      and not exists (
        select 1 from public.wallet_transactions w
        where w.driver_id = pr.driver_id
          and w.description = 'حجز طلب سحب'
          and w.amount_iqd = -pr.amount_iqd
          and w.created_at >= pr.requested_at - interval '1 minute'
      )
  loop
    perform public.post_wallet_transaction(
      p_driver_id   => r.driver_id,
      p_txn_type    => 'payout',
      p_amount_iqd  => -r.amount_iqd,
      p_description => 'حجز طلب سحب'
    );
  end loop;
end
$do$;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.payout_requests where status = 'pending')
    as "طلبات معلّقة",
  public.payout_reserve_iqd() as "الرصيد المحجوز";
