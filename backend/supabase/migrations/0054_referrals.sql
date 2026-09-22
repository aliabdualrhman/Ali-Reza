-- =============================================================================
-- 0054 — نظام الدعوة
-- =============================================================================
-- **أرخص قناة نموّ في سوقنا.** سائقٌ يدعو سائقاً، وراكبٌ يدعو راكباً،
-- فيأخذ الداعي رصيد هدية بعد أن يُثبت المدعوّ أنه مستخدمٌ حقيقي.
--
-- **والمكافأة ليست نقداً من الخزينة.** محفظة السائق سالبها دَين عمولات،
-- فإضافة خمسة آلاف إليها إعفاءٌ من عمولةٍ لم تُكسب بعد. وهديةُ الراكب
-- تُنفق على أجرةٍ نُعوّض السائق عنها. **ورقةٌ تُمحى لا نقدٌ يُدفع.**
--
-- ------------------------------------------------------------------
-- الحراسات الستّ — وهي نصف الملف
-- ------------------------------------------------------------------
-- نظام مكافآت في سوق نقدي، وأرقام الهواتف تُشترى بألف دينار. فبلا
-- حراسة يصير الباب مطبعةَ نقود:
--
--   ١. **رقم هاتف فريد** — قائمٌ في `profiles.phone ... unique` (0002).
--
--   ٢. **جهاز فريد** — لا يُكافَأ داعٍ ومدعوٌّ يتشاركان جهازاً. نقرؤه من
--      `user_devices` (0048).
--
--   ٣. **ثلاث رحلات مؤهِّلة** — لا رحلة واحدة. من ركب مرة قد يكون حساباً
--      وهمياً؛ ومن ركب ثلاثاً صار زبوناً، وهو ما ندفع من أجله.
--
--   ٤. **لا رحلة أُنهيت بعيداً** — محسوبةٌ في `qualifying_trip_count`
--      (0053)، ومعها حدّا المسافة والأجرة.
--
--   ٥. **الداعي والمدعوّ ليسا طرفَي رحلة واحدة** — وإلا نقل السائق صديقه
--      ثلاث مرات وقبض ثمن ذلك مكافأةً.
--
--   ٦. **سقفٌ كلّي لا شهري** — دعوتان لكل شخص مدى الحياة. الشهري يتجدّد،
--      والكلّي يُغلق الباب.
--
-- ------------------------------------------------------------------
-- ولماذا الصرف بمُشغّل لا بمهمّة دورية؟
-- ------------------------------------------------------------------
-- لأن المهمّة الدورية تتأخر أو تتعطّل — وقد رأينا ذلك في `dispatch_tick`
-- حين توقّفت شهراً بلا أن يلاحظ أحد. والمُشغّل يعمل لحظة اكتمال الرحلة
-- الثالثة، فيصل الإشعار والداعي ما زال يذكر من دعا.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الإعدادات — كلها من اللوحة
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('referral_enabled',          'true', 'تفعيل نظام الدعوة'),
  ('referral_driver_bonus_iqd', '5000', 'مكافأة السائق الذي يدعو سائقاً'),
  ('referral_rider_bonus_iqd',  '2000', 'مكافأة الراكب الذي يدعو راكباً'),
  ('referral_required_trips',   '3',    'عدد الرحلات المؤهِّلة لصرف المكافأة'),
  ('referral_max_per_user',     '2',    'سقف الدعوات المكافأة لكل شخص (كلّي)'),
  ('referral_bonus_expiry_days','30',   'صلاحية رصيد الهدية بالأيام'),
  ('referral_code_grace_days',  '7',    'مهلة إدخال رمز الدعوة بعد التسجيل')
on conflict (key) do nothing;


create or replace function public.referral_setting(p_key text, p_default numeric)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select coalesce(
    (select nullif(btrim(value), '')::numeric
     from public.public_settings where key = p_key),
    p_default);
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) رمز الدعوة
-- -----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists referral_code text unique,

  -- **من أين سمع عنّا؟** يطلبه المدير في ملفه، وهو أرخص بحث تسويقي:
  -- يخبرك أيّ قناة تجلب فعلاً قبل أن تنفق ديناراً على الإعلان.
  add column if not exists heard_from text,
  add column if not exists heard_from_note text;

