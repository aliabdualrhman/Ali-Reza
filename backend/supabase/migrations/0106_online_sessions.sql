-- =============================================================================
-- 0106 — ساعات الاتصال تُقاس، تمهيداً للحوافز
-- =============================================================================
-- الحوافز تشترط «عدد رحلات + ساعات اتصال». والرحلات محسوبةٌ في `trips`
-- منذ اليوم الأول، **أما ساعات الاتصال فلا أثر لها في القاعدة إطلاقاً**:
-- `drivers.status` يقول «متصل الآن» ولا يقول كم بقي متصلاً أمس.
--
-- فجلسةٌ تُفتح عند «متصل» وتُغلق عند «غير متصل».
--
-- **وأصعب ما في الأمر الجلسة التي لا تُغلق.** السائق يقتل التطبيق، أو
-- ينفد شحنه، أو ينقطع نته — فيبقى الصفّ مفتوحاً إلى الأبد، ولو عددناه
-- لاستحقّ حافز «عشر ساعات» من نام وهاتفه مطفأ.
--
-- ولهذا لا نثق بـ`ended_at` وحده: **نبضُ الموقع هو الشاهد**. التطبيق
-- يحدّث `location_updated_at` وهو يعمل، فالجلسة المفتوحة تُحسب حتى
-- آخر نبضةٍ زائد دقيقتين لا حتى اللحظة. ومن أغلق هاتفه ساعةً لا تُحسب
-- له إلا الدقيقتان.

set search_path = public, extensions;


create table if not exists public.driver_sessions (
  id         uuid primary key default gen_random_uuid(),
  driver_id  uuid not null references public.drivers(id) on delete cascade,
  started_at timestamptz not null default now(),
  ended_at   timestamptz
);

comment on table public.driver_sessions is
  'فترات اتصال السائق. المفتوحة تُحسب حتى آخر نبضة موقع — انظر driver_online_seconds.';

-- جلسةٌ مفتوحة واحدة لكل سائق: الفهرس الجزئي يمنع الثانية في القاعدة،
-- لا في الدالة وحدها — فضغطتان متزامنتان على «متصل» لا تفتحان جلستين.
create unique index if not exists driver_sessions_one_open
  on public.driver_sessions (driver_id) where ended_at is null;

create index if not exists driver_sessions_driver_time
  on public.driver_sessions (driver_id, started_at desc);

alter table public.driver_sessions enable row level security;

drop policy if exists driver_sessions_read on public.driver_sessions;
create policy driver_sessions_read on public.driver_sessions
  for select to authenticated
  using (driver_id = auth.uid() or public.has_perm('drivers.view'));
-- لا سياسة كتابة: الفتح والإغلاق من دوال `security definer` وحدها.


-- -----------------------------------------------------------------------------
-- ثواني الاتصال في مدّة
-- -----------------------------------------------------------------------------
create or replace function public.driver_online_seconds(
  p_driver_id uuid,
  p_from      timestamptz,
  p_to        timestamptz
)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  -- تقاطع كل جلسة مع المدّة المطلوبة. والجلسة المفتوحة تنتهي عند آخر
  -- نبضةٍ زائد دقيقتين — انظر رأس الملف.
  select coalesce(sum(
    greatest(0, extract(epoch from (
      least(
        coalesce(s.ended_at,
                 least(now(), coalesce(d.location_updated_at, s.started_at)
                              + interval '2 minutes')),
        p_to
      )
      - greatest(s.started_at, p_from)
    )))
  ), 0)::numeric
  from public.driver_sessions s
  join public.drivers d on d.id = s.driver_id
  where s.driver_id = p_driver_id
    and s.started_at < p_to
    and coalesce(s.ended_at, now()) > p_from;
$fn$;

revoke all on function public.driver_online_seconds(uuid, timestamptz, timestamptz)
  from public, anon;
grant execute on function public.driver_online_seconds(uuid, timestamptz, timestamptz)
  to authenticated;


-- -----------------------------------------------------------------------------
-- فتح الجلسة وإغلاقها مع مفتاح «متصل»
-- -----------------------------------------------------------------------------
-- منسوخةٌ من التعريف الحيّ، والزيادة كتلةُ الجلسة في آخرها.
create or replace function public.set_driver_online(p_online boolean)
returns public.driver_status
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  d public.drivers;
  v_min_balance numeric;
begin
  select * into d from public.drivers where id = auth.uid() for update;
  if not found then
    raise exception 'المستخدم الحالي ليس سائقاً';
  end if;

  if d.status = 'on_trip' then
    raise exception 'لا يمكن تغيير الحالة أثناء رحلة جارية';
  end if;

  if p_online then
    if d.verification_status <> 'approved' then
      raise exception 'حسابك قيد المراجعة — لم تُعتمد وثائقك بعد'
        using errcode = 'insufficient_privilege';
    end if;

    -- نأخذ أدنى حد مسموح من أي منطقة مفعّلة (نموذج مبسط لمرحلة MVP)
    select min(min_wallet_balance_iqd) into v_min_balance
    from public.pricing_zones where is_active;

    if d.wallet_balance_iqd < coalesce(v_min_balance, -25000) then
      raise exception 'رصيدك % دينار. سدّد العمولات المستحقة لتتمكن من الاتصال',
        d.wallet_balance_iqd
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  update public.drivers
  set status = case when p_online then 'online' else 'offline' end::public.driver_status
  where id = auth.uid()
  returning status into d.status;

  -- ---- الجلسة ----
  if p_online then
    -- `on conflict` على الفهرس الجزئي: من ضغط «متصل» وهو متصل لا يفتح
    -- جلسةً ثانية ولا يُعيد تصفير الأولى.
    insert into public.driver_sessions (driver_id)
    values (auth.uid())
    on conflict (driver_id) where ended_at is null do nothing;
  else
    update public.driver_sessions
    set ended_at = now()
    where driver_id = auth.uid() and ended_at is null;
  end if;

  return d.status;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_class where relname = 'driver_sessions')  as "جدول الجلسات (١)",
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'set_driver_online'
     and prosrc like '%driver_sessions%')                            as "المفتاح يفتح جلسة (١)",
  public.driver_online_seconds(
    (select id from public.drivers limit 1), now() - interval '1 day', now())
                                                                     as "ثواني سائقٍ أمس (٠ الآن)";
