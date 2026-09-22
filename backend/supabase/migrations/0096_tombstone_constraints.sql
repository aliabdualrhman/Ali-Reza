-- =============================================================================
-- 0096 — إخفاء هوية الحساب المحذوف لم ينجح قط: ثلاثة قيود يخالفها
-- =============================================================================
-- ظهر بعد 0095: حذف السائق انتقل من المحو إلى التجهيل — فسقط التجهيل نفسه
-- بـ `profiles_address_not_blank`. والفحص كشف أن قيم التجهيل كلها تخالف
-- قيود `profiles` في 0002، **منذ كُتبت في 0036**:
--
--   العنوان   '—'                    ← يُشترط ٥ أحرف على الأقل
--   الهاتف    '+964700' + حروفٌ ست    ← يُشترط +9647[3-9] وثمانية أرقام، وفريد
--   الميلاد   1900-01-01              ← يُشترط بعد 1900-01-01
--
-- فلم يُحذف حسابٌ له رحلات قط — لا من اللوحة ولا من «حذف حسابي» في
-- التطبيقين (والأخير شرطٌ في المتجرين).
--
-- الدالتان منسوختان آلياً من آخر تعريف (0095 و0046)، والتغيير الأسطر
-- الثلاثة وحدها.
-- =============================================================================

set search_path = public, extensions;


-- **رقمٌ وهميٌّ صالحٌ وفريد.** `+96473` بادئةٌ لا تستعملها شبكات العراق
-- (زين 78/79، آسيا 77، كورك 75)، فلا يصطدم برقم إنسان. والهاتف فريدٌ في
-- الجدول، فنتحقق ونزيد حتى نجد رقماً خالياً.
create or replace function public.tombstone_phone(p_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $fn$
declare
  n integer := 0;
  v text;
begin
  loop
    v := '+96473' || lpad((abs(hashtext(p_id::text || ':' || n)) % 100000000)::text, 8, '0');
    exit when not exists (select 1 from public.profiles where phone = v);
    n := n + 1;
  end loop;
  return v;
end;
$fn$;

revoke all on function public.tombstone_phone(uuid) from public, anon, authenticated;


create or replace function public.admin_delete_account(
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
  -- **المحو يُحاوَل، ولا يُفرض.** بلا رحلات لا يعني بلا سجلات: رصيد
  -- الترحيب عند التسجيل، وتعبئةٌ، وتسوية سحب — كلها حركات محفظة تمنع
  -- محو السائق (المفتاح الأجنبي `restrict`). فكان الحذف يفشل لكل سائقٍ
  -- تقريباً برسالة `wallet_transactions_driver_id_fkey`.
  --
  -- فإن منعته سجلاتٌ تُحفظ، **نُجهّل بدل أن نفشل** — كمن له رحلات. والمال
  -- يبقى في الدفاتر كما وعدت سياسة الخصوصية.
  if v_trips = 0 then
    begin
      delete from auth.users where id = p_id;
      perform set_config('app.bypass_guards', 'off', true);
      perform public.log_action(
        'account.purge', 'profiles', p_id::text,
        v_name || ' — محو كامل' || coalesce(' — ' || p_reason, '')
      );
      return jsonb_build_object('result', 'purged', 'paths', to_jsonb(v_paths));
    exception when foreign_key_violation then
      null;   -- له سجلات تُحفظ ← التجهيل أدناه
    end;
  end if;

  -- ------------------------------------------------------------------
  -- له رحلات ← تجهيل
  -- ------------------------------------------------------------------
  v_tomb := 'deleted-' || replace(p_id::text, '-', '') || '@zanbour.invalid';

  update public.profiles
  set full_name         = 'حساب محذوف ' || left(replace(p_id::text,'-',''), 8),
      email             = v_tomb,
      phone             = public.tombstone_phone(p_id),
      address           = 'حساب محذوف',
      date_of_birth     = '1900-01-02',
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


create or replace function public.delete_my_account(p_reason text default null)
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
      phone             = public.tombstone_phone(v_uid),
      address           = 'حساب محذوف',
      date_of_birth     = '1900-01-02',
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

revoke all on function public.delete_my_account(text)             from public, anon;
revoke all on function public.admin_delete_account(uuid, text)    from public, anon;
grant execute on function public.delete_my_account(text)          to authenticated;
grant execute on function public.admin_delete_account(uuid, text) to authenticated;


-- فحص: القيم الجديدة تمرّ من القيود (يجب true ثلاث مرات)
select
  public.tombstone_phone(gen_random_uuid()) ~ '^\+9647[3-9][0-9]{8}$' as "الهاتف صالح",
  length(btrim('حساب محذوف')) >= 5                                    as "العنوان صالح",
  date '1900-01-02' > date '1900-01-01'                               as "الميلاد صالح";