comment on column public.profiles.referral_code is
  'رمز يشاركه صاحبه ليدعو غيره. يُولَّد مرة ولا يتغيّر.';
comment on column public.profiles.heard_from is
  'من أين سمع عن التطبيق: ad · street · friend · other';


-- **بلا حروف تلتبس ولا أرقام تُقرأ خطأً.** الرمز يُملى على الهاتف أو
-- يُكتب من صورة، و`0/O` و`1/I` تُفسد ثلث المحاولات.
create or replace function public.generate_referral_code()
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $fn$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code  text;
  v_try   integer := 0;
begin
  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
    end loop;

    exit when not exists (
      select 1 from public.profiles where referral_code = v_code);

    v_try := v_try + 1;
    -- ٣٢^٦ ≈ مليار احتمال. عشر محاولات فاشلة تعني عطلاً لا تزاحماً.
    if v_try > 10 then
      raise exception 'تعذّر توليد رمز دعوة';
    end if;
  end loop;

  return v_code;
end;
$fn$;


-- **يُولَّد عند الطلب لا عند التسجيل.** أكثر المستخدمين لن يدعوا أحداً،
-- وتوليدُ رمزٍ لكل حساب يملأ الجدول بما لا يُقرأ. ومن يفتح شاشة الدعوة
-- يُولَّد له في تلك اللحظة.
create or replace function public.my_referral_code()
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_code text;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  select referral_code into v_code from public.profiles where id = v_uid;
  if v_code is not null then return v_code; end if;

  v_code := public.generate_referral_code();
  update public.profiles set referral_code = v_code where id = v_uid;
  return v_code;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الدعوات
-- -----------------------------------------------------------------------------
create table if not exists public.referrals (
  id           uuid primary key default gen_random_uuid(),

  inviter_id   uuid not null references public.profiles(id) on delete cascade,

  -- **المدعوّ مفتاحٌ فريد.** لا يُدعى مرتين ولا يُنسب لداعيَين.
  invitee_id   uuid not null unique
               references public.profiles(id) on delete cascade,

  code_used    text not null,

  -- pending: أُدخل الرمز ولم تكتمل الشروط
  -- rewarded: صُرفت المكافأة
  -- rejected: سقطت بحارسٍ من الحراسات
  status       text not null default 'pending'
               check (status in ('pending', 'rewarded', 'rejected')),

  reward_iqd   numeric(10,2),
  rejection    text,

  created_at   timestamptz not null default now(),
  rewarded_at  timestamptz
);

create index if not exists referrals_inviter_idx
  on public.referrals (inviter_id, status);

comment on table public.referrals is
  'من دعا من. المدعوّ فريد فلا يُنسب لداعيَين ولا يُكافأ مرتين.';

alter table public.referrals enable row level security;

-- يرى دعواته هو. **ولا يرى من دعاه** — لا فائدة له فيها، وفيها اسم غيره.
drop policy if exists referrals_own_read on public.referrals;
create policy referrals_own_read on public.referrals
  for select to authenticated
  using (inviter_id = auth.uid() or public.is_admin());


