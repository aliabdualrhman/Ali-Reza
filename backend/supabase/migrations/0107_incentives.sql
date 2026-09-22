-- =============================================================================
-- 0107 — الحوافز: هدفٌ ومكافأة، والصرف تلقائيّ
-- =============================================================================
-- طلب علي:
--
--   «أكمل ٢٠ رحلة خلال من–إلى فتأخذ ٣٠٠٠، وأكمل ٣٠ فتأخذ ١٠٠٠٠. المدّة
--    أنا أختارها: ساعة، أو يوماً، أو أسبوعاً. والشرط رحلاتٌ أو ساعات
--    اتصال أو مزيج. والمكافأة رصيد حقيقي يُسحب أو هدية — حسب الحافز.
--    والتقدّم تلقائيّ بلا تدخّل. وأنا أصوغ الحافز كاملاً من اللوحة.»
--
-- فثلاثة جداول: الحافز، ومستوياته، وما نالَه كل سائق.
--
-- **ولماذا المستويات جدولٌ لا عمودان؟** لأن «٢٠ ← ٣٠٠٠ و٣٠ ← ١٠٠٠٠»
-- مستويان في حافزٍ واحد، وقد يصيرا خمسة. وعمودان يعنيان حافزين
-- منفصلين يتسابق السائق فيهما على العدّاد نفسه.
--
-- **والصرف مرةً واحدة لكل مستوى.** فهرسٌ فريد على (المستوى، السائق) هو
-- الضمانة الأخيرة: رحلتان تنتهيان في اللحظة نفسها تقرآن «لم يُصرف بعد»
-- كلتاهما، وتسقط الثانية عند الإدراج.
--
-- **ولا مؤقّت في النظام.** التقييم يجري عند حدثٍ يغيّر العدّاد: انتهاء
-- رحلة، أو إغلاق جلسة اتصال. فلا نحتاج cron ولا خادماً يستيقظ.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الجداول
-- -----------------------------------------------------------------------------
create table if not exists public.incentives (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  description   text,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,

  -- `null` = كل المركبات / كل أنواع الطلبات.
  vehicle_kinds public.vehicle_kind[],
  trip_kinds    public.trip_kind[],

  -- 'real' يُسحب نقداً، 'bonus' يُنفق على العمولة (0103).
  reward_kind   text not null default 'bonus'
                check (reward_kind in ('real', 'bonus')),

  is_active     boolean not null default true,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now(),

  check (ends_at > starts_at)
);

create table if not exists public.incentive_tiers (
  id             uuid primary key default gen_random_uuid(),
  incentive_id   uuid not null references public.incentives(id) on delete cascade,
  trips_required integer not null default 0,
  hours_required numeric(6,2) not null default 0,
  reward_iqd     numeric(12,2) not null,
  sort_order     smallint not null default 1,

  check (reward_iqd > 0),
  check (trips_required >= 0 and hours_required >= 0),
  check (trips_required > 0 or hours_required > 0)
);

create index if not exists incentive_tiers_incentive
  on public.incentive_tiers (incentive_id, sort_order);

create table if not exists public.incentive_awards (
  id           uuid primary key default gen_random_uuid(),
  incentive_id uuid not null references public.incentives(id) on delete cascade,
  tier_id      uuid not null references public.incentive_tiers(id) on delete cascade,
  driver_id    uuid not null references public.drivers(id) on delete cascade,
  amount_iqd   numeric(12,2) not null,
  reward_kind  text not null,
  awarded_at   timestamptz not null default now()
);

-- **الضمانة الأخيرة ضد الصرف مرتين.**
create unique index if not exists incentive_awards_once
  on public.incentive_awards (tier_id, driver_id);

create index if not exists incentive_awards_driver
  on public.incentive_awards (driver_id, awarded_at desc);


-- -----------------------------------------------------------------------------
-- ٢) الصلاحيات والقراءة
-- -----------------------------------------------------------------------------
insert into public.permission_catalog (code, label, sort_order, page) values
  ('incentives.view',   'رؤية الحوافز والعروض',                 130, 'الحوافز'),
  ('incentives.manage', 'إنشاء الحوافز وتعديلها وإيقافها',      131, 'الحوافز')
