-- =============================================================================
-- 0042 — قسم الركّاب في اللوحة، وتعديل المدير المباشر للبيانات
-- =============================================================================
-- **نقصان في اللوحة:**
--
--   ١) السائقون لهم قسم وبحث وصفحة تفاصيل. والركّاب — وهم أكثر عدداً
--      وأصل الإيراد — لا يظهرون إلا كأسماء عابرة داخل صفوف الرحلات.
--      فلا يستطيع المدير أن يجيب سؤالاً بسيطاً: «كم راكباً عندنا؟ ومن
--      هذا الذي يشكو؟ وكم رحلة ألغى؟»
--
--   ٢) وتعديل البيانات يمرّ كله بـ`profile_change_requests` (0036):
--      المستخدم يطلب والمدير يوافق. وذلك صواب لمن يريد تغيير اسمه —
--      لكنه لا يصلح حين يتصل راكب يقول «اسمي مكتوب خطأ» أو يكون في
--      البيانات خطأ إملائي أدخله المدير نفسه. فالمدير مضطر أن ينتظر
--      طلباً من صاحب الشأن ليصلح خطأ يراه أمامه.
--
-- **ما يضيفه هذا الملف:**
--
--   • `admin_search_riders`  — قائمة الركّاب بإحصاءاتهم، مع بحث
--   • `admin_rider_detail`   — بطاقة راكب واحد كاملة
--   • `admin_update_profile` — تعديل مباشر يُسجَّل في سجل التدقيق
--
-- **ولماذا دوال لا استعلامات من الواجهة؟** لأن الركّاب صفوف في
-- `profiles`، وسياسات RLS عليها تمنع أحداً من رؤية غيره. فتحُها للمشرف
-- عبر سياسة جديدة يوسّع الثغرة لكل استعلام؛ والدالة `security definer`
-- تفتح ما نريد بالضبط وتغلق ما عداه.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) صلاحيتان جديدتان
-- -----------------------------------------------------------------------------
-- **`profiles.edit` منفصلة عن `riders.view` عمداً.** الاطّلاع شيء
-- والتعديل شيء آخر: موظف الدعم يحتاج أن يرى ليجيب المتصل، ولا يحتاج
-- أن يغيّر اسم أحد.
create or replace function public.known_permissions()
returns table (code text, label text)
language sql
immutable
as $fn$
  values
    ('drivers.review',  'مراجعة السائقين واعتمادهم'),
    ('drivers.view',    'عرض السائقين وأرصدتهم'),
    ('riders.view',     'عرض الركّاب وبياناتهم'),
    ('profiles.edit',   'تعديل بيانات المستخدمين مباشرةً'),
    ('trips.view',      'عرض الرحلات'),
    ('trips.cancel',    'إلغاء رحلة جارية'),
    ('topups.generate', 'توليد رموز التعبئة'),
    ('topups.view',     'عرض رموز التعبئة'),
    ('payouts.process', 'معالجة طلبات السحب'),
    ('coupons.manage',  'إنشاء الكوبونات وإيقافها'),
    ('settings.manage', 'تعديل الإعدادات العامة')
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) قائمة الركّاب مع بحث
-- -----------------------------------------------------------------------------
-- **الإحصاءات محسوبة هنا لا في الواجهة.** لو أعدنا الصفوف وحدها
-- لاحتاجت اللوحة استعلاماً لكل راكب لتعرف رحلاته — مئة راكب تعني مئة
-- طلب. الحساب في القاعدة يجعلها طلباً واحداً.
create or replace function public.admin_search_riders(
  p_query text default '',
  p_limit integer default 100
)
returns table (
  id                uuid,
  full_name         text,
  phone             text,
  email             text,
  address           text,
  date_of_birth     date,
  avatar_url        text,
  is_blocked        boolean,
  created_at        timestamptz,
  trips_total       integer,
  trips_completed   integer,
  trips_cancelled   integer,
  spent_iqd         bigint,
  last_trip_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare v_term text := trim(coalesce(p_query, ''));
begin
  if not public.has_perm('riders.view') then
    raise exception 'لا تملك صلاحية عرض الركّاب'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select
    p.id, p.full_name, p.phone, p.email, p.address, p.date_of_birth,
    p.avatar_url, p.is_blocked, p.created_at,
    coalesce(t.total, 0)::integer,
    coalesce(t.done, 0)::integer,
    coalesce(t.cancelled, 0)::integer,
    coalesce(t.spent, 0)::bigint,
    t.last_at
  from public.profiles p
  left join lateral (
    select
      count(*)                                              as total,
      count(*) filter (where tr.status = 'completed')        as done,
      count(*) filter (where tr.status = 'cancelled')        as cancelled,
      sum(tr.fare_final_iqd) filter (where tr.status = 'completed') as spent,
      max(tr.requested_at)                                   as last_at
    from public.trips tr
    where tr.rider_id = p.id
  ) t on true
  where p.role = 'rider'::public.user_role
    and (
      v_term = ''
      or p.full_name ilike '%' || v_term || '%'
      or p.phone     ilike '%' || v_term || '%'
      or p.email     ilike '%' || v_term || '%'
    )
  order by p.created_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) بطاقة راكب واحد