-- -----------------------------------------------------------------------------
-- ٤) إدخال الرمز
-- -----------------------------------------------------------------------------
-- يُستدعى عند التسجيل، أو لاحقاً من «حسابي» خلال مهلة السماح.
--
-- **ولماذا مهلة سماح أصلاً؟** لأن الرمز يُنسى وقت التسجيل: الرجل واقفٌ
-- في الشارع يسجّل ولا يتذكّر أن يتصل بصديقه. والمهلة تكسب ثلث الدعوات
-- الضائعة بلا كلفة.
create or replace function public.redeem_referral_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid       uuid := auth.uid();
  v_me        public.profiles;
  v_inviter   public.profiles;
  v_code      text := upper(btrim(p_code));
  v_grace     integer;
  v_cap       integer;
  v_rewarded  integer;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  if public.referral_setting('referral_enabled', 1) = 0 then
    raise exception 'نظام الدعوة متوقّف حالياً';
  end if;

  select * into v_me from public.profiles where id = v_uid;

  if exists (select 1 from public.referrals where invitee_id = v_uid) then
    raise exception 'أدخلتَ رمز دعوة من قبل';
  end if;

  -- ---- مهلة السماح ----
  v_grace := public.referral_setting('referral_code_grace_days', 7)::integer;
  if v_me.created_at < now() - make_interval(days => v_grace) then
    raise exception 'انتهت مهلة إدخال رمز الدعوة (% أيام من التسجيل)', v_grace;
  end if;

  select * into v_inviter from public.profiles where referral_code = v_code;
  if v_inviter.id is null then
    raise exception 'رمز الدعوة غير صحيح';
  end if;

  -- ---- حارس: لا يدعو نفسه ----
  if v_inviter.id = v_uid then
    raise exception 'لا يمكنك استعمال رمزك';
  end if;

  -- ---- حارس: الدور نفسه ----
  -- **سائقٌ يدعو سائقاً وراكبٌ يدعو راكباً.** المكافأتان مختلفتان
  -- ومصدراهما مختلفان، وخلطُهما يفتح باباً لا نعرف كلفته.
  if v_inviter.role is distinct from v_me.role then
    raise exception 'رمز الدعوة لا يصلح لهذا النوع من الحسابات';
  end if;

  if v_me.role = 'admin' or v_inviter.role = 'admin' then
    raise exception 'حسابات المشرفين خارج نظام الدعوة';
  end if;

  -- ---- الحارس ٢: جهاز مشترك ----
  -- من يسجّل حسابين على هاتفٍ واحد لا يدعو صديقاً بل نفسه.
  if exists (
    select 1
    from public.user_devices a
    join public.user_devices b on b.token = a.token
    where a.user_id = v_inviter.id and b.user_id = v_uid
  ) then
    raise exception 'تعذّر قبول الرمز';   -- عمداً بلا تفصيل: لا نُعلّم المحتال
  end if;

  -- ---- الحارس ٦: السقف الكلّي ----
  v_cap := public.referral_setting('referral_max_per_user', 2)::integer;
  select count(*) into v_rewarded
  from public.referrals
  where inviter_id = v_inviter.id and status = 'rewarded';

  if v_rewarded >= v_cap then
    raise exception 'بلغ صاحب هذا الرمز الحد الأقصى للدعوات';
  end if;

  insert into public.referrals (inviter_id, invitee_id, code_used)
  values (v_inviter.id, v_uid, v_code);

  return jsonb_build_object(
    'inviter', split_part(v_inviter.full_name, ' ', 1),
    'required_trips',
      public.referral_setting('referral_required_trips', 3)::integer
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) الصرف — تلقائيّ عند اكتمال الرحلة المؤهِّلة
-- -----------------------------------------------------------------------------
create or replace function public.try_award_referral()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_ref     public.referrals;
  v_role    public.user_role;
  v_needed  integer;
  v_done    integer;
  v_amount  numeric(10,2);
  v_expiry  integer;
  v_cap     integer;
  v_rewarded integer;
