-- =============================================================================
-- 0092 — تعديلات المتجر تنتظر المدير، والمدير يُشعَر بكل ما ينتظره
-- =============================================================================
-- **يتطلّب 0091.**
--
-- ١) تعديل متجرٍ معتمد لا يُطبَّق حتى يوافق المدير — ويرى ما تغيّر.
--    والمتجر يستمرّ ببياناته المعتمدة أثناء المراجعة (قرار علي): تاجرٌ
--    غيّر رقم هاتفه لا يتوقف عمله حتى يفرغ المدير.
--
-- ٢) إشعارٌ لكل مديرٍ يملك الصلاحية — صاحب اللوحة دائماً، والموظفون
--    بصلاحيتهم — حين:
--      · يسجّل تاجرٌ متجراً، أو يعيد تقديمه بعد رفض
--      · يطلب تاجرٌ معتمد تعديل بياناته
--      · تكتمل وثائق سائقٍ جديد، أو يعيد رفع وثيقةٍ مرفوضة
--
--    الإشعار صفٌّ في `notifications`، فيُدفع إلى كل جهازٍ سجّله المدير:
--    تطبيق المدير، أو تطبيق زنبور إن دخله بحسابه.
-- =============================================================================

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) من يُشعَر
-- -----------------------------------------------------------------------------
-- **القاعدة نفسها التي تحكم الصلاحية** (`has_perm`): صاحب اللوحة، أو
-- مديرٌ في صلاحياته الرمز. لكن لكل مستخدمٍ لا للجلسة الحالية — فمن يطلب
-- الاعتماد تاجرٌ لا مدير.
create or replace function public.notify_admins(
  p_perm  text,
  p_title text,
  p_body  text
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_n integer;
begin
  insert into public.notifications (user_id, title, body, kind, sent_by)
  select p.id, p_title, p_body, 'direct', auth.uid()
  from public.profiles p
  where lower(p.email) = 'ali.alkawary@gmail.com'
     or (p.role = 'admin' and p_perm = any(p.staff_permissions));

  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;

-- داخليّة: تستدعيها الدوال والمُشغّلات وحدها، لا التطبيقات.
revoke all on function public.notify_admins(text, text, text)
  from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٢) التعديل المعلّق
-- -----------------------------------------------------------------------------
alter table public.stores
  -- {name, phone, address, lat, lng} كما طلبها التاجر
  add column if not exists pending_changes    jsonb,
  add column if not exists pending_changes_at timestamptz,
  -- سبب رفض آخر تعديل — يراه التاجر، ويُمسح بتعديلٍ جديد
  add column if not exists changes_rejection  text;

comment on column public.stores.pending_changes is
  'تعديلٌ طلبه تاجرٌ معتمد، لا يُطبَّق حتى يوافق المدير. المتجر يعمل '
  'ببياناته المعتمدة أثناء ذلك.';


-- **التسجيل الأول والإعادة بعد الرفض يُطبَّقان مباشرةً** — المتجر لم
-- يُعتمد بعد، فالمراجعة القادمة تشمل كل شيء. **والمعتمد والموقوف
-- يُعلَّق تعديلهما.**
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

    perform public.notify_admins('stores.review',
      'متجرٌ جديد ينتظر اعتمادك',
      format('«%s» — %s. افتح «المتاجر» في لوحة المدير.', v_name,
             coalesce(v_owner, '')));
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
      perform public.notify_admins('stores.review',
        'متجرٌ أعاد التقديم',
        format('«%s» عدّل بياناته بعد الرفض وينتظر المراجعة.', v_name));
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


-- المدير يعتمد التعديل أو يرفضه
create or replace function public.admin_review_store_changes(
  p_store_id uuid,
  p_approve  boolean,
  p_reason   text default null
)
returns public.stores
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row    public.stores;
  v_c      jsonb;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_perm('stores.review') then
    raise exception 'لا تملك صلاحية مراجعة المتاجر'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.stores where id = p_store_id for update;
  if not found then raise exception 'المتجر غير موجود'; end if;

  v_c := v_row.pending_changes;
  if v_c is null then raise exception 'لا تعديل معلّق على هذا المتجر'; end if;

  if p_approve then
    update public.stores
    set name     = v_c ->> 'name',
        phone    = v_c ->> 'phone',
        address  = v_c ->> 'address',
        location = st_setsrid(st_makepoint((v_c ->> 'lng')::double precision,
                                           (v_c ->> 'lat')::double precision),
                              4326)::geography,
        pending_changes = null, pending_changes_at = null,
        changes_rejection = null,
        reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_store_id
    returning * into v_row;
  else
    if v_reason is null then
      raise exception 'اكتب سبب رفض التعديل — يراه التاجر';
    end if;
    update public.stores
    set pending_changes = null, pending_changes_at = null,
        changes_rejection = v_reason,
        reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_store_id
    returning * into v_row;
  end if;

  perform public.log_action(
    'stores.review_changes', 'stores', p_store_id::text,
    format('%s — %s%s', v_row.name,
           case when p_approve then 'اعتُمد التعديل' else 'رُفض التعديل' end,
           coalesce(' — ' || v_reason, '')));

  insert into public.notifications (user_id, title, body, kind, sent_by)
  values (
    v_row.owner_id,
    case when p_approve then 'اعتُمد تعديل متجرك' else 'لم يُعتمد تعديل متجرك' end,
    case when p_approve
      then format('بيانات «%s» محدّثة الآن.', v_row.name)
      else format('السبب: %s. متجرك يعمل ببياناته السابقة.', v_reason)
    end,
    'direct',
    auth.uid()
  );

  return v_row;
