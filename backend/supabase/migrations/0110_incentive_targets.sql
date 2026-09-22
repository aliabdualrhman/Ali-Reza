-- =============================================================================
-- 0110 — الحافز يُوجَّه: لوحة ترتيب السائقين، وإرسالٌ لمن تختار
-- =============================================================================
-- طلب علي: «في صفحة الحوافز أريد لوحة بالسائقين كاملة — الأكثر عملاً
-- للطلبات — وأرسل الحافز إلى أعلى ١٠ أو أعلى ١٠٠ أو أدنى ١٠٠ أو أختار
-- يدوياً».
--
-- فجدولُ توجيه: حافزٌ بلا صفوفٍ فيه **لكل السائقين** كما كان، وحافزٌ له
-- صفوف **لأصحابها وحدهم** — لا يرونه غيرهم ولا يفعّلونه.
--
-- **ولماذا «أدنى ١٠٠» ليست عبثاً؟** أعلى السائقين يعملون أصلاً؛ والحافز
-- الذي يُغيّر سلوكاً هو ما يذهب إلى من توقّف أو قلّ عمله. فالترتيب يُقرأ
-- من طرفيه.
--
-- **والتوجيه يُشعِر المستهدَفين وحدهم.** بثٌّ عامٌّ لحافزٍ لا يراه أكثر من
-- يقرؤه إهانةٌ لا تشجيع.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الجدول
-- -----------------------------------------------------------------------------
create table if not exists public.incentive_targets (
  incentive_id uuid not null references public.incentives(id) on delete cascade,
  driver_id    uuid not null references public.drivers(id) on delete cascade,
  added_at     timestamptz not null default now(),
  primary key (incentive_id, driver_id)
);

alter table public.incentive_targets enable row level security;

drop policy if exists incentive_targets_read on public.incentive_targets;
create policy incentive_targets_read on public.incentive_targets
  for select to authenticated
  using (driver_id = auth.uid()
         or public.has_perm('incentives.view')
         or public.has_perm('incentives.manage'));


-- **شرطُ الأهلية في دالةٍ واحدة.** يُقرأ في ثلاثة مواضع — العرض والتفعيل
-- والصرف — ونسخُه ثلاثاً يعني أن نسيان واحدةٍ يُسرّب حافزاً موجَّهاً.
create or replace function public.incentive_allows(p_incentive uuid, p_driver uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select not exists (select 1 from public.incentive_targets t
                     where t.incentive_id = p_incentive)
      or exists (select 1 from public.incentive_targets t
                 where t.incentive_id = p_incentive and t.driver_id = p_driver);
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) لوحة ترتيب السائقين
-- -----------------------------------------------------------------------------
-- **الترتيب بمدّةٍ يحدّدها المدير.** «الأكثر عملاً» في أسبوعٍ غيرها في
-- شهر، ومن غاب شهراً يتصدّر قائمة السنة.
create or replace function public.admin_driver_leaderboard(
  p_from timestamptz default now() - interval '30 days',
  p_to   timestamptz default now()
)
returns table (
  driver_id    uuid,
  full_name    text,
  phone        text,
  vehicle_kind public.vehicle_kind,
  trips        integer,
  hours        numeric,
  wallet_iqd   numeric,
  is_blocked   boolean,
  approved     boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select
    d.id,
    p.full_name,
    p.phone,
    d.vehicle_kind,
    coalesce(t.n, 0)::integer,
    round(public.driver_online_seconds(d.id, p_from, p_to) / 3600.0, 1),
    d.wallet_balance_iqd,
    p.is_blocked,
    d.verification_status = 'approved'
  from public.drivers d
  join public.profiles p on p.id = d.id
  left join lateral (
    select count(*) as n
    from public.trips tr
    where tr.driver_id = d.id
      and tr.status = 'completed'
      and tr.completed_at between p_from and p_to
  ) t on true
  where public.has_perm('incentives.view')
     or public.has_perm('incentives.manage')
     or public.has_perm('drivers.view')
  order by coalesce(t.n, 0) desc, p.full_name;
$fn$;

revoke all on function public.admin_driver_leaderboard(timestamptz, timestamptz)
  from public, anon;
grant execute on function public.admin_driver_leaderboard(timestamptz, timestamptz)
  to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) توجيه الحافز
