-- =============================================================================
-- 0036 — طلبات تعديل البيانات، وحذف الحساب
-- =============================================================================
-- شرطان من جوجل بلاي وحاجة تشغيلية:
--
--   ١) المستخدم يرى بياناته ويطلب تعديلها — والمدير يوافق أو يرفض.
--   ٢) المستخدم يحذف حسابه من داخل التطبيق بلا وسيط.
--
-- **لماذا الطلب لا التعديل المباشر؟** لأن الاسم والهاتف وتاريخ الميلاد
-- هي ما راجعه المدير على صورة البطاقة الوطنية. تعديلٌ مباشر يعني أن
-- سائقاً معتمَداً يستطيع أن يصير شخصاً آخر بعد الاعتماد، فتسقط المراجعة
-- كلها. الطلب يُبقي البيانات مطابقةً لما رآه إنسان.
--
-- ولوحة اللون ونوع الدراجة تمرّ بالطلب أيضاً: الراكب يتعرّف على الدراجة
-- بهما، وتغييرهما بلا علم الإدارة يجعل الراكب ينتظر دراجةً لا تأتي.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) جدول الطلبات
-- -----------------------------------------------------------------------------
-- **الطلب وحدة واحدة لا حقلاً حقلاً.** من يغيّر هاتفه وعنوانه معاً يقصد
-- تغييراً واحداً، ومراجعته مجزّأة تعني موافقةً على نصف حقيقة.
create table if not exists public.profile_change_requests (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,

  -- الحقول المطلوب تغييرها وقيمها الجديدة
  changes     jsonb not null,
  -- لقطة من القيم القديمة وقت الطلب: المدير يقارن، والسجلّ يبقى مفهوماً
  -- بعد التطبيق.
  previous    jsonb not null,

  note        text,            -- سبب التعديل كما كتبه المستخدم
  status      text not null default 'pending'
                check (status in ('pending', 'approved', 'rejected')),

  created_at  timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  review_note text,

  constraint changes_not_empty check (changes <> '{}'::jsonb)
);

comment on table public.profile_change_requests is
  'طلبات تعديل بيانات المستخدمين — تنتظر موافقة الإدارة.';

create index if not exists pcr_pending_idx
  on public.profile_change_requests (created_at desc)
  where status = 'pending';

create index if not exists pcr_user_idx
  on public.profile_change_requests (user_id, created_at desc);

-- طلب معلّق واحد لكل مستخدم: طلبان متعارضان يجعلان الموافقة على أحدهما
-- تنقض الآخر بلا أن يدري أحد.
create unique index if not exists pcr_one_pending_per_user
  on public.profile_change_requests (user_id)
  where status = 'pending';


-- -----------------------------------------------------------------------------
-- ٢) تقديم الطلب — من التطبيق
-- -----------------------------------------------------------------------------
create or replace function public.request_profile_change(
  p_changes jsonb,
  p_note    text default null
)
returns public.profile_change_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid      uuid := auth.uid();
  v_role     public.user_role;
  v_prev     jsonb := '{}'::jsonb;
  v_clean    jsonb := '{}'::jsonb;
  v_key      text;
  v_val      text;
  v_row      public.profile_change_requests;
  -- الحقول المسموح طلب تغييرها. ما ليس هنا لا يُطلب إطلاقاً:
  -- البريد يوثّق بالرمز، والدور والرصيد والحالة قرارات النظام.
  v_profile_fields text[] := array['full_name','phone','date_of_birth','address'];
  v_driver_fields  text[] := array['vehicle_type','vehicle_plate','vehicle_color'];
