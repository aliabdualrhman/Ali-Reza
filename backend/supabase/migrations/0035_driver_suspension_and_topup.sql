-- =============================================================================
-- 0035 — إيقاف السائق وتعبئة رصيده من اللوحة
-- =============================================================================
-- ثلاثة أفعال إدارية كانت تنقص المدير:
--
--   ١) توقيف السائق مؤقتاً عن استلام الطلبات، دون المساس باعتماده.
--   ٢) إلغاء اعتماده كلّياً فيعود إلى دورة المراجعة.
--   ٣) تعبئة رصيده مباشرةً بمبلغ يختاره، بلا رمز تعبئة.
--
-- كلها كانت متعذّرة من التطبيق: الأولى بلا آلية، والثانية يمحوها مُشغّل
-- الوثائق، والثالثة محجوبة لأن `post_wallet_transaction` مسحوبة من
-- `authenticated` — وهذا صواب: من يستطيع نداءها مباشرةً يستطيع منح نفسه
-- مالاً. الحلّ ليس فتحها بل دالة إدارية ضيّقة تنادِيها نيابةً.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) صلاحيتان جديدتان
-- -----------------------------------------------------------------------------
-- **لماذا صلاحية مستقلة للتعبئة؟** لأنها الفعل الوحيد في اللوحة الذي
-- يخلق مالاً من العدم. موظف يراجع الوثائق لا يلزمه أن يملك مفتاح الخزنة.
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
    ('trips.view',      'عرض الرحلات'),
    ('trips.cancel',    'إلغاء رحلة جارية'),
    ('topups.generate', 'توليد رموز التعبئة'),
    ('topups.view',     'عرض رموز التعبئة'),
    ('payouts.process', 'معالجة طلبات السحب'),
    ('coupons.manage',  'إنشاء الكوبونات وإيقافها'),
    ('settings.manage', 'تعديل الإعدادات العامة')
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الإيقاف المؤقت — عن استلام الطلبات وحدها
-- -----------------------------------------------------------------------------
-- **لماذا `profiles.is_blocked` لا `verification_status`؟** لأن حالة
-- الاعتماد يحسبها مُشغّل الوثائق من جديد عند أي تعديل على وثيقة. سائق
-- موقوف تُحدَّث إحدى وثائقه يعود معتمَداً في صمت — والمدير يظنّه موقوفاً.
--
-- و`is_blocked` مقروءة أصلاً في `find_nearby_drivers`، فالتوقيف يسري
-- على العروض فوراً بلا تعديل في محرّك المطابقة.
--
-- اعتمادُه يبقى كما هو: هذا إيقافٌ لا نقضٌ للمراجعة، ورفعه بضغطة.
create or replace function public.admin_set_driver_blocked(
  p_driver_id uuid,
  p_blocked   boolean,
  p_reason    text default null
)
returns public.drivers
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row  public.drivers;
  v_name text;
begin
  if not public.has_perm('drivers.suspend') then
    raise exception 'لا تملك صلاحية إيقاف السائقين'
      using errcode = 'insufficient_privilege';
  end if;

  select full_name into v_name from public.profiles where id = p_driver_id;
  if v_name is null then
    raise exception 'السائق غير موجود';
  end if;

  update public.profiles
  set is_blocked = p_blocked
  where id = p_driver_id;

  -- الموقوف يُفصل عن الشبكة فوراً: تركه متصلاً يعني أنه يرى نفسه عاملاً
  -- وينتظر طلباً لن يأتي.
  if p_blocked then
    update public.drivers
    set status = 'offline'
    where id = p_driver_id and status <> 'on_trip';
  end if;

  select * into v_row from public.drivers where id = p_driver_id;

  perform public.log_action(
    case when p_blocked then 'driver.block' else 'driver.unblock' end,
    'driver', p_driver_id::text,
    case when p_blocked
      then format('أوقف السائق %s عن استلام الطلبات%s', v_name,
             coalesce(' — ' || nullif(trim(p_reason), ''), ''))
      else format('أعاد تفعيل السائق %s', v_name)
    end
  );

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) إلغاء الاعتماد — قرار أثقل
-- -----------------------------------------------------------------------------
-- السائق يعود إلى حالة `suspended`: لا يتصل، ولا يستلم، ويرى في تطبيقه
-- أن حسابه موقوف. رفعُه يعيده `approved` مباشرةً بلا إعادة رفع وثائق —
-- فالوثائق لم تتغيّر، القرار وحده هو الذي تغيّر.
create or replace function public.admin_set_driver_approval(
  p_driver_id uuid,
  p_approved  boolean,
  p_reason    text default null
)
returns public.drivers
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row  public.drivers;
  v_name text;
