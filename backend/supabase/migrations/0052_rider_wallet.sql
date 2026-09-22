-- =============================================================================
-- 0052 — محفظة الراكب
-- =============================================================================
-- **الراكب كان بلا محفظة إطلاقاً.** يدفع نقداً ويمضي، ولا شيء يُنسب
-- إليه. والكوبونات وحدها كانت أداتنا — نسبةٌ مئوية على رحلةٍ بعينها، لا
-- رصيدٌ يملكه.
--
-- **وهي أساس نظام الدعوة**، ولا تقف عنده: تعويضٌ عن رحلة سيئة، هديةُ
-- عيد، استردادٌ حين يُلغي السائق، شحنٌ مسبق لاحقاً. الدعوة أول
-- استعمالاتها لا سببها.
--
-- **ونفصل الرصيدين كما فصلناهما عند السائق** (0051): فعليٌّ يملكه،
-- وهديةٌ تُنفق ولا تُسترد.
--
-- ------------------------------------------------------------------
-- كيف يُنفق الرصيد — وهي أدقّ نقطة في الملف
-- ------------------------------------------------------------------
-- الدفع نقدي: الراكب يسلّم الأجرة للسائق بيده. فلو ركب برصيده، **لم
-- يقبض السائق شيئاً** — وهديتنا لا يجوز أن تُدفع من جيبه.
--
-- فتُعوّض المنصة السائق بما استُهلك من الرصيد، ويُضاف إلى محفظته
-- **فعليّاً قابلاً للسحب**. وعمولة الرحلة تُخصم كما تُخصم دائماً في
-- `complete_trip`، فتبقى للمنصة:
--
--     أجرة 1,500 · رصيد الراكب 2,000
--       الراكب  يدفع 0        ويبقى له 500
--       السائق  يُضاف له 1,500  ثم تُخصم عمولته 225  =  1,275 صافياً
--       المنصة  تكلفتها 1,275   وعمولتها 225 محفوظة
--
-- **ولماذا نُضيف المبلغ كاملاً ثم تُخصم العمولة، لا الصافي مباشرةً؟**
-- لأن خصم العمولة يجري أصلاً في `complete_trip` لكل رحلة. وخصمُها هنا
-- ثانيةً يعني خصمها مرتين. النتيجة واحدة والمسار أوضح.
--
-- ------------------------------------------------------------------
-- ولماذا مُشغّل لا تعديلٌ في `complete_trip`؟
-- ------------------------------------------------------------------
-- `complete_trip` دالةٌ طويلة تحسب المسافة والأجرة المجمَّدة وخصم
-- المرحلة الثانية والعمولة. وإعادة كتابتها لإضافة سطرين تخاطر بكل ذلك.
-- والمُشغّل يلتقط الاكتمال من أيّ طريق جاء — ولن يُنسى حين نضيف مساراً
-- ثالثاً للاكتمال بعد شهر.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) المحفظة
-- -----------------------------------------------------------------------------
create table if not exists public.rider_wallets (
  id                uuid primary key
                    references public.profiles(id) on delete cascade,

  -- مالٌ يملكه: شحنٌ دفع ثمنه، أو تعويضٌ نقدي. يُسحب مستقبلاً.
  real_balance_iqd  numeric(12,2) not null default 0
                    check (real_balance_iqd >= 0),

  -- منحةٌ منّا. تُنفق على الأجرة ولا تخرج نقداً أبداً.
  bonus_balance_iqd numeric(12,2) not null default 0
                    check (bonus_balance_iqd >= 0),

  -- **الصلاحية على الهدية وحدها.** ما دفع ثمنه لا ينتهي — وإنهاؤه
  -- أخذُ مالٍ بلا مقابل.
  bonus_expires_at  timestamptz,

  updated_at        timestamptz not null default now()
);

comment on table public.rider_wallets is
  'رصيد الراكب. الهدية تُنفق على الأجرة ولا تُسحب؛ والفعلي يملكه.';

alter table public.rider_wallets enable row level security;

-- يقرأ رصيده ولا يكتبه. الكتابة بالدوال وحدها.
drop policy if exists rider_wallets_own_read on public.rider_wallets;
create policy rider_wallets_own_read on public.rider_wallets
  for select to authenticated
  using (id = auth.uid() or public.is_admin());