begin
  if v_uid is null then
    raise exception 'لا توجد جلسة';
  end if;

  select role into v_role from public.profiles where id = v_uid;

  if exists (select 1 from public.profile_change_requests
             where user_id = v_uid and status = 'pending') then
    raise exception 'لديك طلب تعديل قيد المراجعة. انتظر الردّ عليه أولاً.';
  end if;


  -- حقول الملف الشخصي
  for v_key in select unnest(v_profile_fields) loop
    if p_changes ? v_key and btrim(coalesce(p_changes ->> v_key, '')) <> '' then
      v_clean := v_clean || jsonb_build_object(v_key, btrim(p_changes ->> v_key));
      execute format('select (%I)::text from public.profiles where id = $1', v_key)
        into v_val using v_uid;
      v_prev := v_prev || jsonb_build_object(v_key, v_val);
    end if;
  end loop;

  -- حقول المركبة — للسائقين وحدهم
  if v_role = 'driver' then
    for v_key in select unnest(v_driver_fields) loop
      if p_changes ? v_key and btrim(coalesce(p_changes ->> v_key, '')) <> '' then
        v_clean := v_clean || jsonb_build_object(v_key, btrim(p_changes ->> v_key));
        execute format('select (%I)::text from public.drivers where id = $1', v_key)
          into v_val using v_uid;
        v_prev := v_prev || jsonb_build_object(v_key, v_val);
      end if;
    end loop;
  end if;

  if v_clean = '{}'::jsonb then
    raise exception 'لم تغيّر شيئاً';
  end if;

  -- نطرح ما لم يتغيّر فعلاً: طلبٌ يعيد القيمة نفسها يشغل المدير بلا سبب.
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_clean
  from jsonb_each(v_clean)
  where value #>> '{}' is distinct from (v_prev ->> key);

  if v_clean = '{}'::jsonb then
    raise exception 'القيم الجديدة مطابقة للقديمة';
  end if;

  -- فحص صيغة الهاتف قبل الإزعاج: الرفض هنا أرخص من رفضٍ بعد يومين.
  if v_clean ? 'phone' then
    if (v_clean ->> 'phone') !~ '^\+9647[0-9]{9}$' then
      raise exception 'صيغة الهاتف يجب أن تكون ‎+9647XXXXXXXXX';
    end if;
    if exists (select 1 from public.profiles
               where phone = (v_clean ->> 'phone') and id <> v_uid) then
      raise exception 'هذا الرقم مسجّل لحساب آخر';
    end if;
  end if;

  if v_clean ? 'full_name'
     and exists (select 1 from public.profiles
                 where full_name = (v_clean ->> 'full_name') and id <> v_uid) then
    raise exception 'هذا الاسم مسجّل لحساب آخر';
  end if;

  insert into public.profile_change_requests (user_id, changes, previous, note)
  values (v_uid, v_clean, v_prev, nullif(btrim(p_note), ''))
  returning * into v_row;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) سحب الطلب — قبل مراجعته
-- -----------------------------------------------------------------------------
create or replace function public.cancel_profile_change()
returns void
language sql
security definer
set search_path = public, extensions
as $fn$
  delete from public.profile_change_requests
  where user_id = auth.uid() and status = 'pending';
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) مراجعة الطلب — من اللوحة
-- -----------------------------------------------------------------------------
-- **التطبيق يحدث لحظة الموافقة لا لحظة الطلب.** حتى لو مضت أيام، القيمة
-- المعتمَدة هي ما وافق عليه المدير وقرأه بعينه.
create or replace function public.admin_review_profile_change(
  p_id      uuid,
  p_approve boolean,
  p_note    text default null
)
returns public.profile_change_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row  public.profile_change_requests;
  v_name text;
  v_key  text;
