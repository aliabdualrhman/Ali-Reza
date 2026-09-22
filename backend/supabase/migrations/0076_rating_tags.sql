-- =============================================================================
-- 0076 — التقييم يقول سببه، والسبب يقود إلى فعل
-- =============================================================================
-- **نجومٌ بلا سبب لا تُصلح شيئاً.** سائقٌ هبط إلى ٢.٨ — لماذا؟ لا المدير
-- يعرف فيُصلح، ولا السائق يعرف فيتغيّر. والمتوسّط وحده يقول إن شيئاً
-- ساء بعد أن فات أوانه.
--
-- ------------------------------------------------------------------
-- والقاعدة في اختيار الخيارات: كلٌّ منها يقود إلى فعل
-- ------------------------------------------------------------------
-- «خدمة ممتازة» لا يُفعل بها شيء. و«لم يُعِد الباقي» تفتح تحقيقاً،
-- و«قيادة متهوّرة» تُراجَع، و«أنهى الرحلة قبل وصولنا» تُقارَن بقياسٍ
-- عندنا. فما لا يُفعل به شيء حُذف.
--
-- ------------------------------------------------------------------
-- وفي جدولٍ لا في الكود
-- ------------------------------------------------------------------
-- **لأن الكلمات تتغيّر والبناء يستغرق يوماً.** خيارٌ يُضاف أو يُحذف من
-- اللوحة، بلا بناءٍ ولا نشرٍ ولا مراجعة متجر — كما فعلنا مع كل إعداد.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الجدول
-- -----------------------------------------------------------------------------
create table if not exists public.rating_tags (
  code         text primary key,
  label        text not null,

  -- من يُقيَّم بهذا الخيار — لا من يكتبه.
  audience     text not null check (audience in ('driver', 'rider')),
  sentiment    text not null check (sentiment in ('positive', 'negative')),

  -- **الشكوى التي تحمل رقماً.** «لم يُعِد الباقي» بلا مبلغ لا تُحقَّق.
  needs_amount boolean not null default false,

  -- **يصل المدير لحظتها.** شكوى مالٍ أو سلامةٍ تبرد بسرعة: بعد أسبوع
  -- لا الراكب يذكر ولا السائق يعترف.
  alerts_admin boolean not null default false,

  sort         integer not null default 100,
  is_active    boolean not null default true
);

alter table public.rating_tags enable row level security;

drop policy if exists rating_tags_read on public.rating_tags;
create policy rating_tags_read on public.rating_tags
  for select to authenticated using (is_active or public.is_admin());

drop policy if exists rating_tags_admin on public.rating_tags;
create policy rating_tags_admin on public.rating_tags
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

comment on table public.rating_tags is
  'خيارات التقييم. تُحرَّر من اللوحة بلا بناء.';


-- -----------------------------------------------------------------------------
-- ٢) الخيارات
-- -----------------------------------------------------------------------------
insert into public.rating_tags
  (code, label, audience, sentiment, needs_amount, alerts_admin, sort) values

  -- ---- الراكب ← السائق: إيجابية ----
  ('safe_driving',  'قيادة آمنة',      'driver', 'positive', false, false, 10),
  ('fast_arrival',  'وصل بسرعة',       'driver', 'positive', false, false, 20),
  ('polite_d',      'تعامل محترم',     'driver', 'positive', false, false, 30),
  ('clean_vehicle', 'دراجة نظيفة',     'driver', 'positive', false, false, 40),
  ('knows_roads',   'يعرف الطريق',     'driver', 'positive', false, false, 50),
  ('helmet',        'وفّر خوذة',        'driver', 'positive', false, false, 60),

  -- ---- الراكب ← السائق: سلبية ----
  ('no_change',     'لم يُعِد الباقي',  'driver', 'negative', true,  true,  10),
  ('overcharged',   'طلب أكثر من الأجرة','driver','negative', true,  true,  20),
  ('reckless',      'قيادة متهوّرة',    'driver', 'negative', false, true,  30),
  ('ended_early',   'أنهى الرحلة قبل وصولنا',
                                        'driver', 'negative', false, true,  40),
  ('rude_d',        'تعامل غير لائق',  'driver', 'negative', false, true,  50),
  ('late',          'تأخّر كثيراً',     'driver', 'negative', false, false, 60),
  ('bad_vehicle',   'دراجة غير صالحة', 'driver', 'negative', false, false, 70),

  -- ---- السائق ← الراكب: إيجابية ----
  ('ready_on_time', 'كان جاهزاً',      'rider',  'positive', false, false, 10),
  ('clear_address', 'عنوان واضح',      'rider',  'positive', false, false, 20),
  ('polite_r',      'تعامل محترم',     'rider',  'positive', false, false, 30),
  ('paid_easily',   'دفع بلا مشاكل',   'rider',  'positive', false, false, 40),

  -- ---- السائق ← الراكب: سلبية ----
  ('underpaid',     'لم يدفع الأجرة كاملة',
                                        'rider',  'negative', true,  true,  10),
  ('kept_waiting',  'أخّرني كثيراً',    'rider',  'negative', false, false, 20),
  ('wrong_address', 'عنوان خاطئ',      'rider',  'negative', false, false, 30),
  ('oversized_load','طلب حمولةً كبيرة','rider',  'negative', false, false, 40),
  ('rude_r',        'تعامل غير لائق',  'rider',  'negative', false, true,  50)

