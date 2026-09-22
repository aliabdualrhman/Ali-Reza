-- =============================================================================
-- 0060 — لوحة الإشعارات: قوالب وإرسالٌ وجرسٌ داخل التطبيق
-- =============================================================================
-- **ما ينقص المدير اليوم:** لا سبيل لمخاطبة سائقيه ولا ركّابه. لا إعلان
-- عن عرض، ولا تنبيه بانقطاع خدمة، ولا رسالة لسائقٍ بعينه. والوسيلة
-- الوحيدة اتصالٌ هاتفيٌّ واحداً واحداً.
--
-- ------------------------------------------------------------------
-- ثلاثة قرارات تشرح بنية هذا الملف
-- ------------------------------------------------------------------
--
-- **١) الإشعار يُخزَّن قبل أن يُرسَل.** لا نكتفي بدفعه إلى فايربيز:
-- نكتبه في `notifications` أولاً، ويقرؤه التطبيق في جرسٍ داخلي.
--
-- والسبب رأيناه بأعيننا: أجهزةٌ في سوقنا لا تولّد رمز FCM إطلاقاً
-- (`SERVICE_NOT_AVAILABLE`). فمن يعتمد على الدفع وحده يفقد جزءاً من
-- جمهوره في كل حملة **ولا يعلم أنه فقده**. والجرس يصل الجميع.
--
-- **٢) القالب منفصلٌ عن الإرسال.** «تحديث الأسعار» تُكتب مرة وتُرسل
-- عشرات المرات. وكتابتها في كل مرة تعني خطأً إملائياً يصل خمسمئة هاتف
-- ولا يُسترد.
--
-- **٣) المجدول صفٌّ لا مهمّة.** الجدولة تُخزَّن، ويمرّ عليها `pg_cron`
-- كل دقيقة. ولو خبّأناها في مؤقّت لضاعت مع أول إعادة تشغيل — وقد رأينا
-- `dispatch_tick` تتوقف شهراً بلا أن يلاحظ أحد.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) القوالب المحفوظة
-- -----------------------------------------------------------------------------
create table if not exists public.notification_templates (
  id          uuid primary key default gen_random_uuid(),

  title       text not null check (length(btrim(title)) between 2 and 80),
  body        text not null check (length(btrim(body))  between 2 and 300),

  -- 'driver' · 'rider' · 'both'
  audience    text not null default 'both'
              check (audience in ('driver', 'rider', 'both')),

  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  used_count  integer not null default 0
);

comment on table public.notification_templates is
  'رسائل محفوظة تُرسل مراراً. تُكتب مرة فلا يتسلّل خطأٌ إملائي إلى مئات الهواتف.';

alter table public.notification_templates enable row level security;

drop policy if exists templates_admin on public.notification_templates;
create policy templates_admin on public.notification_templates
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- -----------------------------------------------------------------------------
-- ٢) الإشعارات المرسَلة — وهي الجرس
-- -----------------------------------------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),

  -- **فارغ = إشعارٌ عام** لجمهورٍ كامل. وغيرُ الفارغ = رسالةٌ لشخص.
  -- عمودٌ واحد بدل جدولين: القراءة واحدة والجرس واحد.
  user_id     uuid references public.profiles(id) on delete cascade,
  audience    text check (audience in ('driver', 'rider', 'both')),

  title       text not null,
  body        text not null,

  -- 'broadcast' · 'direct' · 'scheduled'
  kind        text not null default 'broadcast'
              check (kind in ('broadcast', 'direct', 'scheduled')),

  sent_by     uuid references public.profiles(id) on delete set null,
  sent_at     timestamptz not null default now(),

  -- كم جهازاً وصله الدفع فعلاً. **يُقاس لا يُفترض.**
  delivered   integer not null default 0,
  recipients  integer not null default 0,

  constraint notifications_target_ck
    check ((user_id is not null) <> (audience is not null))
);

create index if not exists notifications_user_idx
  on public.notifications (user_id, sent_at desc) where user_id is not null;

