set search_path = public, extensions;

-- =============================================================================
-- 0034 — ضبط أرقام المنطقة من اللوحة
-- =============================================================================
-- أرقام المطابقة والتسعير كلها أعمدة في `pricing_zones` منذ اليوم الأول،
-- وهذا ما جعل كل تغيير سعر أو مهلة سطرَ `update` واحداً بلا إعادة بناء.
--
-- **لكنها بقيت في القاعدة وحدها.** ومن يريد تعديل عدد العروض المتزامنة
-- يفتح محرر SQL ويكتب استعلاماً — وهذا حاجزٌ يجعل الأرقام تبقى على
-- افتراضها لا لأنها صحيحة بل لأن تغييرها متعب.
--
-- الدالة هنا تنقلها إلى اللوحة، ومعها حارس صلاحية وسجلّ تدقيق.
-- =============================================================================

create or replace function public.set_zone_numbers(
  p_id      uuid,
  p_numbers jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_name text;
  v_key  text;
begin
  if not public.has_perm('settings.manage') then
    raise exception 'لا تملك صلاحية تعديل المناطق'
      using errcode = 'insufficient_privilege';
  end if;

  -- **قائمة بيضاء صريحة.** بلا هذا يستطيع من يملك الصلاحية أن يمرّر
  -- اسم أي عمود — ومنها `boundary` أو `is_active` — فيغيّر ما لم تُصمَّم
  -- هذه الدالة لتغييره.
  for v_key in select jsonb_object_keys(p_numbers) loop
    if v_key not in (
      'base_fare_iqd', 'per_km_iqd', 'minimum_fare_iqd', 'commission_rate',
      'search_radius_m', 'max_search_radius_m',
      'offer_timeout_s', 'offer_round_seconds', 'max_search_seconds',
      'max_concurrent_offers', 'boosted_concurrent_offers',
      'search_boost_pct', 'tuktuk_surcharge_pct',
      'second_leg_discount_pct', 'stopover_surcharge_pct',
      'stopover_free_minutes', 'arrival_radius_m',
      'driver_free_cancels_per_day', 'driver_cancel_penalty_iqd',
      'min_wallet_balance_iqd', 'cancellation_fee_iqd'
    ) then
      raise exception 'حقل غير مسموح بتعديله: %', v_key;
    end if;
  end loop;

  update public.pricing_zones z
  set base_fare_iqd    = coalesce((p_numbers->>'base_fare_iqd')::numeric, z.base_fare_iqd),
      per_km_iqd       = coalesce((p_numbers->>'per_km_iqd')::numeric, z.per_km_iqd),
      minimum_fare_iqd = coalesce((p_numbers->>'minimum_fare_iqd')::numeric, z.minimum_fare_iqd),
      commission_rate  = coalesce((p_numbers->>'commission_rate')::numeric, z.commission_rate),
      search_radius_m     = coalesce((p_numbers->>'search_radius_m')::integer, z.search_radius_m),
      max_search_radius_m = coalesce((p_numbers->>'max_search_radius_m')::integer, z.max_search_radius_m),
      offer_timeout_s     = coalesce((p_numbers->>'offer_timeout_s')::integer, z.offer_timeout_s),
      offer_round_seconds = coalesce((p_numbers->>'offer_round_seconds')::integer, z.offer_round_seconds),
      max_search_seconds  = coalesce((p_numbers->>'max_search_seconds')::integer, z.max_search_seconds),
      max_concurrent_offers     = coalesce((p_numbers->>'max_concurrent_offers')::smallint, z.max_concurrent_offers),
      boosted_concurrent_offers = coalesce((p_numbers->>'boosted_concurrent_offers')::smallint, z.boosted_concurrent_offers),
      search_boost_pct     = coalesce((p_numbers->>'search_boost_pct')::smallint, z.search_boost_pct),
      tuktuk_surcharge_pct = coalesce((p_numbers->>'tuktuk_surcharge_pct')::smallint, z.tuktuk_surcharge_pct),
      second_leg_discount_pct = coalesce((p_numbers->>'second_leg_discount_pct')::smallint, z.second_leg_discount_pct),
      stopover_surcharge_pct  = coalesce((p_numbers->>'stopover_surcharge_pct')::smallint, z.stopover_surcharge_pct),
      stopover_free_minutes   = coalesce((p_numbers->>'stopover_free_minutes')::smallint, z.stopover_free_minutes),
      arrival_radius_m        = coalesce((p_numbers->>'arrival_radius_m')::integer, z.arrival_radius_m),
      driver_free_cancels_per_day = coalesce((p_numbers->>'driver_free_cancels_per_day')::smallint, z.driver_free_cancels_per_day),
      driver_cancel_penalty_iqd   = coalesce((p_numbers->>'driver_cancel_penalty_iqd')::numeric, z.driver_cancel_penalty_iqd),
      min_wallet_balance_iqd      = coalesce((p_numbers->>'min_wallet_balance_iqd')::numeric, z.min_wallet_balance_iqd),
      cancellation_fee_iqd        = coalesce((p_numbers->>'cancellation_fee_iqd')::numeric, z.cancellation_fee_iqd)
  where z.id = p_id
  returning z.city_name_ar into v_name;

  if v_name is null then
    raise exception 'المنطقة غير موجودة';
  end if;

  perform public.log_action('zone.tune', 'zone', p_id::text,
    format('عدّل أرقام منطقة %s', v_name));
end;
$fn$;

revoke all on function public.set_zone_numbers from public, anon;
grant execute on function public.set_zone_numbers(uuid, jsonb) to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar              as "المنطقة",
  max_concurrent_offers     as "عروض معاً",
  boosted_concurrent_offers as "بعد الرفع",
  offer_timeout_s           as "مهلة العرض",
  offer_round_seconds       as "العودة بعد"
from public.pricing_zones
where is_active;
