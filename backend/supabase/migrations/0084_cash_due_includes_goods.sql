-- =============================================================================
-- 0084 — البضاعة جزءٌ من المستحقّ في كل احتياطيّ
-- =============================================================================
-- **عطلٌ ماليّ رآه علي في الاختبار.** طلب تسوّق: بضاعة ١٠٠٠ وأجرة
-- ١٥٠٠، فالمستحقّ ٢٥٠٠. سلّمه الراكب ٣٠٠٠، فقال التطبيق: الباقي ١٥٠٠.
--
-- والصحيح ٥٠٠. **فكان السائق يُرجع ألفاً من جيبه** — ثمن البضاعة التي
-- اشتراها بماله.
--
-- ------------------------------------------------------------------
-- والسبب سطرٌ احتياطيّ في مكانين
-- ------------------------------------------------------------------
-- `cash_due_iqd` يحسبه مُشغّل `settle_rider_credit` عند الإكمال،
-- والبضاعة داخلةٌ فيه. لكنّ كلا الطرفين — التطبيق و`settle_cash_change`
-- — يحملان احتياطياً لحظة كونه فارغاً:
--
--     coalesce(cash_due_iqd, fare_final - discount)
--
-- وهذا الاحتياطيّ **ينسى البضاعة**. فإن قُرئ الصفّ قبل أن يصل تحديث
-- المُشغّل — وهو فرقُ لحظة — حُسب الباقي على الأجرة وحدها.
--
-- **والاحتياطيّ الخاطئ أخطر من غيابه:** لا يفشل فيُنبّه، بل ينجح
-- برقمٍ ناقص.

set search_path = public, extensions;


create or replace function public.settle_cash_change(
  p_trip_id  uuid,
  p_received numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_trip   public.trips;
  v_due    numeric(12,2);
  v_change numeric(12,2);
  v_bal    numeric(12,2);
  v_floor  numeric(12,2);
  v_name   text;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  select * into v_trip from public.trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'رحلة غير موجودة'; end if;

  if v_trip.driver_id is distinct from v_uid then
    raise exception 'هذه ليست رحلتك';
  end if;
  if v_trip.status <> 'completed' then
    raise exception 'الرحلة لم تكتمل بعد';
  end if;
  if v_trip.cash_received_iqd is not null then
    raise exception 'سُجّل المبلغ لهذه الرحلة من قبل';
  end if;

  -- **البضاعة في الاحتياطيّ أيضاً.** انظر رأس الملف.
  v_due := coalesce(
    v_trip.cash_due_iqd,
    coalesce(v_trip.fare_final_iqd, 0)
      - coalesce(v_trip.discount_iqd, 0)
      + coalesce(v_trip.goods_actual_iqd, v_trip.goods_estimate_iqd, 0)
  );

  if coalesce(p_received, 0) < v_due then
    raise exception 'المبلغ أقلّ من الأجرة المستحقة (% دينار)',
      v_due::bigint;
  end if;

  v_change := coalesce(p_received, 0) - v_due;

  if v_change > 0 then
    select wallet_balance_iqd into v_bal
    from public.drivers where id = v_uid;

    select coalesce(min(min_wallet_balance_iqd), -3000) into v_floor
    from public.pricing_zones where is_active;

    if v_bal - v_change < v_floor then
      raise exception
        'لا يمكن إرجاع الباقي — رصيدك بلغ الحد (% دينار). يرجى التعبئة.',
        v_floor::bigint;
    end if;
  end if;

  update public.trips
  set cash_received_iqd   = p_received,
      change_returned_iqd = v_change
  where id = p_trip_id;

  if v_change <= 0 then
    return jsonb_build_object('change', 0);
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => v_uid,
    p_txn_type    => 'adjustment',
    p_amount_iqd  => -v_change,
    p_trip_id     => p_trip_id,
    p_description => format('باقي نقدي للراكب — الرحلة رقم %s',
                            v_trip.trip_number)
  );

  insert into public.balance_entries
    (user_id, kind, amount_iqd, reason, trip_id, note)
  values (v_uid, 'real', -v_change, 'trip', p_trip_id,
          format('باقي نقدي للراكب — الرحلة رقم %s', v_trip.trip_number));

  perform set_config('app.bypass_guards', 'on', true);

  insert into public.rider_wallets (id) values (v_trip.rider_id)
  on conflict (id) do nothing;

  update public.rider_wallets
  set real_balance_iqd = real_balance_iqd + v_change,
      updated_at       = now()
  where id = v_trip.rider_id;

  perform set_config('app.bypass_guards', 'off', true);

  insert into public.balance_entries
    (user_id, kind, amount_iqd, reason, trip_id, note)
  values (v_trip.rider_id, 'real', v_change, 'trip', p_trip_id,
          format('باقي نقدي — الرحلة رقم %s', v_trip.trip_number));

  select split_part(full_name, ' ', 1) into v_name
  from public.profiles where id = v_uid;

  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (
    v_trip.rider_id,
    'أُعيد باقيك إلى محفظتك',
    format('أعاد السائق %s مبلغ %s دينار إلى محفظتك — الرحلة رقم %s.',
           coalesce(v_name, 'زنبور'), v_change::bigint, v_trip.trip_number),
    'direct',
    v_uid
  );

  return jsonb_build_object('change', v_change);
end;
$fn$;

revoke all on function public.settle_cash_change(uuid, numeric)
  from public, anon;
grant execute on function public.settle_cash_change(uuid, numeric)
  to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select count(*) as "الاحتياطيّ يشمل البضاعة (يجب ١)"
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname = 'settle_cash_change'
  and prosrc like '%goods_actual_iqd, v_trip.goods_estimate_iqd%';