create index if not exists notifications_audience_idx
  on public.notifications (audience, sent_at desc) where audience is not null;

alter table public.notifications enable row level security;

-- **يقرأ ما يخصّه: رسائله الشخصية وإشعارات جمهوره.**
drop policy if exists notifications_read on public.notifications;
create policy notifications_read on public.notifications
  for select to authenticated
  using (
    public.is_admin()
    or user_id = auth.uid()
    or (audience is not null and audience in (
          'both',
          (select role::text from public.profiles where id = auth.uid())))
  );


-- **ما قرأه المستخدم.** جدولٌ منفصل لأن الإشعار العام صفٌّ واحد يقرؤه
-- ألف مستخدم؛ ووضعُ علَمِ القراءة فيه يجعل الألف يتزاحمون على صفٍّ واحد.
create table if not exists public.notification_reads (
  notification_id uuid not null
                  references public.notifications(id) on delete cascade,
  user_id         uuid not null
                  references public.profiles(id) on delete cascade,
  read_at         timestamptz not null default now(),
  primary key (notification_id, user_id)
);

alter table public.notification_reads enable row level security;

drop policy if exists notification_reads_own on public.notification_reads;
create policy notification_reads_own on public.notification_reads
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());


-- -----------------------------------------------------------------------------
-- ٣) الجدولة
-- -----------------------------------------------------------------------------
create table if not exists public.notification_schedules (
  id           uuid primary key default gen_random_uuid(),

  template_id  uuid not null
               references public.notification_templates(id) on delete cascade,
  audience     text not null check (audience in ('driver', 'rider', 'both')),

  -- 'daily' · 'weekly' · 'once'
  frequency    text not null default 'daily'
               check (frequency in ('daily', 'weekly', 'once')),

  -- **ساعة بغداد لا UTC.** المدير يفكّر بتوقيت مدينته، وتحويلُه في
  -- رأسه عند كل جدولة يُنتج رسائل تصل في الثالثة فجراً.
  send_at_hour smallint not null default 9 check (send_at_hour between 0 and 23),
  weekday      smallint check (weekday between 0 and 6),   -- 0 = الأحد

  is_active    boolean not null default true,
  last_sent_at timestamptz,

  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);

alter table public.notification_schedules enable row level security;

drop policy if exists schedules_admin on public.notification_schedules;
create policy schedules_admin on public.notification_schedules
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());


-- -----------------------------------------------------------------------------
-- ٤) عدّ المستقبِلين — يُعرض قبل الإرسال
-- -----------------------------------------------------------------------------
-- **رقمٌ قبل الضغط.** رسالةٌ فيها خطأ تصل خمسمئة هاتف ولا تُسترد، ومن
-- يرى «سترسل إلى ٥١٢ سائقاً» يقرأ نصّه مرة أخرى قبل أن يضغط.
create or replace function public.notification_audience_count(
  p_audience text,
  p_approved_only boolean default false
)
returns integer
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select count(*)::integer
  from public.profiles p
  left join public.drivers d on d.id = p.id
  where p.deleted_at is null
    and not p.is_blocked
    and (p_audience = 'both' or p.role::text = p_audience)
    and p.role in ('rider', 'driver')
    and (not p_approved_only
         or p.role <> 'driver'
         or d.verification_status = 'approved');
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) الإرسال
-- -----------------------------------------------------------------------------
-- **يكتب الصفّ ويترك الدفع للخادم.** إرسال FCM يحتاج رمز OAuth موقّعاً
-- بمفتاح خدمة، وبوستغرس لا يولّده. فتكتب الدالة الإشعار — وهو ما يراه
-- الجرس فوراً — ويلتقطه مُشغّلٌ يستدعي دالة الحافة للدفع.
create or replace function public.send_notification(
  p_title    text,
  p_body     text,
  p_audience text default null,        -- للبثّ
  p_user_id  uuid default null,        -- للرسالة الخاصة
  p_approved_only boolean default false
)
returns public.notifications
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row   public.notifications;
  v_count integer;