end;
$fn$;

revoke all on function public.admin_review_store_changes(uuid, boolean, text) from public, anon;
grant execute on function public.admin_review_store_changes(uuid, boolean, text) to authenticated;


-- قائمة المدير تحمل التعديل المعلّق، و`changes` مرشِّحٌ له.
-- **حذفٌ ثم إنشاء:** تغيير أعمدة الناتج لا يقبله `create or replace`.
drop function if exists public.admin_list_stores(text, text);

create function public.admin_list_stores(
  p_status text default null,
  p_search text default null
)
returns table (
  id                 uuid,
  owner_id           uuid,
  name               text,
  phone              text,
  address            text,
  lat                double precision,
  lng                double precision,
  status             public.store_status,
  rejection_reason   text,
  created_at         timestamptz,
  updated_at         timestamptz,
  reviewed_at        timestamptz,
  owner_name         text,
  owner_phone        text,
  owner_email        text,
  deliveries_total   bigint,
  deliveries_active  bigint,
  open_settlements   bigint,
  open_amount_iqd    numeric,
  pending_changes    jsonb,
  pending_changes_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not public.has_perm('stores.review') then
    raise exception 'لا تملك صلاحية مراجعة المتاجر'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select s.id, s.owner_id, s.name, s.phone, s.address, s.lat, s.lng,
         s.status, s.rejection_reason, s.created_at, s.updated_at,
         s.reviewed_at,
         p.full_name, p.phone, p.email,
         (select count(*) from public.trips t where t.store_id = s.id),
         (select count(*) from public.trips t where t.store_id = s.id
            and t.status in ('searching','accepted','driver_arrived','in_progress')),
         (select count(*) from public.trips t where t.store_id = s.id
            and t.settle_status in ('open','claimed','disputed')),
         (select coalesce(sum(t.goods_actual_iqd), 0) from public.trips t
            where t.store_id = s.id
              and t.settle_status in ('open','claimed','disputed')),
         s.pending_changes, s.pending_changes_at
  from public.stores s
  join public.profiles p on p.id = s.owner_id
  where (p_status is null
         or (p_status = 'changes' and s.pending_changes is not null)
         or s.status::text = p_status)
    and (v_q is null
         or s.name ilike '%' || v_q || '%'
         or s.phone ilike '%' || v_q || '%'
         or p.full_name ilike '%' || v_q || '%'
         or p.phone ilike '%' || v_q || '%')
  order by (s.status = 'pending') desc,
           (s.pending_changes is not null) desc,
           s.created_at desc;
end;
$fn$;

revoke all on function public.admin_list_stores(text, text) from public, anon;
grant execute on function public.admin_list_stores(text, text) to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) السائق الذي ينتظر المراجعة
-- -----------------------------------------------------------------------------
-- **مرّةً حين تكتمل وثائقه، لا مع كل صورة.** أربع وثائق مطلوبة؛ إشعارٌ
-- مع كلٍّ منها أربعة إشعارات لسائقٍ واحد، فيتعلّم المدير تجاهلها.
--
-- «تكتمل» = هذا الرفع جعل الأنواع الأربعة موجودةً بحالةٍ غير مرفوضة،
-- ولم تكن كذلك قبله. فيشمل السائق الجديد، ومن أعاد رفع وثيقةٍ مرفوضة.
-- وصور المركبة الإضافية لا تُطلق شيئاً — النوع موجودٌ أصلاً.
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

drop trigger if exists user_documents_notify_admins on public.user_documents;
create trigger user_documents_notify_admins
  after insert on public.user_documents
  for each row execute function public.notify_driver_docs_complete();


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
   where table_name = 'stores' and column_name in
     ('pending_changes', 'pending_changes_at', 'changes_rejection'))   as "أعمدة التعديل (٣)",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('notify_admins', 'admin_review_store_changes',
                     'notify_driver_docs_complete'))                    as "الدوال (٣)",
  (select count(*) from pg_trigger
   where tgname = 'user_documents_notify_admins')                       as "مُشغّل السائقين (١)",
  (select count(*) from public.profiles
   where lower(email) = 'ali.alkawary@gmail.com'
      or (role = 'admin' and 'stores.review' = any(staff_permissions)))
                                                                        as "من يُشعَر بالمتاجر (١+)";