begin
  if public.referral_setting('referral_enabled', 1) = 0 then
    return new;
  end if;

  -- الطرفان يُفحصان: قد يكون المدعوّ راكب الرحلة أو سائقها.
  for v_ref in
    select * from public.referrals
    where invitee_id in (new.rider_id, new.driver_id)
      and status = 'pending'
  loop
    select role into v_role from public.profiles where id = v_ref.invitee_id;

    -- ---- الحارس ٥: الداعي والمدعوّ في رحلة واحدة ----
    -- **يُفحص هنا لا عند إدخال الرمز**، لأن الرحلة لم تكن قد وقعت بعد.
    if v_ref.inviter_id in (new.rider_id, new.driver_id) then
      update public.referrals
      set status = 'rejected',
          rejection = 'الداعي والمدعوّ طرفا رحلة واحدة'
      where id = v_ref.id;
      continue;
    end if;

    v_needed := public.referral_setting('referral_required_trips', 3)::integer;
    v_done   := public.qualifying_trip_count(v_ref.invitee_id, v_ref.created_at);

    if v_done < v_needed then continue; end if;

    -- ---- السقف يُفحص ثانيةً ----
    -- بين إدخال الرمز والصرف قد تُصرف دعوات أخرى للداعي نفسه.
    v_cap := public.referral_setting('referral_max_per_user', 2)::integer;
    select count(*) into v_rewarded
    from public.referrals
    where inviter_id = v_ref.inviter_id and status = 'rewarded';

    if v_rewarded >= v_cap then
      update public.referrals
      set status = 'rejected', rejection = 'بلغ الداعي السقف'
      where id = v_ref.id;
      continue;
    end if;

    v_amount := case when v_role = 'driver'
      then public.referral_setting('referral_driver_bonus_iqd', 5000)
      else public.referral_setting('referral_rider_bonus_iqd', 2000)
    end;

    perform set_config('app.bypass_guards', 'on', true);

    if v_role = 'driver' then
      update public.drivers
      set bonus_balance_iqd = bonus_balance_iqd + v_amount
      where id = v_ref.inviter_id;
    else
      v_expiry := public.referral_setting('referral_bonus_expiry_days', 30)::integer;

      insert into public.rider_wallets (id) values (v_ref.inviter_id)
      on conflict (id) do nothing;

      update public.rider_wallets
      set bonus_balance_iqd = bonus_balance_iqd + v_amount,
          bonus_expires_at  = greatest(
            coalesce(bonus_expires_at, now()),
            now() + make_interval(days => v_expiry)),
          updated_at = now()
      where id = v_ref.inviter_id;
    end if;

    update public.referrals
    set status = 'rewarded', reward_iqd = v_amount, rewarded_at = now()
    where id = v_ref.id;

    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, note)
    values (v_ref.inviter_id, 'bonus', v_amount, 'referral',
            'مكافأة دعوة صديق');

    perform set_config('app.bypass_guards', 'off', true);

    perform public.log_action(
      'referral.reward', 'referrals', v_ref.id::text,
      format('%s دينار — دعوة %s', v_amount::bigint, v_role)
    );
  end loop;

  return new;
end;
$fn$;

drop trigger if exists trips_award_referral on public.trips;
create trigger trips_award_referral
  after update of status on public.trips
  for each row
  when (new.status = 'completed' and old.status <> 'completed')
  execute function public.try_award_referral();


-- -----------------------------------------------------------------------------
-- ٦) حالة دعواتي — تقرؤها شاشة «ادعُ صديقاً»
-- -----------------------------------------------------------------------------
create or replace function public.my_referrals()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_role public.user_role;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;
  select role into v_role from public.profiles where id = v_uid;

  return jsonb_build_object(
    'code',   (select referral_code from public.profiles where id = v_uid),
    'reward', case when v_role = 'driver'
                then public.referral_setting('referral_driver_bonus_iqd', 5000)
                else public.referral_setting('referral_rider_bonus_iqd', 2000)
              end,
    'required_trips',
      public.referral_setting('referral_required_trips', 3)::integer,
    'cap', public.referral_setting('referral_max_per_user', 2)::integer,
    'rewarded', (select count(*) from public.referrals
                 where inviter_id = v_uid and status = 'rewarded'),
    'pending',  (select count(*) from public.referrals
                 where inviter_id = v_uid and status = 'pending'),
    'earned',   coalesce((select sum(reward_iqd) from public.referrals
                          where inviter_id = v_uid and status = 'rewarded'), 0)
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.my_referral_code()          from public, anon;
revoke all on function public.redeem_referral_code(text)  from public, anon;
revoke all on function public.my_referrals()              from public, anon;
revoke all on function public.generate_referral_code()    from public, anon;

grant execute on function public.my_referral_code()         to authenticated;
grant execute on function public.redeem_referral_code(text) to authenticated;
grant execute on function public.my_referrals()             to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select key as "الإعداد", value as "القيمة", label as "الوصف"
from public.public_settings
where key like 'referral%'
order by key;
