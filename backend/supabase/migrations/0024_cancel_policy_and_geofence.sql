set search_path = public, extensions;

-- =============================================================================
-- 0024 — سياسة الإلغاء الجديدة، وحارس المسافة على تقدّم الرحلة
-- =============================================================================
-- ثلاثة تغييرات تخدم غرضاً واحداً: أن يكون ما يراه التطبيق مطابقاً لما
-- يحدث في الشارع.
--
--   ١) **الراكب يلغي بلا عواقب.** كنا نفرض عليه ٥٠٠ دينار إن ألغى بعد
--      مهلة السماح. المستخدم قرّر رفع ذلك: راكبٌ يخاف زر الإلغاء يترك
--      الطلب معلّقاً بدل إلغائه، فيضيع وقت السائق كاملاً بدل دقيقتين.
--
--   ٢) **السائق يلغي بعد القبول: مرّتان مجاناً كل يوم، ثم ٥٠٠ دينار.**
--      الإلغاء بعد القبول يترك الراكب واقفاً في الشارع وقد انتظر بالفعل،
--      وهو أسوأ من ألا يجد سائقاً أصلاً. لكن المنع التام قاسٍ: قد تُثقب
--      إطاراته أو يمرض. مرّتان مجاناً تحتملان العذر، والثالثة تكلّف.
--
--      **العدّاد يُصفَّر منتصف كل ليلة بتوقيت بغداد** لا بتوقيت الخادم
--      (وهو UTC). فرقٌ ثلاث ساعات يعني أن سائقاً يلغي في الحادية عشرة
--      ليلاً كان سيُحسب عليه في يوم الغد.
--
--   ٣) **حارس المسافة.** "وصلت" و"بدأت الرحلة" صارتا تشترطان أن يكون
--      السائق قريباً فعلاً من نقطة الانطلاق. بلا ذلك يضغط الأزرار وهو
--      في بيته، فيرى الراكب "وصل سائقك" ولا أحد عند الباب.
--
--      **الفحص في القاعدة لا في التطبيق:** ما يُفحص على الهاتف يُتجاوز
--      بتطبيق معدَّل. والقاعدة تعرف موقع السائق أصلاً — يرسله كل خمس
--      ثوانٍ.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) ضوابط جديدة في المنطقة
-- -----------------------------------------------------------------------------
alter table public.pricing_zones
  add column if not exists driver_free_cancels_per_day smallint not null default 2,
  add column if not exists driver_cancel_penalty_iqd   numeric(10,2) not null default 500,
  add column if not exists arrival_radius_m            integer not null default 200;

comment on column public.pricing_zones.driver_free_cancels_per_day is
  'كم إلغاءً بعد القبول يُسمح به مجاناً في اليوم الواحد (توقيت بغداد).';

comment on column public.pricing_zones.driver_cancel_penalty_iqd is
  'ما يُخصم من السائق عند تجاوز الإلغاءات المجانية.';

comment on column public.pricing_zones.arrival_radius_m is
  'كم متراً يُعدّ السائق فيها "وصل" إلى نقطة الانطلاق. ٢٠٠ متر تحتمل '
  'انحراف GPS في المدينة دون أن تسمح بالضغط من البيت.';

-- الراكب لا يدفع شيئاً بعد اليوم. نُبقي العمود لأن الرحلات القديمة
-- سجّلت فيه رسوماً فعلية، ومحوها يفسد كشوف الحساب.
update public.pricing_zones set cancellation_fee_iqd = 0;


