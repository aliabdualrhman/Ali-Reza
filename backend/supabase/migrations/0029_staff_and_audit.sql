set search_path = public, extensions;

-- =============================================================================
-- 0029 — الموظفون وصلاحياتهم، وسجلّ التدقيق
-- =============================================================================
-- حتى اليوم كان في النظام رتبتان: مستخدم ومشرف. والمشرف يملك كل شيء —
-- يعتمد السائقين، ويولّد المال (رموز التعبئة)، ويدفع السحوبات.
--
-- **هذا لا يصمد مع موظف واحد.** من يراجع الوثائق لا يجب أن يولّد رموزاً،
-- ومن يدفع السحوبات لا يجب أن ينشئ كوبونات. وحين يختلف رقمان في آخر
-- الشهر يجب أن نعرف **من** فعل ماذا ومتى.
--
-- فهذا الملف يضيف طبقتين: **صلاحيات مفصّلة**، و**سجلّ لا يُمحى**.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) المالك
-- -----------------------------------------------------------------------------
-- **بريدٌ واحد لا يُمنح ولا يُسحب.** لو جعلنا الملكية صلاحيةً في جدول
-- لأمكن لمشرفٍ أن يمنحها نفسه، أو أن يسحبها من الجميع فيُقفل النظام على
-- لا أحد. ربطها بالبريد يجعلها ثابتة خارج متناول الجدول.
create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and lower(email) = 'ali.alkawary@gmail.com'
  );
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الصلاحيات
-- -----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists staff_permissions text[] not null default '{}';

comment on column public.profiles.staff_permissions is
  'صلاحيات الموظف. المالك يملك كل شيء بلا حاجة إليها.';

-- الصلاحيات المعروفة — تُقرأ في لوحة التحكم لبناء قائمة الاختيار،
-- فلا تتفرّق أسماؤها بين الخادم والواجهة.
create or replace function public.known_permissions()
returns table (code text, label text)
language sql
immutable
as $fn$
  values
    ('drivers.review',  'مراجعة السائقين واعتمادهم'),
    ('drivers.view',    'عرض السائقين وأرصدتهم'),
    ('trips.view',      'عرض الرحلات'),
    ('trips.cancel',    'إلغاء رحلة جارية'),
    ('topups.generate', 'توليد رموز التعبئة'),
    ('topups.view',     'عرض رموز التعبئة'),
    ('payouts.process', 'معالجة طلبات السحب'),
    ('coupons.manage',  'إنشاء الكوبونات وإيقافها'),
    ('settings.manage', 'تعديل الإعدادات العامة')
$fn$;


create or replace function public.has_perm(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select public.is_owner()
      or exists (
        select 1 from public.profiles
        where id = auth.uid()
          and role = 'admin'
          and p_code = any(staff_permissions)
      );
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) سجلّ التدقيق
-- -----------------------------------------------------------------------------
-- **لا حذف ولا تعديل، حتى للمالك.** سجلٌّ يستطيع صاحبه محوه ليس سجلاً.
create table if not exists public.audit_log (
  id         bigserial primary key,
  actor_id   uuid references public.profiles(id),
  actor_name text,          -- منسوخ وقت الفعل: الحساب قد يُحذف والسجل يبقى
  action     text not null, -- 'topup.generate' · 'coupon.create' …
  entity     text,
  entity_id  text,
  summary    text,          -- وصف عربي جاهز للعرض بلا تفسير في الواجهة
  created_at timestamptz not null default now()
);

create index if not exists audit_log_recent_idx on public.audit_log (created_at desc);
create index if not exists audit_log_actor_idx  on public.audit_log (actor_id, created_at desc);

alter table public.audit_log enable row level security;

drop policy if exists "audit: يقرأ المشرف" on public.audit_log;
create policy "audit: يقرأ المشرف"
  on public.audit_log for select to authenticated
  using (public.is_admin());

-- لا سياسة إدراج ولا تحديث ولا حذف: الكتابة تمرّ بالدالة وحدها.