on conflict (code) do update
  set label = excluded.label, sort_order = excluded.sort_order, page = excluded.page;

alter table public.incentives       enable row level security;
alter table public.incentive_tiers  enable row level security;
alter table public.incentive_awards enable row level security;

-- **السائق يرى الحوافز الجارية وحدها.** الماضية والمعطّلة تُربكه:
-- يقرأ هدفاً فات وقته فيظنّه متاحاً.
drop policy if exists incentives_read on public.incentives;
create policy incentives_read on public.incentives
  for select to authenticated
  using (
    (is_active and now() between starts_at and ends_at)
    or public.has_perm('incentives.view')
    or public.has_perm('incentives.manage')
  );

drop policy if exists incentives_manage on public.incentives;
create policy incentives_manage on public.incentives
  for all to authenticated
  using (public.has_perm('incentives.manage'))
  with check (public.has_perm('incentives.manage'));

drop policy if exists incentive_tiers_read on public.incentive_tiers;
create policy incentive_tiers_read on public.incentive_tiers
  for select to authenticated using (true);

drop policy if exists incentive_tiers_manage on public.incentive_tiers;
create policy incentive_tiers_manage on public.incentive_tiers
  for all to authenticated
  using (public.has_perm('incentives.manage'))
  with check (public.has_perm('incentives.manage'));

drop policy if exists incentive_awards_read on public.incentive_awards;
create policy incentive_awards_read on public.incentive_awards
  for select to authenticated
  using (driver_id = auth.uid()
         or public.has_perm('incentives.view')
         or public.has_perm('incentives.manage'));
-- لا سياسة كتابة على الجوائز: تُصرف من الدالة وحدها.


