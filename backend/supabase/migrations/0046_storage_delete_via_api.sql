-- =============================================================================
-- 0046 — حذف الملفات يمرّ بواجهة التخزين لا بجدولها
-- =============================================================================
-- **العطل.** Supabase منعت الحذف المباشر من جداول التخزين:
--
--     ERROR 42501: Direct deletion from storage tables is not allowed.
--                  Use the Storage API instead.
--
-- ودالتان عندنا تفعلانه:
--
--   • `delete_my_account` (0036) — **وهي شرط قبول عند جوجل بلاي.**
--   • `admin_delete_account` (0045)
--
-- **فحذف الحساب معطّل في التطبيق وفي اللوحة معاً.** ولم يظهر لأن أحداً
-- لم يجرّبه على قاعدة حيّة — والمنع أضافته Supabase بعد أن كُتبت 0036.
--
-- **الحل: تفصل الدالة ما تملكه عمّا لا تملكه.**
--
-- تمحو صفوف قاعدة البيانات كما كانت، **وتعيد مسارات الملفات** بدل أن
-- تحذفها. والتطبيق يحذفها بواجهة التخزين — وهي الطريق الوحيد المسموح.
--
-- **ولماذا الترتيب: الدالة أولاً ثم الملفات؟** لأن حرّاس الدالة (رحلة
-- جارية، دين مستحق) قد يرفضون الحذف. ولو حذفنا الملفات أولاً لخسر
-- السائق وثائقه ثم بقي مسجَّلاً — فيضطر لرفعها كلها من جديد بلا ذنب.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) حذف المستخدم لحسابه — تعيد المسارات
-- -----------------------------------------------------------------------------
-- **نغيّر نوع الإرجاع، فنحذف ثم نُنشئ.** والتطبيق القديم الذي يتجاهل
-- القيمة المعادة يبقى يعمل — تُحذف صفوفه ويبقى ملفٌ يتيم في التخزين
-- حتى يُحدَّث. أهون من تعطيل الحذف كله.
drop function if exists public.delete_my_account(text);

create function public.delete_my_account(p_reason text default null)
returns text[]
language plpgsql
security definer
set search_path = public, extensions, auth
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_role  public.user_role;
  v_tomb  text;
  v_open  integer;
  v_paths text[];
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

  -- **نجمع المسارات قبل حذف صفوفها.** بعد الحذف لا يبقى ما يدلّ على
  -- الملفات، فتبقى في التخزين إلى الأبد بلا من يعرف بوجودها.
  select coalesce(array_agg(storage_path), '{}')
  into v_paths
  from public.user_documents where user_id = v_uid;

  v_tomb := 'deleted-' || replace(v_uid::text, '-', '') || '@zanbour.invalid';

  perform set_config('app.bypass_guards', 'on', true);

  delete from public.user_documents          where user_id = v_uid;
  delete from public.profile_change_requests where user_id = v_uid;

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

  return v_paths;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) حذف المدير — يعيد النتيجة والمسارات معاً
-- -----------------------------------------------------------------------------
drop function if exists public.admin_delete_account(uuid, text);

create function public.admin_delete_account(
  p_id     uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, auth
as $fn$
declare
  v_role  public.user_role;
  v_name  text;
  v_trips integer;
  v_open  integer;
  v_tomb  text;
  v_paths text[];
begin
  if not public.has_perm('accounts.delete') then
    raise exception 'لا تملك صلاحية حذف الحسابات'
      using errcode = 'insufficient_privilege';
  end if;

  select role, full_name into v_role, v_name
  from public.profiles where id = p_id;

  if v_name is null then raise exception 'المستخدم غير موجود'; end if;

  if v_role = 'admin' then
    raise exception 'حسابات المشرفين تُدار من صفحة المستخدمين';
  end if;

  select count(*) into v_open
  from public.trips
  where (rider_id = p_id or driver_id = p_id)
    and status in ('searching','accepted','driver_arrived','in_progress');

  if v_open > 0 then
    raise exception 'لهذا الحساب رحلة جارية. أنهِها أو ألغِها أولاً.';
  end if;

  select count(*) into v_trips
  from public.trips where rider_id = p_id or driver_id = p_id;

  if v_trips > 0
     and v_role = 'driver'
     and exists (select 1 from public.drivers
                 where id = p_id and wallet_balance_iqd < 0) then
    raise exception 'على هذا السائق رصيد مستحق. سوِّه قبل الحذف.';
  end if;

  select coalesce(array_agg(storage_path), '{}')
  into v_paths
  from public.user_documents where user_id = p_id;

  perform set_config('app.bypass_guards', 'on', true);

  delete from public.user_documents          where user_id = p_id;
  delete from public.profile_change_requests where user_id = p_id;

  -- ------------------------------------------------------------------
  -- بلا رحلات ← محوٌ كامل
  -- ------------------------------------------------------------------
  if v_trips = 0 then
    delete from auth.users where id = p_id;

    perform set_config('app.bypass_guards', 'off', true);
    perform public.log_action(
      'account.purge', 'profiles', p_id::text,
      v_name || ' — محو كامل' || coalesce(' — ' || p_reason, '')
    );
    return jsonb_build_object('result', 'purged', 'paths', to_jsonb(v_paths));
  end if;

  -- ------------------------------------------------------------------
  -- له رحلات ← تجهيل
  -- ------------------------------------------------------------------
  v_tomb := 'deleted-' || replace(p_id::text, '-', '') || '@zanbour.invalid';

  update public.profiles
  set full_name         = 'حساب محذوف ' || left(replace(p_id::text,'-',''), 8),
      email             = v_tomb,
      phone             = '+964700' || left(replace(p_id::text,'-',''), 6),
      address           = '—',
      date_of_birth     = '1900-01-01',
      avatar_url        = null,
      fcm_token         = null,
      identity_verified = false,
      is_blocked        = true,
      blocked_reason    = coalesce(nullif(btrim(p_reason),''), 'حذفه المدير'),
      deleted_at        = now()
  where id = p_id;

  if v_role = 'driver' then
    update public.drivers
    set status              = 'offline',
        verification_status = 'rejected',
        current_location    = null,
        vehicle_plate       = null,
        vehicle_color       = null,
        vehicle_type        = null
    where id = p_id;
  end if;

  update auth.users
  set email              = v_tomb,
      phone              = null,
      raw_user_meta_data = '{}'::jsonb,
      banned_until       = 'infinity'::timestamptz
  where id = p_id;

  perform set_config('app.bypass_guards', 'off', true);

  perform public.log_action(
    'account.delete', 'profiles', p_id::text,
    v_name || format(' — تجهيل (%s رحلة محفوظة)', v_trips)
      || coalesce(' — ' || p_reason, '')
  );

  return jsonb_build_object('result', 'anonymized', 'paths', to_jsonb(v_paths));
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.delete_my_account(text)             from public, anon;
revoke all on function public.admin_delete_account(uuid, text)    from public, anon;

grant execute on function public.delete_my_account(text)          to authenticated;
grant execute on function public.admin_delete_account(uuid, text) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  p.proname                          as "الدالة",
  pg_get_function_result(p.oid)      as "تعيد"
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('delete_my_account', 'admin_delete_account')
order by p.proname;
