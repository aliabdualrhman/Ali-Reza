-- =============================================================================
-- 0103 — رصيد الهدية يدفع العمولة فعلاً
-- =============================================================================
-- رصد علي: «أضيف رصيد هدية لسائق فلا يظهر شيء، وتطبيق السائق أصلاً لا
-- مكان فيه لرصيد الهدية».
--
-- والفحص أثبت أنه **رقمٌ ميت**: `complete_trip` تخصم العمولة من
-- `wallet_balance_iqd` دائماً ولا تنظر إلى `bonus_balance_iqd` إطلاقاً.
-- فالهدية تُضاف وتبقى كما هي إلى الأبد: لا تُنفَق، ولا تُسحب، ولا تُعرض.
--
-- **والنظام يَعِد بغير ذلك.** `request_payout` تقول للسائق حرفياً:
--
--     «ورصيد الهدية (%) يُنفق على العمولة ولا يُسحب نقداً»
--
-- وعدٌ مكتوبٌ في الشيفرة ولا ينفّذه أحد. فمن وهبناه خمسين ألفاً ظنّها
-- تحميه من دَين العمولة، وهي لا تحميه من شيء.
--
-- **والعمولة تُخصم من الهدية أولاً.** هذا معنى الهدية: مالٌ نمنحه للسائق
-- ليعمل به، لا رقمٌ يزيّن شاشته. وما زاد على الهدية يُقيَّد ديناً كما كان.
--
-- **ويُسجَّل إنفاقها في `balance_entries`** — كما تُسجَّل إضافتها. بلا ذلك
-- تنقص الهدية بلا أثرٍ يفسّر أين ذهبت.

set search_path = public, extensions;


-- منسوخةٌ من التعريف الحيّ، والتغيير في كتلة العمولة وحدها.
create or replace function public.complete_trip(
  p_trip_id           uuid,
  p_actual_distance_m integer default null,
  p_actual_duration_s integer default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip  public.trips;
  v_zone  uuid;
  v_fare  jsonb;
  v_dist  integer;
  v_dur   integer;
  v_disc  numeric(10,2);
  v_total numeric(10,2);
  v_comm  numeric(10,2);
  v_rate  numeric;
  v_bonus numeric(12,2);
  v_used  numeric(12,2);
begin
  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك' using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status <> 'in_progress' then
    raise exception 'لا يمكن إنهاء رحلة حالتها %', v_trip.status;
  end if;

  -- **لا إنهاء قبل بلوغ المحطة الأخيرة.** بلا هذا يُقفل السائق رحلةً
  -- متعددة المحطات عند أولاها فتضيع مرحلة كاملة وأجرتها.
  if v_trip.current_leg < v_trip.stop_count then
    raise exception 'بقيت محطة أخرى. اضغط "وصلت إلى المحطة" أولاً';
  end if;

  v_dist := coalesce(p_actual_distance_m, v_trip.estimated_distance_m);
  v_dur  := coalesce(
    p_actual_duration_s,
    extract(epoch from (now() - v_trip.started_at))::integer,
    v_trip.estimated_duration_s
  );

  v_zone := public.zone_for_point(v_trip.pickup_location);
  v_fare := public.calculate_fare(v_zone, v_dist, v_dur, v_trip.surge_multiplier);

  -- **الأجرة المجمَّدة تسبق إعادة الحساب.** رحلة بمرحلتين أو غُيّرت
  -- وجهتها لا يستطيع هذا السطر اشتقاق سعرها من المسافة الكلية.
  if v_trip.fare_locked_iqd is not null then
    select commission_rate into v_rate
    from public.pricing_zones where id = v_zone;

    v_total := v_trip.fare_locked_iqd;
    v_comm  := round(v_total * coalesce(v_rate, 0.15), 2);
  else
    v_total := (v_fare ->> 'total')::numeric;
    v_comm  := (v_fare ->> 'commission')::numeric;
  end if;

  v_disc := least(coalesce(v_trip.discount_iqd, 0), v_total);

  update public.trips
  set status             = 'completed',
      actual_distance_m  = v_dist,
      actual_duration_s  = v_dur,
      fare_final_iqd     = v_total,
      commission_iqd     = v_comm,
      driver_earning_iqd = v_total - v_comm,
      discount_iqd       = v_disc,
      fare_breakdown     = coalesce(v_trip.fare_breakdown, v_fare),
      payment_status     = case when v_trip.payment_method = 'cash'
                                then 'paid'::public.payment_status
                                else 'pending'::public.payment_status end
  where id = p_trip_id
  returning * into v_trip;

  perform set_config('app.bypass_guards', 'on', true);

  update public.drivers
  set status          = 'online',
      trips_completed = trips_completed + 1
  where id = v_trip.driver_id;

  -- ---------------------------------------------------------------------
  -- **العمولة تأكل الهدية أولاً.**
  -- ---------------------------------------------------------------------
  -- القفل قبل القراءة: رحلتان تنتهيان في اللحظة نفسها تقرآن الهدية نفسها
  -- ثم تخصمان منها مرتين — فيصير الرصيد سالباً أو تُنفق الهدية مرتين.
  select bonus_balance_iqd into v_bonus
  from public.drivers where id = v_trip.driver_id for update;

  v_used := least(coalesce(v_bonus, 0), coalesce(v_trip.commission_iqd, 0));

  if v_used > 0 then
    update public.drivers
    set bonus_balance_iqd = bonus_balance_iqd - v_used
    where id = v_trip.driver_id;

    -- الإنفاق يُسجَّل كما تُسجَّل الإضافة — وإلا نقصت بلا تفسير.
    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, trip_id, note)
    values (v_trip.driver_id, 'bonus', -v_used, 'trip', v_trip.id,
            format('عمولة الرحلة رقم %s من رصيد الهدية', v_trip.trip_number));
  end if;

  perform set_config('app.bypass_guards', 'off', true);

  -- ما بقي من العمولة بعد الهدية يُقيَّد على المحفظة كما كان.
  if coalesce(v_trip.commission_iqd, 0) - v_used > 0 then
    perform public.post_wallet_transaction(
      p_driver_id   => v_trip.driver_id,
      p_txn_type    => 'commission',
      p_amount_iqd  => -(v_trip.commission_iqd - v_used),
      p_trip_id     => v_trip.id,
      p_description => case when v_used > 0
        then format('عمولة الرحلة رقم %s — بعد خصم %s من رصيد الهدية',
                    v_trip.trip_number, v_used::bigint)
        else format('عمولة الرحلة رقم %s', v_trip.trip_number)
      end
    );
  end if;

  if v_disc > 0 then
    perform public.post_wallet_transaction(
      p_driver_id   => v_trip.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_disc,
      p_trip_id     => v_trip.id,
      p_description => format('تعويض خصم كوبون — رحلة %s', v_trip.trip_number)
    );

    insert into public.coupon_redemptions
      (coupon_id, rider_id, trip_id, discount_iqd)
    values (v_trip.coupon_id, v_trip.rider_id, v_trip.id, v_disc)
    on conflict (trip_id) do nothing;
  end if;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'complete_trip'
     and prosrc like '%bonus_balance_iqd%')        as "العمولة تعرف الهدية (١)",
  (select count(*) from public.drivers
   where coalesce(bonus_balance_iqd, 0) > 0)       as "سائقون لديهم هدية الآن";
