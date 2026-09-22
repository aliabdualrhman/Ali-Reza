-- =============================================================================
-- 0100 — الموظف لا يصنع مالاً ولا يرفع صلاحياته
-- =============================================================================
-- طلب علي: «أريد أن أوظّف موظفين بلا صلاحياتٍ عالية، ولا يستطيعون التحايل
-- وبيع الرصيد من ورائي».
--
-- والتدقيق كشف أن ذلك **غير ممكن اليوم**. الصلاحيات تُفحص في الدوال،
-- لكنّ ثلاثة عشر جدولاً تحمل سياسةً واحدة: «كل شيء لأي مشرف»
-- (`for all using (is_admin())`). والموظف يملك مفتاح اللوحة العام (هو في
-- كود الموقع أصلاً) وجلسةً باسمه — فيكلّم القاعدة مباشرةً ولا يمرّ
-- بالدوال ولا بالسجلّ:
--
--   • يرفع رصيد أي سائق:  update drivers set wallet_balance_iqd = 1000000
--     وحارس الأعمدة `guard_driver_columns` **يستثني المشرف** صراحةً.
--   • يمنح نفسه كل الصلاحيات:  update profiles set staff_permissions = ...
--     وحارس `guard_profile_columns` يستثني المشرف كذلك.
--   • يُدرج كوبونات، ويعلّم طلبات السحب «مدفوعة»، ويغيّر الأسعار
--     والإعدادات ومبالغ الدعوة، ويعدّل أجرة رحلةٍ منتهية.
--   • ويغيّر «رمز الأفعال الخطرة» نفسه (`admin_set_code` تفحص الدور وحده).
--
-- **والإصلاح لا يمسّ الدوال التي تحرّك المال.** كلها `security definer`
-- يملكها `postgres` — فداخلها `current_user` هو `postgres`، ومن الطلب
-- المباشر هو `authenticated`. وبهذا الفرق وحده يُعرف من أين جاء التعديل.
--
-- **والمالك لا يتغيّر عليه شيء في اللوحة:** كل ما تكتبه اللوحة مباشرةً
-- تبقى له سياسته (بالصلاحية المناسبة)، و`has_perm` تمرّر المالك دائماً.
--
-- **ما لا يستطيع هذا الترحيل منعه:** موظفٌ أعطيته «شحن الرصيد» أو
-- «توليد الرموز» يستطيع إساءة استعمالهما — تلك صلاحيته. لكن كل حركةٍ
-- منهما تُسجَّل باسمه في سجلّ العمليات، والسجلّ لا يُحذف ولا يُعدَّل
-- (لا سياسة كتابةٍ عليه لأحد).

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) حارس المال والصلاحيات — يميّز الدالة من الطلب المباشر
-- -----------------------------------------------------------------------------
-- **`security invoker` عمداً** (الافتراضي). لو كان `definer` لصار
-- `current_user` داخله `postgres` دائماً، وضاع الفرق الذي نبني عليه.
create or replace function public.guard_staff_direct_writes()
returns trigger
language plpgsql
set search_path = public, extensions
as $fn$
declare
  v_direct boolean := current_user in ('authenticated', 'anon');