on conflict (code) do nothing;


-- -----------------------------------------------------------------------------
-- ٣) ما يعرضه التطبيق
-- -----------------------------------------------------------------------------
-- **العتبة من الإعدادات لا من الكود.** «٣ فأقل سلبيّ» حكمٌ قد يتغيّر.
insert into public.public_settings (key, value, label) values
  ('rating_negative_max', '3', 'أقصى نجومٍ تُعدّ تقييماً سلبياً')
on conflict (key) do nothing;


create or replace function public.rating_options(p_stars integer)
returns table (
  code         text,
  label        text,
  needs_amount boolean
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_role public.user_role;
  v_max  integer;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  select role into v_role from public.profiles where id = v_uid;
  v_max := public.referral_setting('rating_negative_max', 3)::integer;

  -- **من يُقيَّم هو الطرف الآخر.** الراكب يقيّم سائقاً، والسائق راكباً.
  return query
  select t.code, t.label, t.needs_amount
  from public.rating_tags t
  where t.is_active
    and t.audience = case when v_role = 'rider' then 'driver' else 'rider' end
    and t.sentiment = case when coalesce(p_stars, 5) <= v_max
                           then 'negative' else 'positive' end
  order by t.sort, t.label;
end;
$fn$;

revoke all on function public.rating_options(integer) from public, anon;
grant execute on function public.rating_options(integer) to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) الأكثر اختياراً
-- -----------------------------------------------------------------------------
-- **ثلاثةٌ لا قائمة.** عددٌ صغير يُقرأ بنظرة؛ وقائمةٌ بعشرين سطراً
-- تُتجاهَل كلها.
--
-- **وآخر خمسين لا كل التاريخ.** سائقٌ أصلح نفسه منذ شهرين يجب أن تظهر
-- حالته اليوم، لا متوسّط سنةٍ يخفي التحسّن ويخفي التدهور معاً.
create or replace function public.rating_tag_summary(p_user_id uuid)
returns table (
  code      text,
  label     text,
  sentiment text,
  uses      integer
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() and auth.uid() <> p_user_id then
    raise exception 'غير مصرّح';
  end if;

  return query
  with recent as (
    select r.tags
    from public.ratings r
    where r.ratee_id = p_user_id
    order by r.created_at desc
    limit 50
  ),
  flat as (
    select unnest(tags) as code from recent
  )
  select f.code, t.label, t.sentiment, count(*)::integer
  from flat f
  join public.rating_tags t on t.code = f.code
  group by f.code, t.label, t.sentiment
  order by count(*) desc, t.label
  limit 6;
end;
$fn$;

revoke all on function public.rating_tag_summary(uuid) from public, anon;
grant execute on function public.rating_tag_summary(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) تقييما الرحلة — للمدير
-- -----------------------------------------------------------------------------
-- **متقابلان في مكانٍ واحد.** خلافُ رحلةٍ لا يُفهم من طرفٍ واحد: من
-- يقرأ شكوى الراكب وحدها يحكم قبل أن يسمع السائق.
create or replace function public.admin_trip_ratings(p_trip_id uuid)
returns table (
  rater_name text,
  rater_role text,
  ratee_name text,
  stars      smallint,
  labels     text[],
  amount     numeric,
  comment    text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;

  return query
  select
    rp.full_name,
    rp.role::text,
    ep.full_name,
    r.stars,
    coalesce(array(
      select t.label from public.rating_tags t
      where t.code = any (r.tags) order by t.sort
    ), '{}'),
    r.reported_change_iqd,
    r.comment,
    r.created_at
  from public.ratings r
  join public.profiles rp on rp.id = r.rater_id
  join public.profiles ep on ep.id = r.ratee_id
  where r.trip_id = p_trip_id
  order by r.created_at;
end;
$fn$;

revoke all on function public.admin_trip_ratings(uuid) from public, anon;
grant execute on function public.admin_trip_ratings(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- ٦) تقييمات شخصٍ واحد — للمدير
-- -----------------------------------------------------------------------------
create or replace function public.admin_user_ratings(
  p_user_id uuid,
  p_limit   integer default 30
)
returns table (
  trip_number integer,
  rater_name  text,
  stars       smallint,
  labels      text[],
  amount      numeric,
  comment     text,
  created_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;

  return query
  select
    tr.trip_number,
    rp.full_name,
    r.stars,
    coalesce(array(
      select t.label from public.rating_tags t
      where t.code = any (r.tags) order by t.sort
    ), '{}'),
    r.reported_change_iqd,
    r.comment,
    r.created_at
  from public.ratings r
  join public.profiles rp on rp.id = r.rater_id
  join public.trips    tr on tr.id = r.trip_id
  where r.ratee_id = p_user_id
  order by r.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 200));
end;
$fn$;

revoke all on function public.admin_user_ratings(uuid, integer)
  from public, anon;
grant execute on function public.admin_user_ratings(uuid, integer)
  to authenticated;


-- -----------------------------------------------------------------------------
-- ٧) التنبيه يقرأ الجدول لا قائمةً مكتوبة
-- -----------------------------------------------------------------------------
-- **وإلا لأضفتَ خياراً من اللوحة ولم يُنبَّه عليه أحد.** الجدول يقول
-- أيّها يستحق تنبيهاً، والمُشغّل يطيع.
create or replace function public.notify_change_complaint()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_trip   public.trips;
  v_rater  text;
  v_ratee  text;
  v_labels text;
  v_amount text;