begin
  if not public.has_perm('notifications.send') then
    raise exception 'لا تملك صلاحية إرسال الإشعارات'
      using errcode = 'insufficient_privilege';
  end if;

  if (p_user_id is null) = (p_audience is null) then
    raise exception 'حدّد جمهوراً أو مستخدماً واحداً — لا الاثنين';
  end if;

  if length(btrim(coalesce(p_title, ''))) < 2 then
    raise exception 'اكتب عنوان الإشعار';
  end if;
  if length(btrim(coalesce(p_body, ''))) < 2 then
    raise exception 'اكتب نصّ الإشعار';
  end if;

  v_count := case
    when p_user_id is not null then 1
    else public.notification_audience_count(p_audience, p_approved_only)
  end;

  insert into public.notifications
    (user_id, audience, title, body, kind, sent_by, recipients)
  values (
    p_user_id, p_audience,
    btrim(p_title), btrim(p_body),
    case when p_user_id is not null then 'direct' else 'broadcast' end,
    auth.uid(), v_count
  )
  returning * into v_row;

  perform public.log_action(
    'notification.send', 'notifications', v_row.id::text,
    format('%s — %s مستقبِلاً', btrim(p_title), v_count)
  );

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) جرس المستخدم
-- -----------------------------------------------------------------------------
create or replace function public.my_notifications(p_limit integer default 50)
returns table (
  id      uuid,
  title   text,
  body    text,
  sent_at timestamptz,
  is_read boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select n.id, n.title, n.body, n.sent_at,
         (r.user_id is not null) as is_read
  from public.notifications n
  left join public.notification_reads r
    on r.notification_id = n.id and r.user_id = auth.uid()
  where n.user_id = auth.uid()
     or (n.audience is not null and n.audience in (
           'both',
           (select role::text from public.profiles where id = auth.uid())))
  order by n.sent_at desc
  limit least(coalesce(p_limit, 50), 200);
$fn$;


create or replace function public.mark_notifications_read()
returns void
language sql
security definer
set search_path = public, extensions
as $fn$
  insert into public.notification_reads (notification_id, user_id)
  select n.id, auth.uid()
  from public.notifications n
  where n.user_id = auth.uid()
     or (n.audience is not null and n.audience in (
           'both',
           (select role::text from public.profiles where id = auth.uid())))
  on conflict do nothing;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحية
-- -----------------------------------------------------------------------------
insert into public.permission_catalog (code, label, sort_order) values
  ('notifications.send', 'إرسال الإشعارات وإدارة القوالب', 150)
on conflict (code) do update
  set label = excluded.label, sort_order = excluded.sort_order;

update public.profiles
set staff_permissions = array(
      select distinct unnest(staff_permissions || array['notifications.send'])
    )
where role = 'admin'
  and lower(email) = 'ali.alkawary@gmail.com'
  and not ('notifications.send' = any(staff_permissions));


-- -----------------------------------------------------------------------------
-- ٨) الصلاحيات على الدوال
-- -----------------------------------------------------------------------------
revoke all on function
  public.send_notification(text, text, text, uuid, boolean) from public, anon;
revoke all on function
  public.notification_audience_count(text, boolean)         from public, anon;
revoke all on function public.my_notifications(integer)     from public, anon;
revoke all on function public.mark_notifications_read()     from public, anon;

grant execute on function
  public.send_notification(text, text, text, uuid, boolean) to authenticated;
grant execute on function
  public.notification_audience_count(text, boolean)         to authenticated;
grant execute on function public.my_notifications(integer)  to authenticated;
grant execute on function public.mark_notifications_read()  to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.notification_templates) as "قوالب",
  (select count(*) from public.notifications)          as "إشعارات مرسَلة",
  (select count(*) from public.permission_catalog
   where code = 'notifications.send')                  as "الصلاحية مسجَّلة";