-- -----------------------------------------------------------------------------
-- ٢) الرصيد الصالح للإنفاق
-- -----------------------------------------------------------------------------
-- **الهدية المنتهية ليست رصيداً.** نفحص التاريخ في كل قراءة بدل مهمّةٍ
-- دورية تمسحها: لو تعطّلت المهمة يوماً لأنفق الراكب هديةً منتهية، ولو
-- تأخّرت لرأى رصيداً لا يستطيع إنفاقه.
create or replace function public.rider_spendable(p_rider_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select jsonb_build_object(
    'real',  coalesce(w.real_balance_iqd, 0),
    'bonus', case
               when w.bonus_expires_at is not null
                    and w.bonus_expires_at <= now() then 0
               else coalesce(w.bonus_balance_iqd, 0)
             end,
    'bonus_expires_at', w.bonus_expires_at
  )
  from public.rider_wallets w
  where w.id = p_rider_id;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الإنفاق التلقائي عند اكتمال الرحلة
-- -----------------------------------------------------------------------------
create or replace function public.settle_rider_credit()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_due    numeric(12,2);
  v_bonus  numeric(12,2);
  v_real   numeric(12,2);
  v_use_b  numeric(12,2);
  v_use_r  numeric(12,2);
  v_total  numeric(12,2);
  v_spend  jsonb;
begin
  -- ما يدفعه الراكب فعلاً بعد خصم الكوبون إن وُجد.
  v_due := coalesce(new.fare_final_iqd, 0) - coalesce(new.discount_iqd, 0);
  if v_due <= 0 then return new; end if;

  v_spend := public.rider_spendable(new.rider_id);
  if v_spend is null then return new; end if;

  v_bonus := (v_spend ->> 'bonus')::numeric;
  v_real  := (v_spend ->> 'real')::numeric;

  -- **الهدية أولاً.** لأنها تنتهي وماله لا ينتهي؛ وإنفاق ماله قبلها
  -- يُضيّع الهدية عليه بلا سبب.
  v_use_b := least(v_bonus, v_due);
  v_use_r := least(v_real, v_due - v_use_b);
  v_total := v_use_b + v_use_r;

  if v_total <= 0 then return new; end if;

  update public.rider_wallets
  set bonus_balance_iqd = bonus_balance_iqd - v_use_b,
      real_balance_iqd  = real_balance_iqd  - v_use_r,
      updated_at        = now()
  where id = new.rider_id;

  if v_use_b > 0 then
    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, trip_id, note)
    values (new.rider_id, 'bonus', -v_use_b, 'trip', new.id,
            format('رصيد هدية على الرحلة رقم %s', new.trip_number));
  end if;

  if v_use_r > 0 then
    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, trip_id, note)
    values (new.rider_id, 'real', -v_use_r, 'trip', new.id,
            format('رصيد على الرحلة رقم %s', new.trip_number));
  end if;

  -- **ما دفعه الراكب نقداً بعد الرصيد.** يقرؤه تطبيق السائق ليعرف كم
  -- يقبض؛ وبدونه يطلب الأجرة كاملة من راكبٍ سدّدها.
  update public.trips
  set credit_used_iqd = v_total,
      cash_due_iqd    = greatest(0, v_due - v_total)
  where id = new.id;

  -- **تعويض السائق.** الرصيد هديتنا لا هديته؛ فما استُهلك منه يُضاف
  -- إلى محفظته فعليّاً. والعمولة تُخصم في `complete_trip` كالمعتاد،
  -- فلا نخصمها هنا مرة ثانية.
  if new.driver_id is not null then
    perform public.post_wallet_transaction(
      p_driver_id   => new.driver_id,
      p_txn_type    => 'adjustment',
      p_amount_iqd  => v_total,
      p_trip_id     => new.id,
      p_description => format('تعويض رصيد الراكب — الرحلة رقم %s',
                              new.trip_number)
    );

    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, trip_id, note)
    values (new.driver_id, 'real', v_total, 'trip', new.id,
            format('تعويض رصيد الراكب — الرحلة رقم %s', new.trip_number));
  end if;

  return new;
end;
$fn$;


alter table public.trips
  add column if not exists credit_used_iqd numeric(10,2) not null default 0,
  add column if not exists cash_due_iqd    numeric(10,2);

comment on column public.trips.cash_due_iqd is
  'ما يقبضه السائق نقداً بعد خصم رصيد الراكب. فارغ = الأجرة كاملة.';

