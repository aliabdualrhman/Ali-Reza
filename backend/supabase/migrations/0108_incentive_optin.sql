-- =============================================================================
-- 0108 — السائق يفعّل الحافز، والمدير يحدّد كم حافزاً معاً
-- =============================================================================
-- طلب علي:
--
--   «الحافز يصل إشعارٌ به إلى السائق. ويدخل الحوافز فيرى «لا يوجد حافز»
--    أو يرى حافزاً **فيفعّله**. ويمكنه تفعيل حافزٍ أو اثنين معاً حسب ما
--    أختار من اللوحة.»
--
-- فثلاث إضافات على 0107:
--
--   ١) **جدول تفعيل**: لا يُحتسب حافزٌ لمن لم يفعّله.
--   ٢) **سقفٌ لعدد المفعَّلة معاً** يضبطه المدير (افتراضه واحد).
--   ٣) **إشعارٌ يُبثّ عند نشر الحافز** — ومُشغّل `notifications_push` يدفعه
--      إلى هواتف السائقين من تلقائه.
--
-- **والعدّاد يبدأ من لحظة التفعيل لا من بداية الحافز.** من فعّله بعد يومين
-- لا يأخذ رحلات اليومين الماضيين: الحافز أجرٌ على جهدٍ قادم، لا مكافأةٌ
-- على ما مضى. وهذا أيضاً يجعل «فعّل» فعلاً له معنى.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) التفعيل
-- -----------------------------------------------------------------------------
create table if not exists public.incentive_optins (
  incentive_id uuid not null references public.incentives(id) on delete cascade,
  driver_id    uuid not null references public.drivers(id) on delete cascade,
  opted_at     timestamptz not null default now(),
  primary key (incentive_id, driver_id)
);

alter table public.incentive_optins enable row level security;

drop policy if exists incentive_optins_read on public.incentive_optins;
create policy incentive_optins_read on public.incentive_optins
  for select to authenticated
  using (driver_id = auth.uid()
         or public.has_perm('incentives.view')
         or public.has_perm('incentives.manage'));
-- لا سياسة كتابة: التفعيل والإلغاء بدالّتين تفحصان السقف.

alter table public.incentives
  add column if not exists notified_at timestamptz;

insert into public.public_settings (key, value)
values ('incentives_max_active', '1')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- ٢) العدّاد يبدأ من التفعيل
-- -----------------------------------------------------------------------------
create or replace function public.incentive_counters(
  p_driver_id uuid,
  p_incentive public.incentives
)
returns table (trips integer, hours numeric)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  with w as (
    select greatest(
             p_incentive.starts_at,
             coalesce((select o.opted_at from public.incentive_optins o
                       where o.incentive_id = p_incentive.id
                         and o.driver_id = p_driver_id),
                      -- لم يفعّل: نافذةٌ فارغة، فلا يُحتسب له شيء.
                      p_incentive.ends_at)
           ) as from_at,
           least(now(), p_incentive.ends_at) as to_at
  )
  select
    (select count(*)::integer
     from public.trips t, w
     where t.driver_id = p_driver_id
       and t.status = 'completed'
       and t.completed_at >= w.from_at
       and t.completed_at <= w.to_at
       and (p_incentive.trip_kinds is null
            or t.kind = any(p_incentive.trip_kinds))),
    (select round(
       public.driver_online_seconds(p_driver_id, w.from_at, w.to_at) / 3600.0,
       2) from w);
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الصرف للمفعِّلين وحدهم
-- -----------------------------------------------------------------------------
-- منسوخةٌ من 0107، والتغيير شرطُ التفعيل في حلقة الحوافز.
create or replace function public.evaluate_incentives(p_driver_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_inc   public.incentives;
  v_tier  public.incentive_tiers;
  v_kind  public.vehicle_kind;
  v_trips integer;
  v_hours numeric;
  v_paid  integer := 0;
begin
  if p_driver_id is null then return 0; end if;

  select vehicle_kind into v_kind from public.drivers where id = p_driver_id;
  if v_kind is null then return 0; end if;

  for v_inc in
    select i.* from public.incentives i
    join public.incentive_optins o
      on o.incentive_id = i.id and o.driver_id = p_driver_id
    where i.is_active
      and now() between i.starts_at and i.ends_at
      and (i.vehicle_kinds is null or v_kind = any(i.vehicle_kinds))
  loop
    select c.trips, c.hours into v_trips, v_hours
    from public.incentive_counters(p_driver_id, v_inc) c;

    for v_tier in
      select t.* from public.incentive_tiers t
      where t.incentive_id = v_inc.id
        and v_trips >= t.trips_required
        and v_hours >= t.hours_required
        and not exists (
          select 1 from public.incentive_awards a
          where a.tier_id = t.id and a.driver_id = p_driver_id
        )
      order by t.sort_order
    loop
      begin
        insert into public.incentive_awards
          (incentive_id, tier_id, driver_id, amount_iqd, reward_kind)
        values (v_inc.id, v_tier.id, p_driver_id, v_tier.reward_iqd,
                v_inc.reward_kind);
      exception when unique_violation then
        continue;
      end;

      if v_inc.reward_kind = 'real' then
        perform public.post_wallet_transaction(
          p_driver_id   => p_driver_id,
          p_txn_type    => 'adjustment',
          p_amount_iqd  => v_tier.reward_iqd,
          p_description => format('حافز: %s', v_inc.title)
        );
        insert into public.balance_entries
          (user_id, kind, amount_iqd, reason, note)
        values (p_driver_id, 'real', v_tier.reward_iqd, 'admin',
                format('حافز: %s', v_inc.title));
      else
        perform set_config('app.bypass_guards', 'on', true);
        update public.drivers
        set bonus_balance_iqd = coalesce(bonus_balance_iqd, 0) + v_tier.reward_iqd
        where id = p_driver_id;
        perform set_config('app.bypass_guards', 'off', true);

        insert into public.balance_entries
          (user_id, kind, amount_iqd, reason, note)
        values (p_driver_id, 'bonus', v_tier.reward_iqd, 'admin',
                format('حافز: %s', v_inc.title));
      end if;

      insert into public.notifications (user_id, title, body, kind, audience)
      values (
        p_driver_id,
        'حصلت على حافز',
        format('%s — %s دينار %s',
               v_inc.title, v_tier.reward_iqd::bigint,
               case when v_inc.reward_kind = 'real'
                    then 'أُضيفت إلى رصيدك'
                    else 'رصيد هدية يُخصم من عمولتك' end),
        'incentive', 'driver'
      );

      v_paid := v_paid + 1;
    end loop;
  end loop;

  return v_paid;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) يفعّل ويُلغي