begin
  if not public.has_perm('drivers.suspend') then
    raise exception 'لا تملك صلاحية إلغاء اعتماد السائقين'
      using errcode = 'insufficient_privilege';
  end if;

  select full_name into v_name from public.profiles where id = p_driver_id;
  if v_name is null then
    raise exception 'السائق غير موجود';
  end if;

  update public.drivers
  set verification_status =
        case when p_approved then 'approved' else 'suspended' end
        ::public.verification_status,
      rejection_reason = case when p_approved then null else p_reason end,
      status = case when p_approved then status else 'offline' end
  where id = p_driver_id
  returning * into v_row;

  perform public.log_action(
    case when p_approved then 'driver.reinstate' else 'driver.suspend' end,
    'driver', p_driver_id::text,
    case when p_approved
      then format('أعاد اعتماد السائق %s', v_name)
      else format('ألغى اعتماد السائق %s%s', v_name,
             coalesce(' — ' || nullif(trim(p_reason), ''), ''))
    end
  );

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) الإيقاف يصمد أمام مُشغّل الوثائق
-- -----------------------------------------------------------------------------
-- **العطب المُصلَح هنا:** المُشغّل كان يحسب حالة الاعتماد من الوثائق عند
-- كل تعديل، فيمحو قرار الإيقاف. سائق أوقفناه ثم رفع صورة دراجة جديدة
-- كان يعود معتمَداً وحده. الآن `suspended` تبقى حتى يرفعها إنسان.
create or replace function public.recompute_verification()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role         public.user_role;
  required_docs  public.document_type[] := array[
    'live_selfie', 'national_id_front', 'national_id_back', 'vehicle_photo'
  ]::public.document_type[];
  approved_count integer;
  rejected_count integer;
begin
  select role into v_role from public.profiles where id = new.user_id;

  perform set_config('app.bypass_guards', 'on', true);

  if new.doc_type = 'live_selfie' then
    update public.profiles
    set identity_verified = (new.status = 'approved')
    where id = new.user_id;
  end if;

  if v_role = 'driver' then
    select
      count(distinct doc_type) filter (
        where status = 'approved' and doc_type = any(required_docs)),
      count(distinct doc_type) filter (
        where status = 'rejected' and doc_type = any(required_docs))
    into approved_count, rejected_count
    from public.user_documents
    where user_id = new.user_id;

    update public.drivers d
    set verification_status = case
          -- الإيقاف الإداري أعلى من حساب الوثائق: قرار إنسان لا يمحوه
          -- رفعُ صورة.
          when d.verification_status = 'suspended'             then 'suspended'
          when rejected_count > 0                              then 'rejected'
          when approved_count = array_length(required_docs, 1) then 'approved'
          else 'pending'
        end::public.verification_status,
        status = case
          when d.verification_status = 'suspended' then 'offline'
          when rejected_count > 0                  then 'offline'
          else d.status
        end
    where d.id = new.user_id;
  end if;

  perform set_config('app.bypass_guards', 'off', true);

  return new;
end;
$$;


-- -----------------------------------------------------------------------------
-- ٥) تعبئة رصيد مباشرة
-- -----------------------------------------------------------------------------
-- **لماذا دالة لا كتابة مباشرة؟** لأن الرصيد لا يُكتب، بل يُشتقّ من حركات
-- المحفظة. كتابة `wallet_balance_iqd` يدوياً تُنتج رصيداً لا يفسّره سجلّ،
-- فيختلف المدير والسائق على رقم لا أصل له. الحركة تُسجَّل، والرصيد يتبعها.
--
-- والمبلغ موجب دائماً: هذه تعبئة لا تسوية. الخصم له مساره الخاص.
create or replace function public.admin_topup_driver(
  p_driver_id uuid,
  p_amount    numeric,
  p_note      text default null
)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_name    text;
  v_balance numeric(12,2);
begin
  if not public.has_perm('drivers.topup') then
    raise exception 'لا تملك صلاحية تعبئة الأرصدة'
      using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'المبلغ يجب أن يكون أكبر من صفر';
  end if;

  -- سقف للدفعة الواحدة. ليس حدّاً تجارياً بل حارس أصابع: صفر زائد
  -- بالخطأ يعني مليوناً في محفظة سائق، وسحبُه بعد إنفاقه متعذّر.
  if p_amount > 1000000 then
    raise exception 'الحد الأقصى للتعبئة الواحدة مليون دينار';
  end if;

  select p.full_name into v_name
  from public.profiles p
  join public.drivers d on d.id = p.id
  where p.id = p_driver_id;

  if v_name is null then
    raise exception 'السائق غير موجود';
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => p_driver_id,
    p_txn_type    => 'topup',
    p_amount_iqd  => p_amount,
    p_description => coalesce(nullif(trim(p_note), ''), 'تعبئة من لوحة التحكم'),
    p_created_by  => auth.uid()
  );

  select wallet_balance_iqd into v_balance
  from public.drivers where id = p_driver_id;

  perform public.log_action(
    'driver.topup', 'driver', p_driver_id::text,
    format('عبّأ رصيد %s بمبلغ %s دينار — الرصيد بعدها %s',
           v_name, p_amount::bigint, v_balance::bigint)
  );

  return v_balance;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.admin_set_driver_blocked(uuid, boolean, text)
  from public, anon;
revoke all on function public.admin_set_driver_approval(uuid, boolean, text)
  from public, anon;
revoke all on function public.admin_topup_driver(uuid, numeric, text)
  from public, anon;

grant execute on function public.admin_set_driver_blocked(uuid, boolean, text)
  to authenticated;
grant execute on function public.admin_set_driver_approval(uuid, boolean, text)
  to authenticated;
grant execute on function public.admin_topup_driver(uuid, numeric, text)
  to authenticated;

-- الحماية في الدوال نفسها (`has_perm`) لا في المنح: `authenticated` تشمل
-- كل سائق وراكب، وأول سطر في كل دالة يردّهم.


-- -----------------------------------------------------------------------------
-- فحص سريع بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.known_permissions())        as "صلاحيات معرّفة",
  (select count(*) from pg_proc
     where proname in ('admin_set_driver_blocked',
                       'admin_set_driver_approval',
                       'admin_topup_driver'))              as "دوال جديدة";