begin
  -- ---- السائقون: الرصيد ----
  if tg_table_name = 'drivers' then
    if v_direct then
      if tg_op = 'INSERT' then
        if coalesce(new.wallet_balance_iqd, 0) <> 0
           or coalesce(new.bonus_balance_iqd, 0) <> 0 then
          raise exception 'الرصيد يبدأ صفراً ويُعدَّل من دوال المحفظة وحدها'
            using errcode = 'insufficient_privilege';
        end if;
      elsif new.wallet_balance_iqd is distinct from old.wallet_balance_iqd
         or new.bonus_balance_iqd is distinct from old.bonus_balance_iqd then
        raise exception 'الرصيد يُعدَّل من دوال المحفظة وحدها — لا مباشرةً'
          using errcode = 'insufficient_privilege';
      end if;
    end if;
    return new;
  end if;

  -- ---- الملفات: الدور والصلاحيات والبريد ----
  if tg_table_name = 'profiles' then
    if v_direct then
      if tg_op = 'INSERT' then
        if new.role = 'admin'
           or coalesce(array_length(new.staff_permissions, 1), 0) > 0 then
          raise exception 'حسابات المشرفين تُنشأ من صفحة الموظفين وحدها'
            using errcode = 'insufficient_privilege';
        end if;
      else
        if new.role is distinct from old.role
           or new.staff_permissions is distinct from old.staff_permissions then
          raise exception 'الدور والصلاحيات تُغيَّر من صفحة الموظفين وحدها'
            using errcode = 'insufficient_privilege';
        end if;
        -- **البريد هو هويّة المالك** (`is_owner` تقارنه). تغييره مباشرةً
        -- يُخرج المالك من حسابه أو يُدخل غيره فيه.
        if new.email is distinct from old.email then
          raise exception 'البريد يتغيّر من إعدادات الحساب لا مباشرةً'
            using errcode = 'insufficient_privilege';
        end if;
      end if;
    end if;

    -- **ولا يُمسّ ملف مشرفٍ آخر إلا من المالك** — ولو عبر دالة. موظفٌ
    -- بصلاحية «تعديل البيانات» كان يستطيع تعديل ملف المالك نفسه.
    if tg_op = 'UPDATE'
       and old.role = 'admin'
       and auth.uid() is not null
       and old.id <> auth.uid()
       and not public.is_owner()
       and not public.guards_bypassed() then
      raise exception 'ملفات المشرفين يعدّلها المالك وحده'
        using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;

  return new;
end;
$fn$;

drop trigger if exists "0_guard_staff_direct" on public.drivers;
create trigger "0_guard_staff_direct"
  before insert or update on public.drivers
  for each row execute function public.guard_staff_direct_writes();

drop trigger if exists "0_guard_staff_direct" on public.profiles;
create trigger "0_guard_staff_direct"
  before insert or update on public.profiles
  for each row execute function public.guard_staff_direct_writes();


-- -----------------------------------------------------------------------------
-- ٢) السياسات: القراءة للمشرف، والكتابة بالصلاحية أو لا كتابة
-- -----------------------------------------------------------------------------
-- القاعدة: **ما لا تكتبه اللوحة مباشرةً لا سياسة كتابةٍ له.** الدوال
-- (`security definer` بمالكها `postgres`) تتجاوز RLS أصلاً، فلا تحتاجها.
-- وما تكتبه اللوحة مباشرةً تبقى له سياسة بالصلاحية التي تخصّه.

-- ---- جداول تُقرأ فقط: كل كتابتها بدوال ----
drop policy if exists "drivers: صلاحية كاملة للمشرف" on public.drivers;
drop policy if exists drivers_admin_read on public.drivers;
create policy drivers_admin_read on public.drivers
  for select to authenticated using (public.is_admin());

drop policy if exists "profiles: صلاحية كاملة للمشرف" on public.profiles;
drop policy if exists profiles_admin_read on public.profiles;
create policy profiles_admin_read on public.profiles
  for select to authenticated using (public.is_admin());

drop policy if exists "trips: صلاحية كاملة للمشرف" on public.trips;
drop policy if exists trips_admin_read on public.trips;
create policy trips_admin_read on public.trips
  for select to authenticated using (public.is_admin());

drop policy if exists "payouts: صلاحية كاملة للمشرف" on public.payout_requests;
drop policy if exists payouts_admin_read on public.payout_requests;
create policy payouts_admin_read on public.payout_requests
  for select to authenticated using (public.is_admin());

-- **كشف الحساب لا يُكتب يدوياً.** حركةٌ مزيّفة فيه لا تغيّر الرصيد، لكنها
-- تُخفي حركةً حقيقية أو تبرّر رصيداً مسروقاً. والقراءة باقية في سياسة
-- «السائق يقرأ كشف حسابه» (وفيها المشرف).
drop policy if exists "wallet: المشرف يسجّل تسويات" on public.wallet_transactions;

drop policy if exists "pricing: تعديل للمشرف" on public.pricing_zones;
drop policy if exists pricing_admin_read on public.pricing_zones;
create policy pricing_admin_read on public.pricing_zones
  for select to authenticated using (public.is_admin());