begin
  select string_agg(t.label, ' · ' order by t.sort) into v_labels
  from public.rating_tags t
  where t.code = any (new.tags) and t.alerts_admin;

  if v_labels is null then return new; end if;

  select * into v_trip from public.trips where id = new.trip_id;
  select full_name into v_rater from public.profiles where id = new.rater_id;
  select full_name into v_ratee from public.profiles where id = new.ratee_id;

  -- **المبلغان متجاوران.** ما قاله الشاكي وما سجّله الطرف الآخر في
  -- سطرٍ واحد — فيُحسم الخلاف بنظرة لا بتحقيق.
  v_amount := case
    when new.reported_change_iqd is null then ''
    else format(' — يقول %s دينار، والمسجَّل %s دينار',
                new.reported_change_iqd::bigint,
                coalesce(v_trip.change_returned_iqd, 0)::bigint)
  end;

  insert into public.notifications (user_id, title, body, kind)
  select p.id,
         format('شكوى على الرحلة %s', v_trip.trip_number),
         format('%s ★ من %s على %s: %s%s',
                new.stars, coalesce(v_rater, '—'),
                coalesce(v_ratee, '—'), v_labels, v_amount),
         'direct'
  from public.profiles p
  where p.role = 'admin' and p.deleted_at is null;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select audience as "يُقيَّم", sentiment as "النوع", count(*) as "الخيارات"
from public.rating_tags
where is_active
group by audience, sentiment
order by audience, sentiment;