drop trigger if exists trips_settle_rider_credit on public.trips;
create trigger trips_settle_rider_credit
  after update of status on public.trips
  for each row
  when (new.status = 'completed' and old.status <> 'completed')
  execute function public.settle_rider_credit();


-- -----------------------------------------------------------------------------
-- ٤) المدير يعدّل رصيد الراكب
-- -----------------------------------------------------------------------------
create or replace function public.admin_adjust_rider_balance(
  p_rider_id uuid,
  p_amount   numeric,
  p_kind     text,
  p_note     text default null,
  p_expires_days integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_name  text;
  v_real  numeric(12,2);
  v_bonus numeric(12,2);
begin
  if not public.has_perm('wallets.adjust') then
    raise exception 'لا تملك صلاحية تعديل الأرصدة'
      using errcode = 'insufficient_privilege';
  end if;

  if p_kind not in ('real', 'bonus') then
    raise exception 'النوع يجب أن يكون real أو bonus';
  end if;

  if p_amount is null or p_amount = 0 then
    raise exception 'أدخل مبلغاً غير صفري';
  end if;

  if coalesce(btrim(p_note), '') = '' then
    raise exception 'اكتب سبب التعديل';
  end if;

  select full_name into v_name
  from public.profiles where id = p_rider_id and role = 'rider';

  if v_name is null then
    raise exception 'هذا الحساب ليس راكباً';
  end if;

  insert into public.rider_wallets (id) values (p_rider_id)
  on conflict (id) do nothing;

  if p_kind = 'real' then
    update public.rider_wallets
    set real_balance_iqd = greatest(0, real_balance_iqd + p_amount),
        updated_at = now()
    where id = p_rider_id;
  else
    update public.rider_wallets
    set bonus_balance_iqd = greatest(0, bonus_balance_iqd + p_amount),
        -- **الصلاحية تُمدَّد ولا تُقصَّر.** منحةٌ جديدة تصل قبل انتهاء
        -- سابقتها يجب ألا تُقصّر عمرها؛ والرصيد واحد لا طبقات.
        bonus_expires_at = case
          when p_amount <= 0 or p_expires_days is null then bonus_expires_at
          else greatest(
                 coalesce(bonus_expires_at, now()),
                 now() + make_interval(days => p_expires_days))
        end,
        updated_at = now()
    where id = p_rider_id;
  end if;

  select real_balance_iqd, bonus_balance_iqd
  into v_real, v_bonus
  from public.rider_wallets where id = p_rider_id;

  insert into public.balance_entries
    (user_id, kind, amount_iqd, reason, note, actor_id)
  values (p_rider_id, p_kind, p_amount, 'admin', btrim(p_note), auth.uid());

  perform public.log_action(
    'wallet.adjust', 'profiles', p_rider_id::text,
    format('%s — %s %s دينار (%s) — %s',
           v_name,
           case when p_amount > 0 then 'إضافة' else 'خصم' end,
           abs(p_amount)::bigint,
           case when p_kind = 'real' then 'فعلي' else 'هدية' end,
           btrim(p_note))
  );

  return jsonb_build_object('real', v_real, 'bonus', v_bonus);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) رصيدي — يقرؤه التطبيق
-- -----------------------------------------------------------------------------
create or replace function public.my_balance()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_role public.user_role;
  v_out  jsonb;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  select role into v_role from public.profiles where id = v_uid;

  if v_role = 'driver' then
    select jsonb_build_object(
             'real',  wallet_balance_iqd,
             'bonus', bonus_balance_iqd)
    into v_out from public.drivers where id = v_uid;
  else
    v_out := public.rider_spendable(v_uid);
  end if;

  return coalesce(v_out, jsonb_build_object('real', 0, 'bonus', 0));
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function
  public.admin_adjust_rider_balance(uuid, numeric, text, text, integer)
  from public, anon;
grant execute on function
  public.admin_adjust_rider_balance(uuid, numeric, text, text, integer)
  to authenticated;

revoke all on function public.rider_spendable(uuid) from public, anon;
grant execute on function public.rider_spendable(uuid) to authenticated;

revoke all on function public.my_balance() from public, anon;
grant execute on function public.my_balance() to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.rider_wallets)              as "محافظ ركّاب",
  (select count(*) from public.profiles where role='rider') as "ركّاب",
  (select count(*) from pg_trigger
   where tgname = 'trips_settle_rider_credit')             as "المُشغّل";