-- -----------------------------------------------------------------------------
create or replace function public.activate_incentive(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_kind public.vehicle_kind;
  v_inc  public.incentives;
  v_max  integer;
  v_now  integer;
begin
  select vehicle_kind into v_kind from public.drivers where id = v_uid;
  if v_kind is null then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  select * into v_inc from public.incentives where id = p_id;
  if v_inc.id is null then raise exception 'الحافز غير موجود'; end if;
  if not v_inc.is_active or now() not between v_inc.starts_at and v_inc.ends_at then
    raise exception 'هذا الحافز غير متاح الآن';
  end if;
  if v_inc.vehicle_kinds is not null and not (v_kind = any(v_inc.vehicle_kinds)) then
    raise exception 'هذا الحافز ليس لمركبتك';
  end if;

  v_max := greatest(1, public.referral_setting('incentives_max_active', 1)::integer);

  -- **تُعدّ المفعَّلة الجارية وحدها.** حافزٌ فعّله الشهر الماضي وانتهى لا
  -- يجوز أن يسدّ مكاناً اليوم.
  select count(*) into v_now
  from public.incentive_optins o
  join public.incentives i on i.id = o.incentive_id
  where o.driver_id = v_uid
    and i.is_active
    and now() between i.starts_at and i.ends_at;

  if exists (select 1 from public.incentive_optins
             where incentive_id = p_id and driver_id = v_uid) then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  if v_now >= v_max then
    raise exception 'يمكنك تفعيل % حافزاً في وقتٍ واحد. ألغِ واحداً أولاً.', v_max;
  end if;

  insert into public.incentive_optins (incentive_id, driver_id)
  values (p_id, v_uid);

  return jsonb_build_object('ok', true, 'already', false);
end;
$fn$;

revoke all on function public.activate_incentive(uuid) from public, anon;
grant execute on function public.activate_incentive(uuid) to authenticated;


create or replace function public.deactivate_incentive(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  -- **من نال مستوىً لا يُلغي.** الإلغاء بعد الصرف يفتح باب التفعيل
  -- والإلغاء دورةً بعد دورة على الحافز نفسه.
  if exists (select 1 from public.incentive_awards
             where incentive_id = p_id and driver_id = auth.uid()) then
    raise exception 'نلتَ مكافأةً من هذا الحافز — لا يمكن إلغاؤه';
  end if;

  delete from public.incentive_optins
  where incentive_id = p_id and driver_id = auth.uid();
end;
$fn$;

revoke all on function public.deactivate_incentive(uuid) from public, anon;
grant execute on function public.deactivate_incentive(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) ما يقرؤه تطبيق السائق — مع حالة التفعيل
-- -----------------------------------------------------------------------------
create or replace function public.my_incentives()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_kind   public.vehicle_kind;
  v_inc    public.incentives;
  v_trips  integer;
  v_hours  numeric;
  v_on     boolean;
  v_max    integer;
  v_active integer;
  v_out    jsonb := '[]'::jsonb;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  select vehicle_kind into v_kind from public.drivers where id = v_uid;
  if v_kind is null then
    return jsonb_build_object('items', '[]'::jsonb, 'max_active', 1,
                              'active_count', 0, 'earned_total', 0);
  end if;

  perform public.evaluate_incentives(v_uid);

  v_max := greatest(1, public.referral_setting('incentives_max_active', 1)::integer);

  select count(*) into v_active
  from public.incentive_optins o
  join public.incentives i on i.id = o.incentive_id
  where o.driver_id = v_uid
    and i.is_active
    and now() between i.starts_at and i.ends_at;

  for v_inc in
    select * from public.incentives
    where is_active
      and now() between starts_at and ends_at
      and (vehicle_kinds is null or v_kind = any(vehicle_kinds))
    order by ends_at
  loop
    v_on := exists (select 1 from public.incentive_optins
                    where incentive_id = v_inc.id and driver_id = v_uid);

    select c.trips, c.hours into v_trips, v_hours
    from public.incentive_counters(v_uid, v_inc) c;

    v_out := v_out || jsonb_build_object(
      'id',          v_inc.id,
      'title',       v_inc.title,
      'description', v_inc.description,
      'starts_at',   v_inc.starts_at,
      'ends_at',     v_inc.ends_at,
      'reward_kind', v_inc.reward_kind,
      'activated',   v_on,
      'opted_at', (select opted_at from public.incentive_optins
                   where incentive_id = v_inc.id and driver_id = v_uid),
      -- لا عدّاد لمن لم يفعّل: صفرٌ حتى يضغط «فعّل».
      'trips',       case when v_on then v_trips else 0 end,
      'hours',       case when v_on then v_hours else 0 end,
      'tiers', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'trips_required', t.trips_required,
                 'hours_required', t.hours_required,
                 'reward_iqd',     t.reward_iqd,
                 'earned', exists (
                   select 1 from public.incentive_awards a
                   where a.tier_id = t.id and a.driver_id = v_uid)
               ) order by t.sort_order), '[]'::jsonb)
        from public.incentive_tiers t where t.incentive_id = v_inc.id
      )
    );
  end loop;

  return jsonb_build_object(
    'items', v_out,
    'max_active', v_max,
    'active_count', v_active,
    'earned_total', (select coalesce(sum(amount_iqd), 0)
                     from public.incentive_awards where driver_id = v_uid)
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) إشعار النشر، وسقف المفعَّلة في اللوحة
-- -----------------------------------------------------------------------------
-- **مرّةً واحدة لكل حافز.** `notified_at` يمنع تكرار الإشعار كلما عُدّل
-- الحافز أو أُوقف ثم فُعّل.
create or replace function public.announce_incentive(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_inc public.incentives;
  v_top numeric;
begin
  select * into v_inc from public.incentives where id = p_id;
  if v_inc.id is null or v_inc.notified_at is not null then return; end if;
  if not v_inc.is_active or now() > v_inc.ends_at then return; end if;

  select max(reward_iqd) into v_top
  from public.incentive_tiers where incentive_id = p_id;

  -- إدراج الصفّ يكفي: مُشغّل `notifications_push` يدفعه إلى الهواتف.
  insert into public.notifications (audience, title, body, kind, recipients)
  values (
    'driver',
    'حافز جديد: ' || v_inc.title,
    format('افتح «الحوافز» وفعّله — حتى %s دينار. ينتهي %s',
           coalesce(v_top, 0)::bigint,
           to_char(v_inc.ends_at at time zone 'Asia/Baghdad', 'MM-DD HH24:MI')),
    'incentive',
    (select count(*) from public.drivers)
  );

  update public.incentives set notified_at = now() where id = p_id;
end;
$fn$;

revoke all on function public.announce_incentive(uuid) from public, anon;
grant execute on function public.announce_incentive(uuid) to authenticated;


-- يُستدعى من الحفظ والتفعيل: الإعلان يتبع النشر لا يسبقه.
create or replace function public.admin_set_incentive_active(
  p_id uuid, p_active boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.has_perm('incentives.manage') then
    raise exception 'لا تملك صلاحية إدارة الحوافز'
      using errcode = 'insufficient_privilege';
  end if;

  update public.incentives set is_active = p_active where id = p_id;

  if p_active then
    perform public.announce_incentive(p_id);
  end if;

  perform public.log_action('incentive.active', 'incentive', p_id::text,
    case when p_active then 'فُعِّل حافز' else 'أُوقف حافز' end);
end;
$fn$;


create or replace function public.admin_set_incentives_max(p_max integer)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.has_perm('incentives.manage') then
    raise exception 'لا تملك صلاحية إدارة الحوافز'
      using errcode = 'insufficient_privilege';
  end if;
  if p_max < 1 or p_max > 5 then
    raise exception 'العدد بين ١ و٥';
  end if;

  insert into public.public_settings (key, value)
  values ('incentives_max_active', p_max::text)
  on conflict (key) do update set value = excluded.value;

  perform public.log_action('incentive.max', 'public_settings',
    'incentives_max_active', format('سقف الحوافز المفعَّلة معاً: %s', p_max));
end;
$fn$;

revoke all on function public.admin_set_incentives_max(integer) from public, anon;
grant execute on function public.admin_set_incentives_max(integer) to authenticated;


-- ولوحة المدير ترى من فعّل: رقمٌ يقول هل وصل الحافز الناس أم لا.
create or replace function public.admin_incentives()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
begin
  if not (public.has_perm('incentives.view')
          or public.has_perm('incentives.manage')) then
    raise exception 'لا تملك صلاحية رؤية الحوافز'
      using errcode = 'insufficient_privilege';
  end if;

  return jsonb_build_object(
    'max_active',
      greatest(1, public.referral_setting('incentives_max_active', 1)::integer),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'title', i.title, 'description', i.description,
        'starts_at', i.starts_at, 'ends_at', i.ends_at,
        'reward_kind', i.reward_kind, 'is_active', i.is_active,
        'vehicle_kinds', i.vehicle_kinds, 'trip_kinds', i.trip_kinds,
        'tiers', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'id', t.id, 'trips_required', t.trips_required,
                   'hours_required', t.hours_required,
                   'reward_iqd', t.reward_iqd) order by t.sort_order), '[]'::jsonb)
          from public.incentive_tiers t where t.incentive_id = i.id),
        'optins', (select count(*) from public.incentive_optins o
                   where o.incentive_id = i.id),
        'awards_count', (select count(*) from public.incentive_awards a
                         where a.incentive_id = i.id),
        'awards_total', (select coalesce(sum(a.amount_iqd), 0)
                         from public.incentive_awards a
                         where a.incentive_id = i.id)
      ) order by i.starts_at desc)
      from public.incentives i), '[]'::jsonb)
  );