-- -----------------------------------------------------------------------------
-- تعيد الصف نفسه محدَّثاً. **لماذا لا نكتفي بصفّ القائمة؟** لأنه لقطة
-- وقت الفتح — بعد تعديل أو حظر يبقى معروضاً كما كان، فيظنّ المدير أن
-- الفعل لم ينفّذ ويكرّره.
create or replace function public.admin_rider_detail(p_id uuid)
returns table (
  id                uuid,
  full_name         text,
  phone             text,
  email             text,
  address           text,
  date_of_birth     date,
  avatar_url        text,
  is_blocked        boolean,
  created_at        timestamptz,
  trips_total       integer,
  trips_completed   integer,
  trips_cancelled   integer,
  spent_iqd         bigint,
  last_trip_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.has_perm('riders.view') then
    raise exception 'لا تملك صلاحية عرض الركّاب'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select
    p.id, p.full_name, p.phone, p.email, p.address, p.date_of_birth,
    p.avatar_url, p.is_blocked, p.created_at,
    coalesce(t.total, 0)::integer,
    coalesce(t.done, 0)::integer,
    coalesce(t.cancelled, 0)::integer,
    coalesce(t.spent, 0)::bigint,
    t.last_at
  from public.profiles p
  left join lateral (
    select
      count(*)                                              as total,
      count(*) filter (where tr.status = 'completed')        as done,
      count(*) filter (where tr.status = 'cancelled')        as cancelled,
      sum(tr.fare_final_iqd) filter (where tr.status = 'completed') as spent,
      max(tr.requested_at)                                   as last_at
    from public.trips tr
    where tr.rider_id = p.id
  ) t on true
  where p.id = p_id;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) رحلات راكب معيّن
-- -----------------------------------------------------------------------------
create or replace function public.admin_rider_trips(
  p_id uuid,
  p_limit integer default 50
)
returns table (
  id            uuid,
  trip_number   bigint,
  status        text,
  requested_at  timestamptz,
  pickup_address   text,
  dropoff_address  text,
  distance_m    integer,
  fare_final    integer,
  driver_name   text
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.has_perm('riders.view') then
    raise exception 'لا تملك صلاحية عرض الركّاب'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select
    t.id, t.trip_number, t.status::text, t.requested_at,
    t.pickup_address, t.dropoff_address,
    coalesce(t.actual_distance_m, t.estimated_distance_m),
    t.fare_final_iqd::integer,
    dp.full_name
  from public.trips t
  left join public.profiles dp on dp.id = t.driver_id
  where t.rider_id = p_id
  order by t.requested_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) تعديل المدير المباشر
