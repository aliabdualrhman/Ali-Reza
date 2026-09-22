-- =============================================================================
-- 0075 — الباقي النقدي يعود إلى محفظة الراكب
-- =============================================================================
-- **مشكلةٌ يوميّة في سوقٍ نقديّ.** الأجرة ١٥٠٠ والراكب يحمل ٢٠٠٠ وليس مع
-- السائق فكّة. فإمّا أن يخسر الراكب خمسمئة، أو يقف الاثنان في الشارع
-- يبحثان عن صرّاف. وكلاهما يُفقدنا راكباً.
--
-- **فالباقي يصير رصيداً.** يسأل التطبيقُ السائقَ: كم سلّمك؟ فإن زاد عمّا
-- عليه، انتقل الفرق من محفظة السائق إلى محفظة الراكب في اللحظة نفسها.
-- لا يخسر أحد، ويعود المال إلى صاحبه.
--
-- ------------------------------------------------------------------
-- والمعادلة سطرٌ واحد
-- ------------------------------------------------------------------
--     الباقي = ما سلّمه الراكب − cash_due_iqd
--
-- و`cash_due_iqd` محسوبٌ في 0052 بعد خصم رصيد الراكب **وبعد الكوبون
-- معاً**. فلا نحسب التخفيض هنا ولا الرصيد: أجرةٌ ١٥٠٠ بتخفيض ٥٠٠ تعني
-- `cash_due = 1000`، ومن سلّم ٥٠٠٠ يستردّ ٤٠٠٠. وتعويض السائق عن
-- التخفيض يجري في `complete_trip` كما هو، فلا يُمسّ.
--
-- ------------------------------------------------------------------
-- والحدّ هو حارسنا من ثلاثة أخطار في آنٍ واحد
-- ------------------------------------------------------------------
-- `min_wallet_balance_iqd` (‎-3000 لكل منطقة) يمنع الإرجاع الذي يهوي
-- بالسائق تحته. وهو يحمي من:
--
--   • **سائقٍ يُرجع ما لا يملك** فيتراكم عليه دَينٌ لا يُسدَّد.
--   • **خطأٍ مطبعيّ**: من كتب ٢٠٬٠٠٠ بدل ٢٬٠٠٠ يُردّ عند الحدّ لا بعده.
--   • **تصفيةٍ متعمَّدة**: لا يستطيع تفريغ محفظته بإرجاعاتٍ وهمية.
--
-- ولا نمنعه بصمت: نقول له إنه بلغ الحد وعليه أن يعبّئ.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الأعمدة
-- -----------------------------------------------------------------------------
alter table public.trips
  add column if not exists cash_received_iqd   numeric(10,2),
  add column if not exists change_returned_iqd numeric(10,2) not null default 0;

comment on column public.trips.cash_received_iqd is
  'ما سلّمه الراكب نقداً كما أقرّ السائق. فارغ = لم يُسأل بعد.';
comment on column public.trips.change_returned_iqd is
  'الباقي الذي انتقل من محفظة السائق إلى محفظة الراكب.';


-- -----------------------------------------------------------------------------
-- ٢) تسوية الباقي
-- -----------------------------------------------------------------------------
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

  -- **سائق الرحلة وحده.** غيرُه لا يعرف ما جرى، ولا يجوز أن ينقل مالاً.
  if v_trip.driver_id is distinct from v_uid then
    raise exception 'هذه ليست رحلتك';
  end if;
  if v_trip.status <> 'completed' then
    raise exception 'الرحلة لم تكتمل بعد';
  end if;
  if v_trip.cash_received_iqd is not null then
    raise exception 'سُجّل المبلغ لهذه الرحلة من قبل';
  end if;

  v_due := coalesce(v_trip.cash_due_iqd,
                    coalesce(v_trip.fare_final_iqd, 0)
                      - coalesce(v_trip.discount_iqd, 0));

  if coalesce(p_received, 0) < v_due then
    raise exception 'المبلغ أقلّ من الأجرة المستحقة (% دينار)',
      v_due::bigint;
  end if;

  v_change := coalesce(p_received, 0) - v_due;

  -- **الحدّ يُفحص قبل أن نلمس شيئاً.** لو خصمنا ثم فحصنا لبقي السائق
  -- تحت الحدّ ونحن نعتذر.
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

  -- ---- من محفظة السائق ----
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

  -- ---- إلى محفظة الراكب ----
  -- **رصيدٌ حقيقيّ لا هدية.** هذا ماله هو، دفعه نقداً قبل دقيقة.
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

  -- ---- إشعارٌ للراكب ----
  -- **يُخبَر بالمبلغ وباسم من أرجعه.** رصيدٌ يزيد بلا خبرٍ يُقلق، ورقمٌ
  -- بلا اسمٍ لا يُراجَع عند الخلاف.
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
-- ٣) التقييم يحمل سببه
-- -----------------------------------------------------------------------------
-- **نجومٌ بلا سبب لا تُصلح شيئاً.** ثلاث نجومٍ تقول إن شيئاً ساء ولا
-- تقول ما هو، فلا المدير يعرف ماذا يفعل ولا السائق يعرف ماذا يصحّح.
alter table public.ratings
  add column if not exists tags text[] not null default '{}',

  -- **الشكوى الوحيدة التي تحمل رقماً.** «لم يُعِد الباقي» بلا مبلغٍ
  -- لا تُحقَّق: المدير يحتاج أن يقارنه بما سجّله السائق.
  add column if not exists reported_change_iqd numeric(10,2);