begin
  if not public.has_perm('profiles.review') then
    raise exception 'لا تملك صلاحية مراجعة طلبات التعديل'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.profile_change_requests
  where id = p_id for update;

  if not found then
    raise exception 'الطلب غير موجود';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'هذا الطلب مُراجَع بالفعل';
  end if;

  select full_name into v_name from public.profiles where id = v_row.user_id;

  if p_approve then
    -- نتجاوز حارس الملف الشخصي: هذا تعديل موثوق وافق عليه إنسان.
    perform set_config('app.bypass_guards', 'on', true);

    for v_key in select jsonb_object_keys(v_row.changes) loop
      if v_key in ('full_name','phone','address') then
        execute format('update public.profiles set %I = $1 where id = $2', v_key)
          using (v_row.changes ->> v_key), v_row.user_id;
      elsif v_key = 'date_of_birth' then
        update public.profiles
        set date_of_birth = (v_row.changes ->> 'date_of_birth')::date
        where id = v_row.user_id;
      elsif v_key in ('vehicle_type','vehicle_plate','vehicle_color') then
        execute format('update public.drivers set %I = $1 where id = $2', v_key)
          using (v_row.changes ->> v_key), v_row.user_id;
      end if;
    end loop;

    perform set_config('app.bypass_guards', 'off', true);
  end if;

  update public.profile_change_requests
  set status      = case when p_approve then 'approved' else 'rejected' end,
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = nullif(btrim(p_note), '')
  where id = p_id
  returning * into v_row;

  perform public.log_action(
    case when p_approve then 'profile.change.approve' else 'profile.change.reject' end,
    'profile_change_request', p_id::text,
    format('%s طلب تعديل بيانات %s (%s)',
           case when p_approve then 'وافق على' else 'رفض' end,
           coalesce(v_name, '—'),
           (select string_agg(key, '، ') from jsonb_object_keys(v_row.changes) key))
  );

  return v_row;
end;
$fn$;


-- عمود الحذف — نحتاجه لتمييز المحذوف عن الموقوف في كل استعلام لاحق.
alter table public.profiles
  add column if not exists deleted_at timestamptz;

create index if not exists profiles_deleted_idx
  on public.profiles (deleted_at) where deleted_at is not null;


-- -----------------------------------------------------------------------------
-- ٥) حذف الحساب — من داخل التطبيق
-- -----------------------------------------------------------------------------
-- **لماذا لا نحذف الصف؟** لأن `trips.rider_id` عليه `on delete restrict`:
-- حذف الراكب يكسر سجلّ رحلاته، وفيها أجرة وعمولة ومحفظة سائق. حذفٌ
-- ينسف الدفاتر ليس حذفاً مسؤولاً.
--
-- فنحذف **الشخص** ونُبقي **الأرقام**: كل ما يعرّف صاحب الحساب يُمحى —
-- الاسم والهاتف والبريد والعنوان والميلاد والصور — ويبقى في السجلّ رحلة
-- بلا هوية. هذا ما تشترطه جوجل فعلاً، وما يبقي الحسابات صحيحة.
--
-- والبريد يُحرَّر: يستطيع صاحبه التسجيل من جديد بالبريد نفسه غداً.
create or replace function public.delete_my_account(p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, extensions, auth
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_role  public.user_role;
  v_tomb  text;
  v_open  integer;
begin
  if v_uid is null then
    raise exception 'لا توجد جلسة';
  end if;

  select role into v_role from public.profiles where id = v_uid;

  -- رحلة جارية تعني راكباً في الشارع أو سائقاً على الطريق. الحذف وسطها
  -- يترك الطرف الآخر بلا أحد.
  select count(*) into v_open
  from public.trips
  where (rider_id = v_uid or driver_id = v_uid)
    and status in ('searching','accepted','driver_arrived','in_progress');

  if v_open > 0 then
    raise exception 'لديك رحلة جارية. أنهِها أو ألغِها قبل حذف الحساب.';
  end if;

  if v_role = 'driver' then
    -- محفظة سالبة = دين على السائق. حذفٌ يمحوه يجعل الحذف باب هروب.
    if exists (select 1 from public.drivers
               where id = v_uid and wallet_balance_iqd < 0) then
      raise exception 'عليك رصيد مستحق. سدّده قبل حذف الحساب.';
    end if;

    if exists (select 1 from public.payout_requests
               where driver_id = v_uid and status = 'pending') then
      raise exception 'لديك طلب سحب معلّق. انتظر معالجته قبل حذف الحساب.';
    end if;
  end if;

  v_tomb := 'deleted-' || replace(v_uid::text, '-', '') || '@zanbour.invalid';

  perform set_config('app.bypass_guards', 'on', true);

  -- ١) الوثائق: الصفوف والملفات معاً. صورة بطاقة وطنية باقية في التخزين
  --    بعد حذف الحساب هي أسوأ ما يمكن أن يبقى.
  delete from storage.objects
  where bucket_id = 'documents' and name like v_uid::text || '/%';

  delete from public.user_documents where user_id = v_uid;

  -- ٢) رمز الإشعارات وأي طلب تعديل معلّق
  delete from public.profile_change_requests where user_id = v_uid;

  -- ٣) محو ما يعرّف الشخص
  update public.profiles
  set full_name         = 'حساب محذوف ' || left(replace(v_uid::text,'-',''), 8),
      email             = v_tomb,
      phone             = '+964700' || left(replace(v_uid::text,'-',''), 6),
      address           = '—',
      date_of_birth     = '1900-01-01',
      avatar_url        = null,
      fcm_token         = null,
      identity_verified = false,
      is_blocked        = true,
      blocked_reason    = coalesce(nullif(btrim(p_reason),''), 'حذف المستخدم حسابه'),
      deleted_at        = now()
  where id = v_uid;

  if v_role = 'driver' then
    update public.drivers
    set status              = 'offline',
        verification_status = 'rejected',
        current_location    = null,
        vehicle_plate       = null,
        vehicle_color       = null,
        vehicle_type        = null
    where id = v_uid;
  end if;

  -- ٤) تحرير البريد في نظام الدخول ومنع الدخول بالحساب القديم
  update auth.users
  set email              = v_tomb,
      phone              = null,
      raw_user_meta_data = '{}'::jsonb,
      banned_until       = 'infinity'::timestamptz
  where id = v_uid;

  perform set_config('app.bypass_guards', 'off', true);

  perform public.log_action(
    'account.delete', 'profile', v_uid::text,
    format('حذف مستخدم (%s) حسابه', v_role)
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) صلاحية المراجعة
-- -----------------------------------------------------------------------------
create or replace function public.known_permissions()
returns table (code text, label text)
language sql
immutable
as $fn$
  values
    ('drivers.review',  'مراجعة السائقين واعتمادهم'),
    ('drivers.view',    'عرض السائقين وأرصدتهم'),
    ('drivers.suspend', 'إيقاف السائقين وإلغاء اعتمادهم'),
    ('drivers.topup',   'تعبئة رصيد السائق مباشرة'),
    ('profiles.review', 'مراجعة طلبات تعديل البيانات'),
    ('trips.view',      'عرض الرحلات'),
    ('trips.cancel',    'إلغاء رحلة جارية'),
    ('topups.generate', 'توليد رموز التعبئة'),
    ('topups.view',     'عرض رموز التعبئة'),
    ('payouts.process', 'معالجة طلبات السحب'),
    ('coupons.manage',  'إنشاء الكوبونات وإيقافها'),
    ('settings.manage', 'تعديل الإعدادات العامة')
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) سياسات الأمان
-- -----------------------------------------------------------------------------
alter table public.profile_change_requests enable row level security;

