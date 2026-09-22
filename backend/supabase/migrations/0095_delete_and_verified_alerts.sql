-- =============================================================================
-- 0095 — حذف السائق لا يفشل، والمدير لا يُشعَر إلا بحسابٍ موثَّق
-- =============================================================================
-- **يتطلّب 0092.** الدوال الثلاث منسوخةٌ آلياً من آخر تعريفٍ لكلٍّ منها
-- (انظر رأس 0093 — نسخُ نسخةٍ أقدم هو ما أسقط حجز السحب).
--
-- ١) حذف السائق من اللوحة كان يفشل: «بلا رحلات» يختار المحو الكامل، وحركات
--    المحفظة (رصيد الترحيب، التعبئة، التسويات) تمنع المحو. صار يُجهّل إن
--    مُنع المحو، ولا يفشل.
--
-- ٢) إشعارات «ينتظر اعتمادك» (0092) لا تصل إلا بعد أن يوثّق صاحب الحساب
--    بريده **أو** هاتفه. ومن اكتملت وثائقه أو سجّل متجره قبل التوثيق،
--    يصل عنه الإشعار لحظة التوثيق.
-- =============================================================================

set search_path = public, extensions;


-- موثَّق = بريدٌ أو هاتف، أحدهما على الأقل.
create or replace function public.account_verified(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select coalesce(phone_verified, false) or coalesce(email_verified, false)
  from public.profiles where id = p_uid;
$fn$;

revoke all on function public.account_verified(uuid) from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- ١) الحذف
-- -----------------------------------------------------------------------------
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
-- ٢) المتجر — الإشعار بعد التوثيق
-- -----------------------------------------------------------------------------
create or replace function public.save_my_store(
  p_name    text,
  p_phone   text,
  p_address text,
  p_lat     double precision,
  p_lng     double precision
)
returns public.stores
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid     uuid := auth.uid();
  v_name    text := btrim(coalesce(p_name, ''));
  v_phone   text := btrim(coalesce(p_phone, ''));
  v_addr    text := btrim(coalesce(p_address, ''));
  v_loc     geography;
  v_row     public.stores;
  v_owner   text;
  v_moved   integer;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  if exists (select 1 from public.profiles where id = v_uid and is_blocked) then
    raise exception 'حسابك موقوف' using errcode = 'insufficient_privilege';
  end if;

  if length(v_name) < 2 or length(v_name) > 60 then
    raise exception 'اسم المتجر من حرفين إلى ٦٠ حرفاً';
  end if;
  if v_phone !~ '^\+?[0-9 ]{7,20}$' then
    raise exception 'رقم هاتف المتجر غير صحيح';
  end if;
  if length(v_addr) < 3 then
    raise exception 'اكتب عنوان المتجر';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'حدّد موقع المتجر على الخريطة';
  end if;

  v_loc := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  if public.zone_for_point(v_loc) is null then
    raise exception 'موقع المتجر خارج نطاق الخدمة';
  end if;

  select full_name into v_owner from public.profiles where id = v_uid;

  select * into v_row from public.stores where owner_id = v_uid for update;

  -- ---- جديد ----
  if not found then
    insert into public.stores (owner_id, name, phone, address, location)
    values (v_uid, v_name, v_phone, v_addr, v_loc)
    returning * into v_row;

    if public.account_verified(v_uid) then
    perform public.notify_admins('stores.review',
      'متجرٌ جديد ينتظر اعتمادك',
      format('«%s» — %s. افتح «المتاجر» في لوحة المدير.', v_name,
             coalesce(v_owner, '')));
    end if;
    return v_row;
  end if;

  -- ---- لم يُعتمد بعد، أو رُفض: يُطبَّق ويُراجَع كاملاً ----
  if v_row.status in ('pending', 'rejected') then
    update public.stores
    set name = v_name, phone = v_phone, address = v_addr, location = v_loc,
        status = 'pending', rejection_reason = null,
        pending_changes = null, pending_changes_at = null
    where id = v_row.id
    returning * into v_row;

    -- إعادة التقديم خبرٌ للمدير؛ تعديل طلبٍ ما زال ينتظر ليس خبراً جديداً.
    if v_row.reviewed_at is not null then
      if public.account_verified(v_uid) then
    perform public.notify_admins('stores.review',
        'متجرٌ أعاد التقديم',
        format('«%s» عدّل بياناته بعد الرفض وينتظر المراجعة.', v_name));
    end if;
    end if;
    return v_row;
  end if;

  -- ---- معتمد أو موقوف: التعديل يُعلَّق ----
  v_moved := st_distance(v_row.location, v_loc)::integer;

  if v_name = v_row.name and v_phone = v_row.phone
     and v_addr = v_row.address and v_moved < 5 then
    -- لا شيء تغيّر: نُلغي أيّ تعديلٍ معلّق سابق ولا نُزعج المدير.
    update public.stores
    set pending_changes = null, pending_changes_at = null
    where id = v_row.id
    returning * into v_row;
    return v_row;
  end if;

  update public.stores
  set pending_changes = jsonb_build_object(
        'name', v_name, 'phone', v_phone, 'address', v_addr,
        'lat', p_lat, 'lng', p_lng),
      pending_changes_at = now(),
      changes_rejection  = null
  where id = v_row.id
  returning * into v_row;

  perform public.notify_admins('stores.review',
    'متجرٌ يطلب تعديل بياناته',
    format('«%s» عدّل: %s. افتح «المتاجر» لتراجع التعديل.',
           v_row.name,
           concat_ws('، ',
             case when v_name  <> v_row.name    then 'الاسم' end,
             case when v_phone <> v_row.phone   then 'الهاتف' end,
             case when v_addr  <> v_row.address then 'العنوان' end,
             case when v_moved >= 5 then format('الموقع (%s م)', v_moved) end)));

  return v_row;
