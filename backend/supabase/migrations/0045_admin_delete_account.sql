-- =============================================================================
-- 0045 — المدير يحذف حساب راكب أو سائق
-- =============================================================================
-- **الحاجة.** حساباتٌ تجريبية أنشأها المدير بنفسه (0044) تتراكم بعد
-- انتهاء الاختبار فتزاحم الحقيقيين في القوائم. وحسابٌ مسيء يجب أن
-- يُزال لا أن يُوقف وحده.
--
-- **والحذف نوعان لا نوع واحد** — وهذا جوهر الملف:
--
--   • **حسابٌ لم يركب قطّ** (تجريبي أو مهجور) → يُمحى كلياً من
--     `auth.users`، ويأخذ معه ملفه ووثائقه. لا أثر يبقى ولا سبب لبقائه.
--
--   • **حسابٌ له رحلات** → يُجهَّل ولا يُمحى: الاسم والهاتف والبريد
--     والصور تُزال، ويبقى سجلّ الرحلات ومبالغها. لأن `trips.rider_id`
--     مقيَّد بـ`on delete restrict` — والقيد ليس عائقاً بل قرار: رحلةٌ
--     بلا راكب رقمٌ في دفتر لا يُراجَع، ومحوُ سجلّ مالي يُغلق باب
--     المحاسبة على من أراد الهرب.
--
-- **ولماذا لا نترك المدير يختار؟** لأن الخيار الخاطئ هنا لا رجعة فيه.
-- الدالة تفحص وتقرّر، وتخبر المدير أيّهما فعلت.
--
-- **ونعيد استعمال منطق 0036 نفسه** في التجهيل: مسار واحد للحذف لا
-- مساران يتباعدان، فما يحمي المستخدم حين يحذف حسابه بنفسه يحمي القاعدة
-- حين يحذفه المدير.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) صلاحية الحذف
-- -----------------------------------------------------------------------------
-- **منفصلة عن `profiles.edit`** — تصحيح اسم شيء ومحو حساب شيء آخر.
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
    ('accounts.create', 'إنشاء حسابات جديدة من اللوحة'),
    ('accounts.delete', 'حذف حسابات المستخدمين'),
    ('trips.view',      'عرض الرحلات'),
    ('trips.cancel',    'إلغاء رحلة جارية'),
    ('topups.generate', 'توليد رموز التعبئة'),
    ('topups.view',     'عرض رموز التعبئة'),
    ('payouts.process', 'معالجة طلبات السحب'),
    ('coupons.manage',  'إنشاء الكوبونات وإيقافها'),
    ('settings.manage', 'تعديل الإعدادات العامة')
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) الحذف
-- -----------------------------------------------------------------------------
-- تعيد `'purged'` إن مُحي الحساب كلياً، و`'anonymized'` إن جُهّل —
-- فتعرض اللوحة للمدير ما حدث فعلاً لا ما ظنّه.
create or replace function public.admin_delete_account(
  p_id     uuid,
  p_reason text default null
)
returns text
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
begin
  if not public.has_perm('accounts.delete') then
    raise exception 'لا تملك صلاحية حذف الحسابات'
      using errcode = 'insufficient_privilege';
  end if;

  select role, full_name into v_role, v_name
  from public.profiles where id = p_id;

  if v_name is null then raise exception 'المستخدم غير موجود'; end if;

  -- **لا يُحذف مشرف من هنا.** ترقية المشرفين وعزلهم بابهما `staff`،
  -- وحذفٌ عابر قد يُقفل اللوحة على لا أحد.
  if v_role = 'admin' then
    raise exception 'حسابات المشرفين تُدار من صفحة المستخدمين';
  end if;

  -- رحلة جارية تعني راكباً في الشارع أو سائقاً على الطريق. الحذف وسطها
  -- يترك الطرف الآخر بلا أحد — نفس حارس 0036.
  select count(*) into v_open
  from public.trips
  where (rider_id = p_id or driver_id = p_id)
    and status in ('searching','accepted','driver_arrived','in_progress');

  if v_open > 0 then
    raise exception 'لهذا الحساب رحلة جارية. أنهِها أو ألغِها أولاً.';
  end if;

  select count(*) into v_trips
  from public.trips where rider_id = p_id or driver_id = p_id;

  perform set_config('app.bypass_guards', 'on', true);

  -- الوثائق تُحذف في الحالتين. **صورة بطاقة وطنية باقية في التخزين بعد
  -- حذف الحساب هي أسوأ ما يمكن أن يبقى.**
  delete from storage.objects
  where bucket_id = 'documents' and name like p_id::text || '/%';

  delete from public.user_documents        where user_id = p_id;
  delete from public.profile_change_requests where user_id = p_id;

  -- ---------------------------------------------------------------------
  -- الحالة الأولى: بلا رحلات ← محوٌ كامل
  -- ---------------------------------------------------------------------
  if v_trips = 0 then
    -- `profiles` مقيَّد بـ`on delete cascade` على `auth.users`، فحذف
    -- المستخدم يأخذ ملفه وصفّ سائقه معاً.
    delete from auth.users where id = p_id;

    perform set_config('app.bypass_guards', 'off', true);
    perform public.log_action(
      'account.purge', 'profiles', p_id::text,
      v_name || ' — محو كامل' || coalesce(' — ' || p_reason, '')
    );
    return 'purged';
  end if;

  -- ---------------------------------------------------------------------
  -- الحالة الثانية: له رحلات ← تجهيل
  -- ---------------------------------------------------------------------
  -- **الدين يمنع الحذف كما يمنعه في 0036.** حذفٌ يمحو ديناً يجعل الحذف
  -- باب هروب — ولا فرق بين أن يطلبه صاحبه أو أن يفعله المدير سهواً.
  if v_role = 'driver'
     and exists (select 1 from public.drivers
                 where id = p_id and wallet_balance_iqd < 0) then
    perform set_config('app.bypass_guards', 'off', true);
    raise exception 'على هذا السائق رصيد مستحق. سوِّه قبل الحذف.';
  end if;

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

  -- تحرير البريد في نظام الدخول ومنع الدخول بالحساب القديم
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

  return 'anonymized';
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.admin_delete_account(uuid, text) from public, anon;
grant execute on function public.admin_delete_account(uuid, text) to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) للمالك وحده
-- -----------------------------------------------------------------------------
update public.profiles
set staff_permissions = array(
      select distinct unnest(staff_permissions || array['accounts.delete'])
    )
where role = 'admin'
  and lower(email) = 'ali.alkawary@gmail.com'
  and not ('accounts.delete' = any(staff_permissions));


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  count(*) filter (where deleted_at is null)     as "حسابات حيّة",
  count(*) filter (where deleted_at is not null) as "مجهَّلة"
from public.profiles where role in ('rider','driver');