drop policy if exists "pcr: يقرأ صاحبه" on public.profile_change_requests;
create policy "pcr: يقرأ صاحبه"
  on public.profile_change_requests for select
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "pcr: للمشرف كاملة" on public.profile_change_requests;
create policy "pcr: للمشرف كاملة"
  on public.profile_change_requests for all
  using (public.is_admin()) with check (public.is_admin());

-- الإدراج والحذف يمرّان بالدوال وحدها — لا سياسة كتابة للمستخدم.


-- -----------------------------------------------------------------------------
-- ٨) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.request_profile_change(jsonb, text) from public, anon;
revoke all on function public.cancel_profile_change()             from public, anon;
revoke all on function public.admin_review_profile_change(uuid, boolean, text)
  from public, anon;
revoke all on function public.delete_my_account(text)             from public, anon;

grant execute on function public.request_profile_change(jsonb, text) to authenticated;
grant execute on function public.cancel_profile_change()             to authenticated;
grant execute on function public.admin_review_profile_change(uuid, boolean, text)
  to authenticated;
grant execute on function public.delete_my_account(text)             to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.known_permissions())          as "صلاحيات",
  (select count(*) from pg_proc
     where proname in ('request_profile_change','cancel_profile_change',
                       'admin_review_profile_change','delete_my_account'))
                                                             as "دوال جديدة",
  (select count(*) from information_schema.columns
     where table_name = 'profiles' and column_name = 'deleted_at')
                                                             as "عمود الحذف";