end;
$fn$;

revoke all on function public.save_my_store(text, text, text, double precision, double precision)
  from public, anon;
grant execute on function public.save_my_store(text, text, text, double precision, double precision)
  to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) السائق — الإشعار بعد التوثيق
-- -----------------------------------------------------------------------------
create or replace function public.notify_driver_docs_complete()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_required public.document_type[] := array[
    'live_selfie', 'national_id_front', 'national_id_back', 'vehicle_photo'
  ]::public.document_type[];
  v_before integer;
  v_after  integer;
  v_name   text;
  v_again  boolean;
begin
  if not (new.doc_type = any(v_required)) then return new; end if;
  if not exists (select 1 from public.profiles
                 where id = new.user_id and role = 'driver') then
    return new;
  end if;

  select count(distinct doc_type) filter (where id <> new.id),
         count(distinct doc_type)
  into v_before, v_after
  from public.user_documents
  where user_id = new.user_id
    and doc_type = any(v_required)
    and status <> 'rejected';

  if v_after < array_length(v_required, 1)
     or v_before = array_length(v_required, 1) then
    return new;
  end if;

  -- **لا يصل المديرَ إلا حسابٌ موثَّق** (قرار علي): بريدٌ أو هاتف. ومن
  -- رفع وثائقه قبل التوثيق يُبلَّغ عنه لحظة يوثّق — المُشغّل أدناه.
  if not public.account_verified(new.user_id) then
    return new;
  end if;

  select full_name into v_name from public.profiles where id = new.user_id;
  v_again := exists (select 1 from public.user_documents
                     where user_id = new.user_id and status = 'rejected');

  perform public.notify_admins('drivers.review',
    case when v_again then 'سائقٌ أعاد رفع وثائقه' else 'سائقٌ جديد ينتظر اعتمادك' end,
    format('%s — وثائقه كاملة. افتح «المراجعة» في لوحة المدير.',
           coalesce(v_name, 'سائق')));

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) لحظة التوثيق: ما كان ينتظرها يُبلَّغ عنه الآن
-- -----------------------------------------------------------------------------
-- **الانتقال وحده يُطلق:** من «لا بريد ولا هاتف» إلى «أحدهما». توثيق
-- الثاني بعد الأول لا يُعيد الإشعار.
create or replace function public.notify_admins_on_verified()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_required public.document_type[] := array[
    'live_selfie', 'national_id_front', 'national_id_back', 'vehicle_photo'
  ]::public.document_type[];
  v_docs integer;
begin
  if (coalesce(old.phone_verified, false) or coalesce(old.email_verified, false))
     or not (coalesce(new.phone_verified, false) or coalesce(new.email_verified, false))
  then
    return new;
  end if;

  -- سائقٌ وثائقه كاملة وينتظر
  if new.role = 'driver'
     and exists (select 1 from public.drivers
                 where id = new.id and verification_status = 'pending')
  then
    select count(distinct doc_type) into v_docs
    from public.user_documents
    where user_id = new.id
      and doc_type = any(v_required)
      and status <> 'rejected';

    if v_docs = array_length(v_required, 1) then
      perform public.notify_admins('drivers.review',
        'سائقٌ جديد ينتظر اعتمادك',
        format('%s — وثّق حسابه ووثائقه كاملة. افتح «المراجعة» في لوحة المدير.',
               coalesce(new.full_name, 'سائق')));
    end if;
  end if;

  -- متجرٌ ينتظر
  if exists (select 1 from public.stores
             where owner_id = new.id and status = 'pending') then
    perform public.notify_admins('stores.review',
      'متجرٌ جديد ينتظر اعتمادك',
      format('%s — وثّق حسابه. افتح «المتاجر» في لوحة المدير.',
             coalesce(new.full_name, '')));
  end if;

  return new;
end;
$fn$;

drop trigger if exists profiles_notify_admins_on_verified on public.profiles;
create trigger profiles_notify_admins_on_verified
  after update of phone_verified, email_verified on public.profiles
  for each row execute function public.notify_admins_on_verified();


-- -----------------------------------------------------------------------------
-- فحص
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname = 'admin_delete_account' and prosrc like '%foreign_key_violation%')
                                                              as "الحذف لا يفشل (١)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('save_my_store', 'notify_driver_docs_complete')
     and prosrc like '%account_verified%')                    as "الإشعار بعد التوثيق (٢)",
  (select count(*) from pg_trigger
   where tgname = 'profiles_notify_admins_on_verified')       as "مُشغّل التوثيق (١)";