drop policy if exists "surge: تعديل للمشرف" on public.surge_state;
drop policy if exists surge_admin_read on public.surge_state;
create policy surge_admin_read on public.surge_state
  for select to authenticated using (public.is_admin());

drop policy if exists "pcr: للمشرف كاملة" on public.profile_change_requests;
drop policy if exists pcr_admin_read on public.profile_change_requests;
create policy pcr_admin_read on public.profile_change_requests
  for select to authenticated using (public.is_admin());

drop policy if exists rating_tags_admin on public.rating_tags;
drop policy if exists rating_tags_admin_read on public.rating_tags;
create policy rating_tags_admin_read on public.rating_tags
  for select to authenticated using (public.is_admin());

-- ---- جداول تكتبها اللوحة مباشرةً: بصلاحيتها ----
drop policy if exists "coupons: للمشرف وحده" on public.coupons;
drop policy if exists coupons_admin_read on public.coupons;
drop policy if exists coupons_manage on public.coupons;
create policy coupons_admin_read on public.coupons
  for select to authenticated using (public.is_admin());
create policy coupons_manage on public.coupons
  for all to authenticated
  using (public.has_perm('coupons.manage'))
  with check (public.has_perm('coupons.manage'));

drop policy if exists "settings: يكتب المشرف" on public.public_settings;
drop policy if exists settings_manage on public.public_settings;
create policy settings_manage on public.public_settings
  for update to authenticated
  using (public.has_perm('settings.manage'))
  with check (public.has_perm('settings.manage'));

drop policy if exists templates_admin on public.notification_templates;
drop policy if exists templates_admin_read on public.notification_templates;
drop policy if exists templates_manage on public.notification_templates;
create policy templates_admin_read on public.notification_templates
  for select to authenticated using (public.is_admin());
create policy templates_manage on public.notification_templates
  for all to authenticated
  using (public.has_perm('notifications.send'))
  with check (public.has_perm('notifications.send'));

drop policy if exists schedules_admin on public.notification_schedules;
drop policy if exists schedules_admin_read on public.notification_schedules;
drop policy if exists schedules_manage on public.notification_schedules;
create policy schedules_admin_read on public.notification_schedules
  for select to authenticated using (public.is_admin());
create policy schedules_manage on public.notification_schedules
  for all to authenticated
  using (public.has_perm('notifications.send'))
  with check (public.has_perm('notifications.send'));

-- الوثائق: المراجعة تعديلٌ مباشر من اللوحة.
drop policy if exists "documents: المشرف يراجع" on public.user_documents;
drop policy if exists documents_admin_read on public.user_documents;
drop policy if exists documents_review on public.user_documents;
create policy documents_admin_read on public.user_documents
  for select to authenticated using (public.is_admin());
create policy documents_review on public.user_documents
  for update to authenticated
  using (public.has_perm('drivers.review') or public.has_perm('profiles.edit'))
  with check (public.has_perm('drivers.review') or public.has_perm('profiles.edit'));

-- وحذف سجل الوثيقة: لصاحبها عند إعادة الرفع، وللمراجع بصلاحيته.
drop policy if exists "documents: حذف سجل عند إعادة الرفع" on public.user_documents;
drop policy if exists documents_delete on public.user_documents;
create policy documents_delete on public.user_documents
  for delete to authenticated
  using (user_id = auth.uid()
         or public.has_perm('drivers.review')
         or public.has_perm('profiles.edit'));


-- -----------------------------------------------------------------------------
-- ٣) دوال كانت تفحص «هل هو مشرف؟» وحدها
-- -----------------------------------------------------------------------------
-- منسوخةٌ من التعريف الحيّ (pg_get_functiondef). التغيير سطر الفحص وحده،
-- وسطر السجلّ في دالتَي السحب (لم يكن فيهما سجلّ).