-- -----------------------------------------------------------------------------
create or replace function public.admin_set_incentive_targets(
  p_id      uuid,
  p_drivers uuid[]
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_inc  public.incentives;
  v_new  integer := 0;
  v_did  uuid;
  v_top  numeric;
begin
  if not public.has_perm('incentives.manage') then
    raise exception 'لا تملك صلاحية إدارة الحوافز'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_inc from public.incentives where id = p_id;
  if v_inc.id is null then raise exception 'الحافز غير موجود'; end if;

  -- قائمةٌ فارغة تعني «للجميع»: نمسح التوجيه ولا نُشعر أحداً.
  if p_drivers is null or array_length(p_drivers, 1) is null then
    delete from public.incentive_targets where incentive_id = p_id;
    perform public.log_action('incentive.targets', 'incentive', p_id::text,
      format('صار الحافز «%s» لكل السائقين', v_inc.title));
    return 0;
  end if;

  select max(reward_iqd) into v_top
  from public.incentive_tiers where incentive_id = p_id;

  -- **من أُضيف من قبل لا يُشعَر ثانيةً.** تعديل القائمة إضافةُ قومٍ لا
  -- إعادةُ نداءٍ على من نودي.
  foreach v_did in array p_drivers loop
    if not exists (select 1 from public.incentive_targets
                   where incentive_id = p_id and driver_id = v_did) then
      insert into public.incentive_targets (incentive_id, driver_id)
      values (p_id, v_did);

      insert into public.notifications (user_id, title, body, kind, recipients)
      values (
        v_did,
        'حافز خاصٌّ لك: ' || v_inc.title,
        format('افتح «الحوافز» وفعّله — حتى %s دينار. ينتهي %s',
               coalesce(v_top, 0)::bigint,
               to_char(v_inc.ends_at at time zone 'Asia/Baghdad',
                       'MM-DD HH24:MI')),
        'incentive', 1
      );
      v_new := v_new + 1;
    end if;
  end loop;

  -- ومن خرج من القائمة يخرج — إلا من نال منه مكافأةً بالفعل.
  delete from public.incentive_targets t
  where t.incentive_id = p_id
    and not (t.driver_id = any(p_drivers))
    and not exists (select 1 from public.incentive_awards a
                    where a.incentive_id = p_id and a.driver_id = t.driver_id);

  perform public.log_action('incentive.targets', 'incentive', p_id::text,
    format('وُجّه الحافز «%s» إلى %s سائقاً (%s جديداً)',
           v_inc.title, array_length(p_drivers, 1), v_new));

  return v_new;
end;
$fn$;

revoke all on function public.admin_set_incentive_targets(uuid, uuid[])
  from public, anon;
grant execute on function public.admin_set_incentive_targets(uuid, uuid[])
  to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) الأهلية تُفحص في العرض والتفعيل والصرف
-- -----------------------------------------------------------------------------
-- **بالاستبدال النصّي لا بإعادة الكتابة.** الدوال الثلاث طويلة، ونسخُها
-- بيدٍ أسقط منطقاً من قبل (0080). والشرط يُلحق بشرط المركبة في كلٍّ منها.
do $do$
declare
  r     record;
  v_def text;
  v_n   integer;
begin
  for r in
    select * from (values
      ('evaluate_incentives',
       '      and (i.vehicle_kinds is null or v_kind = any(i.vehicle_kinds))',
       '      and (i.vehicle_kinds is null or v_kind = any(i.vehicle_kinds))' ||
       chr(10) || '      and public.incentive_allows(i.id, p_driver_id)'),
      ('my_incentives',
       '      and (vehicle_kinds is null or v_kind = any(vehicle_kinds))',
       '      and (vehicle_kinds is null or v_kind = any(vehicle_kinds))' ||
       chr(10) || '      and public.incentive_allows(id, v_uid)'),
      ('activate_incentive',
       '  v_max := greatest(1, public.referral_setting(''incentives_max_active'', 1)::integer);',
       '  if not public.incentive_allows(p_id, v_uid) then' || chr(10) ||
       '    raise exception ''هذا الحافز موجَّهٌ إلى سائقين آخرين'';' || chr(10) ||
       '  end if;' || chr(10) || chr(10) ||
       '  v_max := greatest(1, public.referral_setting(''incentives_max_active'', 1)::integer);')
    ) as t(fn, old_txt, new_txt)
  loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = r.fn;

    if v_def is null then
      raise exception 'الدالة % غير موجودة — طبّق 0107 و0108 أولاً', r.fn;
    end if;
    if position('incentive_allows' in v_def) > 0 then
      continue;  -- طُبّق من قبل
    end if;

    v_n := (length(v_def) - length(replace(v_def, r.old_txt, '')))
           / length(r.old_txt);
    if v_n <> 1 then
      raise exception 'الدالة %: المرساة وردت % مرة لا مرةً واحدة', r.fn, v_n;
    end if;

    execute replace(v_def, r.old_txt, r.new_txt);
  end loop;
end;
$do$;


-- ولوحة المدير ترى عدد الموجَّه إليهم.
do $do$
declare
  v_def text;
  v_old constant text := '''optins'', (select count(*) from public.incentive_optins o';
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.proname = 'admin_incentives';

  if v_def is null then
    raise exception 'admin_incentives غير موجودة';
  end if;
  if position('incentive_targets' in v_def) > 0 then
    return;
  end if;
  if position(v_old in v_def) = 0 then
    raise exception 'admin_incentives تغيّرت — أضف العدّ يدوياً';
  end if;

  execute replace(
    v_def, v_old,
    '''targets'', (select count(*) from public.incentive_targets g' || chr(10) ||
    '                    where g.incentive_id = i.id),' || chr(10) ||
    '        ' || v_old);
end;
$do$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_class where relname = 'incentive_targets')   as "جدول التوجيه (١)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('admin_driver_leaderboard', 'admin_set_incentive_targets',
                     'incentive_allows'))                               as "الدوال (٣)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('evaluate_incentives', 'my_incentives', 'activate_incentive')
     and prosrc like '%incentive_allows%')                              as "الأهلية تُفحص (٣)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname = 'admin_incentives' and prosrc like '%incentive_targets%') as "اللوحة تعدّهم (١)";