create or replace function public.log_action(
  p_action  text,
  p_entity  text default null,
  p_id      text default null,
  p_summary text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_name text;
begin
  select full_name into v_name from public.profiles where id = auth.uid();
  insert into public.audit_log (actor_id, actor_name, action, entity, entity_id, summary)
  values (auth.uid(), v_name, p_action, p_entity, p_id, p_summary);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) تسجيل الأفعال المالية
-- -----------------------------------------------------------------------------
-- **مُشغّلات لا نداءات من الواجهة.** لو تركنا التسجيل للتطبيق لنسيه أول
-- مسار جديد، ولاستطاع من ينادي الدالة مباشرةً تخطّيه. المُشغّل يلتقط
-- الفعل من مصدره مهما كان الطريق.
create or replace function public.audit_topup_code()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if tg_op = 'INSERT' then
    perform public.log_action('topup.generate', 'topup_code', new.id::text,
      format('ولّد رمز تعبئة بقيمة %s دينار', new.amount_iqd::bigint));
  elsif new.redeemed_by is distinct from old.redeemed_by
        and new.redeemed_by is not null then
    perform public.log_action('topup.redeem', 'topup_code', new.id::text,
      format('استُهلك رمز بقيمة %s دينار', new.amount_iqd::bigint));
  end if;
  return new;
end;
$fn$;

drop trigger if exists topup_codes_audit on public.topup_codes;
create trigger topup_codes_audit
  after insert or update of redeemed_by on public.topup_codes
  for each row execute function public.audit_topup_code();


create or replace function public.audit_coupon()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if tg_op = 'INSERT' then
    perform public.log_action('coupon.create', 'coupon', new.id::text,
      format('أنشأ كوبون %s بخصم %s٪', new.code, new.discount_pct));
  elsif new.is_active is distinct from old.is_active then
    perform public.log_action(
      case when new.is_active then 'coupon.enable' else 'coupon.disable' end,
      'coupon', new.id::text,
      format('%s الكوبون %s',
             case when new.is_active then 'فعّل' else 'أوقف' end, new.code));
  end if;
  return new;
end;
$fn$;

drop trigger if exists coupons_audit on public.coupons;
create trigger coupons_audit
  after insert or update of is_active on public.coupons
  for each row execute function public.audit_coupon();


create or replace function public.audit_payout()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.status is distinct from old.status then
    perform public.log_action('payout.' || new.status, 'payout', new.id::text,
      format('%s طلب سحب بقيمة %s دينار',
             case new.status when 'paid' then 'دفع' else 'رفض' end,
             new.amount_iqd::bigint));
  end if;
  return new;
end;
$fn$;

drop trigger if exists payout_requests_audit on public.payout_requests;
create trigger payout_requests_audit
  after update of status on public.payout_requests
  for each row execute function public.audit_payout();