-- -----------------------------------------------------------------------------
-- ٣) عدّاد السائق في حافز
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
  select
    (select count(*)::integer
     from public.trips t
     where t.driver_id = p_driver_id
       and t.status = 'completed'
       and t.completed_at >= p_incentive.starts_at
       and t.completed_at <= p_incentive.ends_at
       and (p_incentive.trip_kinds is null
            or t.kind = any(p_incentive.trip_kinds))),
    round(public.driver_online_seconds(
            p_driver_id, p_incentive.starts_at,
            least(now(), p_incentive.ends_at)) / 3600.0, 2);
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) التقييم والصرف
-- -----------------------------------------------------------------------------
-- **تُستدعى بعد كل حدثٍ يغيّر العدّاد**، وهي صامتة إن لم يستحقّ شيئاً.
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
    select * from public.incentives
    where is_active
      and now() between starts_at and ends_at
      and (vehicle_kinds is null or v_kind = any(vehicle_kinds))
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
      -- الفهرس الفريد يحسم السباق: من يصل ثانياً يسقط هنا بلا ضرر.
      begin
        insert into public.incentive_awards
          (incentive_id, tier_id, driver_id, amount_iqd, reward_kind)
        values (v_inc.id, v_tier.id, p_driver_id, v_tier.reward_iqd,
                v_inc.reward_kind);
      exception when unique_violation then
        continue;
      end;

      if v_inc.reward_kind = 'real' then
        -- رصيدٌ حقيقي: يدخل المحفظة فيُسحب إلى زين كاش.
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
        -- هدية: تأكلها عمولة رحلاته أولاً (0103).
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

      -- **يُخبَر به.** حافزٌ يُصرف بلا أن يعلم صاحبه لا يحفّز أحداً.
      insert into public.notifications (user_id, title, body, kind, audience)
      values (
        p_driver_id,
        'حصلت على حافز',
        format('%s — %s دينار %s',
               v_inc.title,
               v_tier.reward_iqd::bigint,
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

revoke all on function public.evaluate_incentives(uuid) from public, anon;
grant execute on function public.evaluate_incentives(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) متى يُقيَّم؟ عند انتهاء رحلة، وعند إغلاق جلسة اتصال
-- -----------------------------------------------------------------------------
create or replace function public.incentives_after_trip()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.status = 'completed'
     and old.status is distinct from new.status
     and new.driver_id is not null then
    -- **لا نُفشل إنهاء الرحلة بسبب حافز.** المال في يد السائق والراكب
    -- ينتظر؛ وخطأٌ هنا يعني رحلةً عالقة في `in_progress`.
    begin
      perform public.evaluate_incentives(new.driver_id);
    exception when others then
      raise warning 'تعذّر تقييم الحوافز: %', sqlerrm;
    end;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trips_incentives on public.trips;
create trigger trips_incentives
  after update of status on public.trips
  for each row execute function public.incentives_after_trip();


create or replace function public.incentives_after_session()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.ended_at is not null and old.ended_at is null then
    begin
      perform public.evaluate_incentives(new.driver_id);
    exception when others then
      raise warning 'تعذّر تقييم الحوافز: %', sqlerrm;
    end;
  end if;
  return new;
end;
$fn$;

drop trigger if exists driver_sessions_incentives on public.driver_sessions;
create trigger driver_sessions_incentives
  after update of ended_at on public.driver_sessions
  for each row execute function public.incentives_after_session();


-- -----------------------------------------------------------------------------
-- ٦) ما يقرؤه تطبيق السائق
-- -----------------------------------------------------------------------------
-- **يُقيّم قبل أن يقرأ.** من فتح الشاشة وقد بلغ هدفه قبل ثانية يجب أن
-- يرى المكافأة مصروفة، لا أن ينتظر رحلةً تالية تُشغّل المُشغّل.
create or replace function public.my_incentives()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_kind  public.vehicle_kind;
  v_inc   public.incentives;
  v_trips integer;
  v_hours numeric;
  v_out   jsonb := '[]'::jsonb;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  select vehicle_kind into v_kind from public.drivers where id = v_uid;
  if v_kind is null then return jsonb_build_object('items', '[]'::jsonb); end if;

  perform public.evaluate_incentives(v_uid);

  for v_inc in
    select * from public.incentives
    where is_active
      and now() between starts_at and ends_at
      and (vehicle_kinds is null or v_kind = any(vehicle_kinds))
    order by ends_at
  loop
    select c.trips, c.hours into v_trips, v_hours
    from public.incentive_counters(v_uid, v_inc) c;

    v_out := v_out || jsonb_build_object(
      'id',          v_inc.id,
      'title',       v_inc.title,
      'description', v_inc.description,
      'starts_at',   v_inc.starts_at,
      'ends_at',     v_inc.ends_at,
      'reward_kind', v_inc.reward_kind,
      'trips',       v_trips,
      'hours',       v_hours,
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
    'earned_total', (
      select coalesce(sum(amount_iqd), 0)
      from public.incentive_awards where driver_id = v_uid)
  );
end;
$fn$;

revoke all on function public.my_incentives() from public, anon;
grant execute on function public.my_incentives() to authenticated;


-- -----------------------------------------------------------------------------
-- ٧) ما تقرؤه لوحة المدير
-- -----------------------------------------------------------------------------
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

  return coalesce((
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
      -- ما صُرف فعلاً: الرقم الذي يهمّ المدير قبل أن يمدّد حافزاً.
      'awards_count', (select count(*) from public.incentive_awards a
                       where a.incentive_id = i.id),
      'awards_total', (select coalesce(sum(a.amount_iqd), 0)
                       from public.incentive_awards a
                       where a.incentive_id = i.id)
    ) order by i.starts_at desc)
    from public.incentives i), '[]'::jsonb);
end;
$fn$;

revoke all on function public.admin_incentives() from public, anon;
grant execute on function public.admin_incentives() to authenticated;