comment on column public.ratings.tags is
  'أسباب مختارة. الإيجابية عند ٤ نجوم فأكثر، والسلبية عند ٣ فأقل.';


-- **تصل المدير لحظتها لا في تقرير شهري.** شكوى مالٍ تبرد بسرعة: بعد
-- أسبوع لا الراكب يذكر ولا السائق يعترف.
create or replace function public.notify_change_complaint()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip   public.trips;
  v_rater  text;
begin
  if not ('no_change' = any (new.tags)) then return new; end if;

  select * into v_trip from public.trips where id = new.trip_id;
  select full_name into v_rater from public.profiles where id = new.rater_id;

  insert into public.notifications (user_id, title, body, kind)
  select p.id,
         'شكوى: باقٍ لم يُعَد',
         format('%s يقول إن السائق لم يُعِد %s دينار — الرحلة رقم %s. '
                'المسجَّل في الرحلة: %s دينار.',
                coalesce(v_rater, 'راكب'),
                coalesce(new.reported_change_iqd, 0)::bigint,
                v_trip.trip_number,
                coalesce(v_trip.change_returned_iqd, 0)::bigint),
         'direct'
  from public.profiles p
  where p.role = 'admin' and p.deleted_at is null;

  return new;
end;
$fn$;

drop trigger if exists ratings_change_complaint on public.ratings;
create trigger ratings_change_complaint
  after insert on public.ratings
  for each row execute function public.notify_change_complaint();


-- -----------------------------------------------------------------------------
-- ٤) تفاصيل رحلةٍ واحدة — للطرفين
-- -----------------------------------------------------------------------------
-- **الطرف الآخر بلا هاتفٍ ولا عنوان.** بعد انتهاء الرحلة لم يبقَ سببٌ
-- لأن يعرف أحدهما كيف يصل إلى الآخر خارج التطبيق — والاسم والتقييم
-- يكفيان ليتذكّر من كان معه.
create or replace function public.my_trip_detail(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_t     public.trips;
  v_other uuid;
  v_p     public.profiles;
  v_d     public.drivers;
  v_rated boolean;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  select * into v_t from public.trips where id = p_trip_id;
  if v_t.id is null then raise exception 'رحلة غير موجودة'; end if;

  if v_uid not in (v_t.rider_id, coalesce(v_t.driver_id, v_uid)) then
    raise exception 'هذه ليست رحلتك';
  end if;
  if v_uid <> v_t.rider_id and v_uid is distinct from v_t.driver_id then
    raise exception 'هذه ليست رحلتك';
  end if;

  v_other := case when v_uid = v_t.rider_id then v_t.driver_id
                  else v_t.rider_id end;

  select * into v_p from public.profiles where id = v_other;
  if v_other is not null then
    select * into v_d from public.drivers where id = v_other;
  end if;

  select exists (
    select 1 from public.ratings
    where trip_id = p_trip_id and rater_id = v_uid
  ) into v_rated;

  return jsonb_build_object(
    'id',            v_t.id,
    'trip_number',   v_t.trip_number,
    'status',        v_t.status,
    'requested_at',  v_t.requested_at,
    'completed_at',  v_t.completed_at,
    'pickup',        v_t.pickup_address,
    'dropoff',       v_t.dropoff_address,
    'distance_m',    coalesce(v_t.actual_distance_m, v_t.estimated_distance_m),
    'fare',          v_t.fare_final_iqd,
    'discount',      v_t.discount_iqd,
    'credit_used',   v_t.credit_used_iqd,
    'cash_due',      v_t.cash_due_iqd,
    'cash_received', v_t.cash_received_iqd,
    'change',        v_t.change_returned_iqd,
    'earning',       case when v_uid = v_t.driver_id
                          then v_t.driver_earning_iqd end,
    'rated',         v_rated,
    'i_am_rider',    v_uid = v_t.rider_id,
    'other', case when v_other is null then null else jsonb_build_object(
      'name',    v_p.full_name,
      'avatar',  v_p.avatar_url,
      'rating',  v_d.rating_avg,
      'vehicle', v_d.vehicle_type,
      'plate',   v_d.vehicle_plate,
      'color',   v_d.vehicle_color
    ) end
  );
end;
$fn$;

revoke all on function public.my_trip_detail(uuid) from public, anon;
grant execute on function public.my_trip_detail(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
   where table_name = 'trips'
     and column_name in ('cash_received_iqd', 'change_returned_iqd'))
    as "أعمدة الرحلة (٢)",
  (select count(*) from information_schema.columns
   where table_name = 'ratings'
     and column_name in ('tags', 'reported_change_iqd'))
    as "أعمدة التقييم (٢)",
  (select min(min_wallet_balance_iqd) from public.pricing_zones where is_active)
    as "حدّ الرصيد";