-- -----------------------------------------------------------------------------
-- ٥) إدارة الموظفين — للمالك وحده
-- -----------------------------------------------------------------------------
create or replace function public.staff_list()
returns table (
  id          uuid,
  full_name   text,
  email       text,
  phone       text,
  permissions text[],
  is_owner    boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select p.id, p.full_name, p.email, p.phone, p.staff_permissions,
         lower(p.email) = 'ali.alkawary@gmail.com'
  from public.profiles p
  where p.role = 'admin'
    and public.is_owner()
  order by lower(p.email) = 'ali.alkawary@gmail.com' desc, p.full_name;
$fn$;


-- يرقّي حساباً قائماً إلى موظف بصلاحيات محددة.
--
-- **لا ننشئ حساباً هنا.** إنشاء المستخدمين يمرّ بنظام المصادقة وحده،
-- وتقليدُه من جدول `profiles` يترك حساباً بلا كلمة مرور ولا بريد مؤكَّد.
-- الموظف يسجّل كراكب أولاً، ثم يُرقّى.
create or replace function public.set_staff(p_email text, p_permissions text[])
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_id uuid; v_name text;
begin
  if not public.is_owner() then
    raise exception 'للمالك وحده' using errcode = 'insufficient_privilege';
  end if;

  select id, full_name into v_id, v_name from public.profiles
  where lower(email) = lower(btrim(p_email));

  if v_id is null then
    raise exception 'لا يوجد حساب بهذا البريد. اطلب منه التسجيل في التطبيق أولاً';
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.profiles
  set role = 'admin', staff_permissions = coalesce(p_permissions, '{}')
  where id = v_id;
  perform set_config('app.bypass_guards', 'off', true);

  perform public.log_action('staff.set', 'profile', v_id::text,
    format('منح %s صلاحيات موظف (%s)', coalesce(v_name, p_email),
           array_length(coalesce(p_permissions,'{}'), 1)));
end;
$fn$;


create or replace function public.remove_staff(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_email text; v_name text;
begin
  if not public.is_owner() then
    raise exception 'للمالك وحده' using errcode = 'insufficient_privilege';
  end if;

  select email, full_name into v_email, v_name
  from public.profiles where id = p_id;

  -- **المالك لا يُنزَع.** بلا هذا الحارس يستطيع المالك أن يسحب صلاحيته
  -- من نفسه بضغطة، فيُقفل النظام على لا أحد ولا سبيل للعودة.
  if lower(coalesce(v_email, '')) = 'ali.alkawary@gmail.com' then
    raise exception 'لا يمكن نزع صلاحيات المالك';
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.profiles
  set role = 'rider', staff_permissions = '{}'
  where id = p_id;
  perform set_config('app.bypass_guards', 'off', true);

  perform public.log_action('staff.remove', 'profile', p_id::text,
    format('نزع صلاحيات %s', coalesce(v_name, v_email)));
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) إلغاء رحلة من اللوحة
-- -----------------------------------------------------------------------------
-- `cancel_trip` تشترط أن يكون المنادي راكب الرحلة أو سائقها. المدير ليس
-- أياً منهما، فيحتاج باباً خاصاً — ولا رسوم ولا عقوبة على أحد: إلغاء
-- إداري لا خطأ من طرف.
create or replace function public.admin_cancel_trip(p_trip_id uuid, p_reason text)
returns public.trips
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_trip public.trips;
begin
  if not public.has_perm('trips.cancel') then
    raise exception 'لا تملك صلاحية إلغاء الرحلات'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'الرحلة غير موجودة';
  end if;
  if v_trip.status in ('completed', 'cancelled') then
    raise exception 'الرحلة منتهية بالفعل';
  end if;

  update public.trips
  set status = 'cancelled', cancelled_by = auth.uid(),
      cancellation_reason = coalesce(p_reason, 'إلغاء إداري'),
      cancellation_fee_iqd = 0
  where id = p_trip_id
  returning * into v_trip;

  update public.trip_offers set status = 'cancelled', responded_at = now()
  where trip_id = p_trip_id and status = 'pending';

  if v_trip.driver_id is not null then
    perform set_config('app.bypass_guards', 'on', true);
    update public.drivers
    set status = case when status = 'on_trip' then 'online' else status end
    where id = v_trip.driver_id;
    perform set_config('app.bypass_guards', 'off', true);
  end if;

  perform public.log_action('trip.cancel', 'trip', p_trip_id::text,
    format('ألغى الرحلة رقم %s — %s', v_trip.trip_number,
           coalesce(p_reason, 'بلا سبب')));

  return v_trip;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.set_staff        from public, anon;
revoke all on function public.remove_staff     from public, anon;
revoke all on function public.admin_cancel_trip from public, anon;
revoke all on function public.log_action       from public, anon;

grant execute on function public.is_owner()                        to authenticated;
grant execute on function public.has_perm(text)                    to authenticated;
grant execute on function public.known_permissions()               to authenticated;
grant execute on function public.staff_list()                      to authenticated;
grant execute on function public.set_staff(text, text[])           to authenticated;
grant execute on function public.remove_staff(uuid)                to authenticated;
grant execute on function public.admin_cancel_trip(uuid, text)     to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.known_permissions()) as "صلاحيات معرّفة",
  (select count(*) from public.profiles where role = 'admin') as "حسابات إدارية",
  (select count(*) from public.audit_log) as "سجلات تدقيق";