-- يُنشئ حافزاً بمستوياته دفعةً واحدة — حافزٌ بلا مستويات لا يُصرف شيئاً.
create or replace function public.admin_save_incentive(p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_id   uuid := nullif(p_data ->> 'id', '')::uuid;
  v_tier jsonb;
  v_i    smallint := 1;
begin
  if not public.has_perm('incentives.manage') then
    raise exception 'لا تملك صلاحية إدارة الحوافز'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_data ->> 'title'), '') = '' then
    raise exception 'اكتب عنوان الحافز';
  end if;
  if jsonb_array_length(coalesce(p_data -> 'tiers', '[]'::jsonb)) = 0 then
    raise exception 'أضف مستوى واحداً على الأقل';
  end if;

  if v_id is null then
    insert into public.incentives
      (title, description, starts_at, ends_at, vehicle_kinds, trip_kinds,
       reward_kind, is_active, created_by)
    values (
      btrim(p_data ->> 'title'),
      nullif(btrim(coalesce(p_data ->> 'description', '')), ''),
      (p_data ->> 'starts_at')::timestamptz,
      (p_data ->> 'ends_at')::timestamptz,
      case when p_data -> 'vehicle_kinds' is null
                or jsonb_array_length(p_data -> 'vehicle_kinds') = 0
           then null
           else (select array_agg(value::text::public.vehicle_kind)
                 from jsonb_array_elements_text(p_data -> 'vehicle_kinds') value)
      end,
      case when p_data -> 'trip_kinds' is null
                or jsonb_array_length(p_data -> 'trip_kinds') = 0
           then null
           else (select array_agg(value::text::public.trip_kind)
                 from jsonb_array_elements_text(p_data -> 'trip_kinds') value)
      end,
      coalesce(p_data ->> 'reward_kind', 'bonus'),
      coalesce((p_data ->> 'is_active')::boolean, true),
      auth.uid()
    )
    returning id into v_id;
  else
    update public.incentives
    set title       = btrim(p_data ->> 'title'),
        description = nullif(btrim(coalesce(p_data ->> 'description', '')), ''),
        starts_at   = (p_data ->> 'starts_at')::timestamptz,
        ends_at     = (p_data ->> 'ends_at')::timestamptz,
        reward_kind = coalesce(p_data ->> 'reward_kind', reward_kind),
        is_active   = coalesce((p_data ->> 'is_active')::boolean, is_active)
    where id = v_id;
  end if;

  -- **المستويات تُستبدل لا تُدمج.** والمصروف منها محميّ: الجوائز تشير
  -- إلى المستوى بـ`on delete cascade`، فحذفُ مستوىً صُرف يمحو أثر صرفه.
  if exists (select 1 from public.incentive_awards where incentive_id = v_id) then
    raise exception 'صُرفت جوائز من هذا الحافز — لا تُعدَّل مستوياته. أوقفه وأنشئ غيره.';
  end if;

  delete from public.incentive_tiers where incentive_id = v_id;

  for v_tier in select * from jsonb_array_elements(p_data -> 'tiers')
  loop
    insert into public.incentive_tiers
      (incentive_id, trips_required, hours_required, reward_iqd, sort_order)
    values (
      v_id,
      coalesce((v_tier ->> 'trips_required')::integer, 0),
      coalesce((v_tier ->> 'hours_required')::numeric, 0),
      (v_tier ->> 'reward_iqd')::numeric,
      v_i
    );
    v_i := v_i + 1;
  end loop;

  perform public.log_action('incentive.save', 'incentive', v_id::text,
    format('حفظ الحافز «%s»', p_data ->> 'title'));

  return v_id;
end;
$fn$;

revoke all on function public.admin_save_incentive(jsonb) from public, anon;
grant execute on function public.admin_save_incentive(jsonb) to authenticated;


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

  perform public.log_action('incentive.active', 'incentive', p_id::text,
    case when p_active then 'فُعِّل حافز' else 'أُوقف حافز' end);
end;
$fn$;

revoke all on function public.admin_set_incentive_active(uuid, boolean)
  from public, anon;
grant execute on function public.admin_set_incentive_active(uuid, boolean)
  to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_class
   where relname in ('incentives', 'incentive_tiers', 'incentive_awards'))  as "الجداول (٣)",
  (select count(*) from pg_trigger
   where tgname in ('trips_incentives', 'driver_sessions_incentives'))      as "مُشغّلا التقييم (٢)",
  (select count(*) from public.permission_catalog
   where code like 'incentives.%')                                         as "صلاحيات الحوافز (٢)";