end;
$fn$;


-- والحفظ يُعلن الحافز الجديد.
--
-- **المرساة سطرٌ واحد بلا نهاية سطر.** جرّبتها أولاً مع نهاية السطر
-- بعدها فرفضت القاعدة الترحيل كلّه: التعريف الحيّ مكتوبٌ بنهايات سطر
-- ويندوز، ولا يطابق ما كتبناه. والسطر وحده يكفي — وهو يرد مرةً واحدة.
do $do$
declare
  v_def text;
  v_old constant text := '  return v_id;';
  v_n   integer;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'admin_save_incentive';

  if v_def is null then
    raise exception 'admin_save_incentive غير موجودة — طبّق 0107 أولاً';
  end if;
  if position('announce_incentive' in v_def) > 0 then
    return;  -- طُبّق من قبل
  end if;

  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then
    raise exception 'admin_save_incentive: المرساة وردت % مرة لا مرةً واحدة', v_n;
  end if;

  execute replace(
    v_def, v_old,
    '  perform public.announce_incentive(v_id);' || chr(10) || '  return v_id;');
end;
$do$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_class where relname = 'incentive_optins')      as "جدول التفعيل (١)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('activate_incentive', 'deactivate_incentive',
                     'announce_incentive', 'admin_set_incentives_max'))    as "الدوال (٤)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname = 'evaluate_incentives' and prosrc like '%incentive_optins%') as "الصرف للمفعِّلين (١)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname = 'admin_save_incentive' and prosrc like '%announce_incentive%') as "الحفظ يُعلن (١)",
  (select value from public.public_settings where key = 'incentives_max_active') as "السقف";