-- ---- السحب: بصلاحية «معالجة طلبات السحب» ----
create or replace function public.mark_payout_paid(p_id uuid, p_note text default null)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.has_perm('payouts.process') then
    raise exception 'لا تملك صلاحية معالجة طلبات السحب'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests where id = p_id for update;
  if not found then
    raise exception 'الطلب غير موجود';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'هذا الطلب مُعالج بالفعل';
  end if;

  -- **لا خصم هنا.** المبلغ خرج من رصيد السائق لحظة طلبه.
  update public.payout_requests
  set status = 'paid', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  perform public.log_action(
    'payout.paid', 'payout_request', p_id::text,
    format('علّم طلب سحب بقيمة %s دينار مدفوعاً', v_row.amount_iqd::bigint)
  );

  return v_row;
end;
$fn$;

create or replace function public.reject_payout_request(p_id uuid, p_note text)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.has_perm('payouts.process') then
    raise exception 'لا تملك صلاحية معالجة طلبات السحب'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests
  where id = p_id and status = 'pending'
  for update;

  if not found then
    raise exception 'الطلب غير موجود أو مُعالج بالفعل';
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'adjustment',
    p_amount_iqd  => v_row.amount_iqd,
    p_description => coalesce(nullif(p_note, ''), 'رُفض طلب السحب')
  );

  update public.payout_requests
  set status = 'rejected', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  perform public.log_action(
    'payout.rejected', 'payout_request', p_id::text,
    format('رفض طلب سحب بقيمة %s دينار', v_row.amount_iqd::bigint)
  );

  return v_row;
end;
$fn$;

-- ---- رمز الأفعال الخطرة وتصفير اللوحة: للمالك وحده ----
-- **رمزٌ يغيّره من يُفترض أنه محجوبٌ به لا يحجب شيئاً.**
create or replace function public.admin_set_code(p_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_owner() then
    raise exception 'للمالك وحده' using errcode = 'insufficient_privilege';
  end if;
  if length(coalesce(p_code, '')) < 8 then
    raise exception 'الرمز ثمانية أحرف على الأقل';
  end if;

  insert into public.admin_secrets (key, hash, updated_by)
  values ('action_code',
          extensions.crypt(p_code, extensions.gen_salt('bf')),
          auth.uid())
  on conflict (key) do update
    set hash = excluded.hash,
        updated_at = now(),
        updated_by = excluded.updated_by;

  perform public.log_action('admin.code_changed', 'admin_secrets',
    'action_code', 'غُيّر رمز الأفعال الخطرة');
end;
$fn$;

create or replace function public.admin_reset_dashboard(p_code text)
returns timestamptz
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_owner() then
    raise exception 'للمالك وحده' using errcode = 'insufficient_privilege';
  end if;
  if not public.check_admin_code(p_code) then
    raise exception 'رمز المدير غير صحيح';
  end if;

  update public.public_settings
  set value = now()::text where key = 'dashboard_epoch';

  perform public.log_action('dashboard.reset', 'public_settings',
    'dashboard_epoch', 'صُفّرت لوحة الأرقام');

  return now();
end;
$fn$;

create or replace function public.admin_undo_dashboard_reset(p_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_owner() then
    raise exception 'للمالك وحده' using errcode = 'insufficient_privilege';
  end if;
  if not public.check_admin_code(p_code) then
    raise exception 'رمز المدير غير صحيح';
  end if;

  update public.public_settings set value = '' where key = 'dashboard_epoch';

  perform public.log_action('dashboard.reset_undo', 'public_settings',
    'dashboard_epoch', 'أُلغي تصفير اللوحة');
end;
$fn$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_policies
   where schemaname = 'public' and cmd = 'ALL'
     and (qual = 'is_admin()' or with_check = 'is_admin()'))      as "سياسات «كل شيء للمشرف» الباقية (٠)",
  (select count(*) from pg_trigger
   where tgname = '0_guard_staff_direct')                          as "حارس المال والصلاحيات (٢)",
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('mark_payout_paid', 'reject_payout_request')
     and prosrc like '%payouts.process%')                          as "السحب بصلاحيته (٢)",
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('admin_set_code', 'admin_reset_dashboard',
                     'admin_undo_dashboard_reset')
     and prosrc like '%is_owner()%')                               as "للمالك وحده (٣)";