-- -----------------------------------------------------------------------------
-- **يعمل على الراكب والسائق معاً** — الحقول في `profiles` لكليهما.
--
-- **ولماذا نسمح به وقد بنينا نظام الطلبات في 0036؟** لأن الطلب يحمي من
-- تغيير المستخدم لهويته بعد اعتماد وثائقه، ولا يحمي من خطأ إملائي في
-- الاسم أدخله المدير نفسه. الحاجتان مختلفتان:
--
--   • المستخدم يريد تغييراً  ← طلب يمرّ على إنسان   (0036)
--   • المدير يصلح خطأً       ← تعديل مباشر مسجَّل    (هنا)
--
-- **وكل تعديل يُسجَّل بما كان وما صار.** بلا ذلك يصير الباب الذي فتحناه
-- للإصلاح باباً لتغيير هوية سائق معتمَد بلا أثر.
--
-- `null` في أي معامل تعني «لا تغيّر هذا الحقل» — فيستطيع النداء أن
-- يعدّل الاسم وحده دون أن يمسّ الباقي.
create or replace function public.admin_update_profile(
  p_id            uuid,
  p_full_name     text default null,
  p_phone         text default null,
  p_address       text default null,
  p_date_of_birth date default null,
  p_avatar_url    text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_old   public.profiles;
  v_parts text[] := '{}';
begin
  if not public.has_perm('profiles.edit') then
    raise exception 'لا تملك صلاحية تعديل بيانات المستخدمين'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_old from public.profiles where id = p_id;
  if not found then
    raise exception 'المستخدم غير موجود';
  end if;

  -- **التحقق هنا لا في الواجهة.** الواجهة تُتجاوَز بنداء مباشر، والقيد
  -- في الجدول يرمي رسالة إنجليزية غامضة. نرمي رسالةً يفهمها المدير.
  if p_phone is not null and p_phone !~ '^\+9647[0-9]{9}$' then
    raise exception 'صيغة الهاتف يجب أن تكون ‎+9647XXXXXXXXX';
  end if;

  if p_full_name is not null and length(trim(p_full_name)) < 3 then
    raise exception 'الاسم قصير جداً';
  end if;

  if p_date_of_birth is not null
     and p_date_of_birth > current_date - interval '16 years' then
    raise exception 'العمر الأدنى ١٦ سنة';
  end if;

  update public.profiles set
    full_name     = coalesce(p_full_name,     full_name),
    phone         = coalesce(p_phone,         phone),
    address       = coalesce(p_address,       address),
    date_of_birth = coalesce(p_date_of_birth, date_of_birth),
    avatar_url    = coalesce(p_avatar_url,    avatar_url)
  where id = p_id;

  -- ملخّص يذكر ما تغيّر فعلاً لا ما مُرِّر
  if p_full_name is not null and p_full_name is distinct from v_old.full_name
    then v_parts := v_parts || ('الاسم: ' || v_old.full_name || ' ← ' || p_full_name);
  end if;
  if p_phone is not null and p_phone is distinct from v_old.phone
    then v_parts := v_parts || ('الهاتف: ' || v_old.phone || ' ← ' || p_phone);
  end if;
  if p_address is not null and p_address is distinct from v_old.address
    then v_parts := v_parts || 'العنوان';
  end if;
  if p_date_of_birth is not null
     and p_date_of_birth is distinct from v_old.date_of_birth
    then v_parts := v_parts || 'تاريخ الميلاد';
  end if;
  if p_avatar_url is not null and p_avatar_url is distinct from v_old.avatar_url
    then v_parts := v_parts || 'الصورة';
  end if;

  if array_length(v_parts, 1) is null then return; end if;

  perform public.log_action(
    'profile.edit',
    'profiles',
    p_id::text,
    v_old.full_name || ' — ' || array_to_string(v_parts, '، ')
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) حظر مستخدم ورفعه
-- -----------------------------------------------------------------------------
-- الحظر موجود للسائق في 0035، والراكب كان بلا مقابل — فمن يسيء لا
-- يُوقف إلا بحذف حسابه، وهو إجراء لا رجعة فيه.
create or replace function public.admin_set_blocked(
  p_id uuid,
  p_blocked boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_name text;
begin
  if not public.has_perm('profiles.edit') then
    raise exception 'لا تملك صلاحية تعديل بيانات المستخدمين'
      using errcode = 'insufficient_privilege';
  end if;

  select full_name into v_name from public.profiles where id = p_id;
  if v_name is null then raise exception 'المستخدم غير موجود'; end if;

  update public.profiles set is_blocked = p_blocked where id = p_id;

  perform public.log_action(
    case when p_blocked then 'profile.block' else 'profile.unblock' end,
    'profiles', p_id::text,
    v_name || coalesce(' — ' || p_reason, '')
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.admin_search_riders(text, integer) from public, anon;
revoke all on function public.admin_rider_detail(uuid)           from public, anon;
revoke all on function public.admin_rider_trips(uuid, integer)   from public, anon;
revoke all on function public.admin_update_profile(uuid, text, text, text, date, text)
  from public, anon;
revoke all on function public.admin_set_blocked(uuid, boolean, text) from public, anon;

grant execute on function public.admin_search_riders(text, integer) to authenticated;
grant execute on function public.admin_rider_detail(uuid)           to authenticated;
grant execute on function public.admin_rider_trips(uuid, integer)   to authenticated;
grant execute on function public.admin_update_profile(uuid, text, text, text, date, text)
  to authenticated;
grant execute on function public.admin_set_blocked(uuid, boolean, text) to authenticated;


-- -----------------------------------------------------------------------------
-- ٨) منح الصلاحيتين الجديدتين لمن يملك نظائرها
-- -----------------------------------------------------------------------------
-- **من يرى السائقين اليوم يرى الركّاب غداً.** ولو تركناها فارغة لاختفى
-- القسم عن كل موظف حتى يمرّ المالك على كلٍّ منهم — ولن يفعل، فيبلّغون
-- عن «قسم لا يفتح».
--
-- أما `profiles.edit` فلا تُمنح تلقائياً: التعديل المباشر صلاحية أثقل،
-- يمنحها المالك بيده لمن يثق به.
update public.profiles
set staff_permissions = array(
      select distinct unnest(staff_permissions || array['riders.view'])
    )
where role = 'admin'
  and 'drivers.view' = any(staff_permissions)
  and not ('riders.view' = any(staff_permissions));


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  count(*)                                        as "عدد الركّاب",
  count(*) filter (where is_blocked)              as "المحظورون"
from public.profiles where role = 'rider';

select code as "الصلاحية", label as "الوصف"
from public.known_permissions()
where code in ('riders.view', 'profiles.edit');