-- -----------------------------------------------------------------------------
-- ٢) كم بقي للسائق من إلغاءات مجانية اليوم
-- -----------------------------------------------------------------------------
-- يستدعيها التطبيق ليُري السائق العاقبة **قبل** أن يضغط، لا بعدها.
create or replace function public.my_cancels_today()
returns table (
  used      integer,
  free      integer,
  penalty   numeric
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select
    (select count(*)::integer
     from public.trips t
     where t.driver_id = auth.uid()
       and t.cancelled_by = auth.uid()
       and t.cancelled_at is not null
       and timezone('Asia/Baghdad', t.cancelled_at)::date
           = timezone('Asia/Baghdad', now())::date),
    coalesce((select min(driver_free_cancels_per_day)::integer
              from public.pricing_zones where is_active), 2),
    coalesce((select min(driver_cancel_penalty_iqd)
              from public.pricing_zones where is_active), 500);
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الإلغاء: الراكب مجاناً، والسائق بعد مرّتين
-- -----------------------------------------------------------------------------
create or replace function public.cancel_trip(
  p_trip_id uuid,
  p_reason  text default null
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip     public.trips;
  v_zone     public.pricing_zones;
  v_is_rider boolean;
  v_fee      numeric(10,2) := 0;   -- ما يُخصم من السائق عقوبةً
  v_used     integer := 0;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'الرحلة غير موجودة';
  end if;

  v_is_rider := (v_trip.rider_id = auth.uid());

  if not v_is_rider and v_trip.driver_id is distinct from auth.uid() then
    raise exception 'لا تملك صلاحية إلغاء هذه الرحلة'
      using errcode = 'insufficient_privilege';
  end if;

  if v_trip.status in ('completed', 'cancelled') then
    raise exception 'الرحلة منتهية بالفعل';
  end if;

  -- **السائق لا يلغي رحلة بدأت فعلاً.** الراكب على الدراجة حينها،
  -- وتركه في منتصف الطريق ليس إلغاءً بل هجراً.
  if not v_is_rider and v_trip.status = 'in_progress' then
    raise exception 'لا يمكن إلغاء رحلة بدأت. أنهِها من زر الإنهاء';
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  -- ---- عقوبة إلغاء السائق ----
  --
  -- تُحسب على الإلغاء **بعد القبول** وحده: رفض العرض قبل القبول حقٌّ
  -- كامل لا عقوبة فيه، وهو ما يبني عليه محرك المطابقة أصلاً.
  if not v_is_rider and v_trip.status in ('accepted', 'driver_arrived') then
    select count(*) into v_used
    from public.trips t
    where t.driver_id = auth.uid()
      and t.cancelled_by = auth.uid()
      and t.cancelled_at is not null
      and timezone('Asia/Baghdad', t.cancelled_at)::date
          = timezone('Asia/Baghdad', now())::date;

    if v_used >= coalesce(v_zone.driver_free_cancels_per_day, 2) then
      v_fee := coalesce(v_zone.driver_cancel_penalty_iqd, 500);
    end if;
  end if;

  update public.trips
  set status               = 'cancelled',
      cancelled_by         = auth.uid(),
      cancellation_reason  = p_reason,
      cancellation_fee_iqd = v_fee
  where id = p_trip_id
  returning * into v_trip;

  -- إبطال العروض المعلّقة
  update public.trip_offers set status = 'cancelled', responded_at = now()
  where trip_id = p_trip_id and status = 'pending';

  -- إعادة السائق للشبكة
  if v_trip.driver_id is not null then
    update public.drivers
    set status = case when status = 'on_trip' then 'online' else status end,
        trips_cancelled = trips_cancelled
          + case when not v_is_rider then 1 else 0 end
    where id = v_trip.driver_id;

    -- **الخصم على السائق لا التعويض له.** كان هذا السطر يمنحه رسوم
    -- إلغاء الراكب؛ صار يخصم عقوبة إلغائه هو. الإشارة سالبة.
    if v_fee > 0 then
      perform public.post_wallet_transaction(
        p_driver_id   => v_trip.driver_id,
        p_txn_type    => 'cancellation_fee',
        p_amount_iqd  => -v_fee,
        p_trip_id     => v_trip.id,
        p_description => format('عقوبة إلغاء الرحلة رقم %s', v_trip.trip_number)
      );
    end if;
  end if;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) حارس المسافة على "وصلت" و"بدأت الرحلة"
-- -----------------------------------------------------------------------------
create or replace function public.advance_trip(
  p_trip_id uuid,
  p_to      public.trip_status
)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip     public.trips;
  v_zone     public.pricing_zones;
  v_loc      geography;
  v_loc_age  integer;
  v_distance integer;
  v_radius   integer;
begin
  if p_to not in ('driver_arrived', 'in_progress') then
    raise exception 'استخدم complete_trip أو cancel_trip لهذه الحالة';
  end if;

  select * into v_trip from public.trips
  where id = p_trip_id and driver_id = auth.uid()
  for update;

  if not found then
    raise exception 'الرحلة غير موجودة أو ليست لك'
      using errcode = 'insufficient_privilege';
  end if;

  select z.* into v_zone
  from public.pricing_zones z
  where z.id = public.zone_for_point(v_trip.pickup_location);

  v_radius := coalesce(v_zone.arrival_radius_m, 200);

  select d.current_location,
         round(extract(epoch from (now() - d.location_updated_at)))::integer
  into v_loc, v_loc_age
  from public.drivers d where d.id = auth.uid();

  -- **موقع قديم يُرفض كما يُرفض غيابه.** موقع عمره خمس دقائق قد يكون
  -- بيت السائق لا موقعه الآن، وقبوله يفتح الباب لما جئنا نغلقه.
  if v_loc is null or v_loc_age is null or v_loc_age > 120 then
    raise exception
      'تعذّر تحديد موقعك. تأكد أن خدمة الموقع تعمل ثم أعد المحاولة';
  end if;

  v_distance := st_distance(v_loc, v_trip.pickup_location)::integer;

  if v_distance > v_radius then
    raise exception 'أنت على بعد % متر من نقطة الانطلاق. اقترب إلى أقل من % متر',
      v_distance, v_radius;
  end if;

  -- المُشغّل enforce_trip_transition يرفض الانتقالات غير المنطقية
  update public.trips set status = p_to where id = p_trip_id
  returning * into v_trip;

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.my_cancels_today from public, anon;
grant execute on function public.my_cancels_today() to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  city_name_ar                as "المنطقة",
  cancellation_fee_iqd        as "رسوم إلغاء الراكب",
  driver_free_cancels_per_day as "إلغاءات السائق المجانية",
  driver_cancel_penalty_iqd   as "عقوبة السائق",
  arrival_radius_m            as "نطاق الوصول (م)"
from public.pricing_zones
order by city_name_ar
limit 5;
