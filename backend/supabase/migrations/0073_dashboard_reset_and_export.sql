-- =============================================================================
-- 0073 — تصفير اللوحة وتصديرها، برمز المدير
-- =============================================================================
-- **لا تُمحى بيانات — تُنسى.** المطلوب أن تبدأ اللوحة من صفرٍ يوم
-- الإطلاق، لا أن يُمحى ما جرى. فنضع «نقطة صفر»، وتعدّ اللوحة ما بعدها
-- وحده.
--
-- والفرق ليس تفصيلاً:
--
--   • **يُسترجَع بضغطة.** من صفّر بالخطأ يُعيد التاريخ فتعود الأرقام.
--     والحذف لا يُتراجَع عنه أبداً.
--   • **الرحلات تبقى لأصحابها.** سائقٌ يسأل عن رحلةٍ قبل الإطلاق يجد
--     جوابها، ومحفظته تبقى صحيحة — والحذف كان يجعل رصيده كذبةً بلا سند.
--   • **والمحاسبة تبقى ممكنة.** ما جرى جرى، وسجلّه دليلٌ عند الخلاف.
--
-- ------------------------------------------------------------------
-- ورمز المدير مُجزَّأ في القاعدة لا مكتوبٌ في اللوحة
-- ------------------------------------------------------------------
-- لوحة المدير تطبيق ويب: ملفّها يُنزَّل في متصفّح أيّ زائر، وأيّ نصٍّ
-- فيه يُقرأ بالبحث عنه. فرمزٌ مكتوبٌ هناك قفلٌ مفتاحه معلَّق عليه.
--
-- فيُخزَّن مُجزَّأً (bcrypt)، ويُقارَن في الخادم، ولا يخرج من القاعدة.
-- ويُغيَّر بـ`admin_set_code` بلا بناءٍ ولا نشر.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الرمز
-- -----------------------------------------------------------------------------
create table if not exists public.admin_secrets (
  key        text primary key,
  hash       text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

alter table public.admin_secrets enable row level security;
-- بلا سياسة: لا أحد يقرؤه من الواجهة. الدوال وحدها، وهي `security definer`.

comment on table public.admin_secrets is
  'رموز الأفعال الخطرة، مُجزَّأة. لا تُقرأ من الواجهة إطلاقاً.';


create or replace function public.admin_set_code(p_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;
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

revoke all on function public.admin_set_code(text) from public, anon;
grant execute on function public.admin_set_code(text) to authenticated;


-- **الفحص داخليّ لا يُنادى من الواجهة.** لو مُنح للتطبيق لصار مِجرفةً
-- لتخمين الرمز: نداءٌ يردّ نعم/لا بلا حدّ.
create or replace function public.check_admin_code(p_code text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_hash text;
begin
  select hash into v_hash
  from public.admin_secrets where key = 'action_code';

  -- **لا رمز = لا فعل.** الافتراض المفتوح أخطر من الافتراض المغلق:
  -- قاعدةٌ رُحّلت ولم يُضبط رمزها تصير مفتوحةً للجميع.
  if v_hash is null then
    raise exception 'لم يُضبط رمز المدير بعد';
  end if;

  return extensions.crypt(coalesce(p_code, ''), v_hash) = v_hash;
end;
$fn$;

revoke all on function public.check_admin_code(text)
  from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٢) نقطة الصفر
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('dashboard_epoch', '', 'نقطة صفر اللوحة — تُحسب الأرقام بعدها')
on conflict (key) do nothing;


create or replace function public.dashboard_epoch()
returns timestamptz
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select nullif(btrim(value), '')::timestamptz
  from public.public_settings where key = 'dashboard_epoch';
$fn$;


create or replace function public.admin_reset_dashboard(p_code text)
returns timestamptz
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;
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

revoke all on function public.admin_reset_dashboard(text) from public, anon;
grant execute on function public.admin_reset_dashboard(text) to authenticated;


-- **والتراجع متاح.** من صفّر بالخطأ يستعيد كل شيء — ولولا ذلك لكان
-- الزرّ حذفاً باسمٍ ألطف.
create or replace function public.admin_undo_dashboard_reset(p_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;
  if not public.check_admin_code(p_code) then
    raise exception 'رمز المدير غير صحيح';
  end if;

  update public.public_settings set value = '' where key = 'dashboard_epoch';

  perform public.log_action('dashboard.reset_undo', 'public_settings',
    'dashboard_epoch', 'أُلغي تصفير اللوحة');
end;
$fn$;

revoke all on function public.admin_undo_dashboard_reset(text)
  from public, anon;
grant execute on function public.admin_undo_dashboard_reset(text)
  to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) اللوحة تعدّ ما بعد النقطة
-- -----------------------------------------------------------------------------
create or replace function public.admin_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_epoch  timestamptz := coalesce(public.dashboard_epoch(), '-infinity');
  v_day    timestamptz := greatest(date_trunc('day', now()), v_epoch);
  v_month  timestamptz := greatest(date_trunc('month', now()), v_epoch);
  v_codes  jsonb;
  v_trips  jsonb;
  v_people jsonb;
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح';
  end if;

  -- **الرمز يُنسب إلى تعبئته لا إلى توليده.** رمزٌ وُلّد قبل الإطلاق
  -- وعُبّئ بعده مالٌ خرج بعد الإطلاق، وعدّه في القديم يُخفيه.
  select jsonb_build_object(
    'generated_iqd',
      coalesce(sum(amount_iqd) filter (where created_at >= v_epoch), 0),
    'redeemed_iqd',
      coalesce(sum(amount_iqd)
        filter (where redeemed_at is not null and redeemed_at >= v_epoch), 0),
    'outstanding_iqd',
      coalesce(sum(amount_iqd)
        filter (where redeemed_by is null and not is_void
                  and created_at >= v_epoch), 0),
    'redeemed_today_iqd',
      coalesce(sum(amount_iqd) filter (where redeemed_at >= v_day), 0),
    'redeemed_month_iqd',
      coalesce(sum(amount_iqd) filter (where redeemed_at >= v_month), 0),
    'count_total', count(*) filter (where created_at >= v_epoch),
    'count_unused', count(*) filter (
      where redeemed_by is null and not is_void and created_at >= v_epoch)
  )
  into v_codes
  from public.topup_codes;

  select jsonb_build_object(
    'total',            count(*),
    'month',            count(*) filter (where requested_at >= v_month),
    'today',            count(*) filter (where requested_at >= v_day),

    'completed_total',  count(*) filter (where status = 'completed'),
    'completed_month',  count(*) filter (
                          where status = 'completed'
                            and requested_at >= v_month),
    'completed_today',  count(*) filter (
                          where status = 'completed'
                            and requested_at >= v_day),

    'cancelled_total',  count(*) filter (where status = 'cancelled'),
    'cancelled_month',  count(*) filter (
                          where status = 'cancelled'
                            and requested_at >= v_month),

    'fare_total',  coalesce(sum(fare_final_iqd)
                     filter (where status = 'completed'), 0),
    'fare_month',  coalesce(sum(fare_final_iqd)
                     filter (where status = 'completed'
                               and requested_at >= v_month), 0),
    'fare_today',  coalesce(sum(fare_final_iqd)
                     filter (where status = 'completed'
                               and requested_at >= v_day), 0),

    'commission_total', coalesce(sum(commission_iqd)
                          filter (where status = 'completed'), 0),
    'commission_month', coalesce(sum(commission_iqd)
                          filter (where status = 'completed'
                                    and requested_at >= v_month), 0),
    'commission_today', coalesce(sum(commission_iqd)
                          filter (where status = 'completed'
                                    and requested_at >= v_day), 0)
  )
  into v_trips
  from public.trips
  where requested_at >= v_epoch;

  -- **الناس لا يُصفَّرون.** سائقٌ معتمَدٌ قبل الإطلاق سائقٌ اليوم،
  -- وإخفاؤه من العدّاد يجعل اللوحة تكذب عن حجم الأسطول. يُصفَّر
  -- الجديد منهم وحده.
  select jsonb_build_object(
    'drivers',          count(*) filter (where role = 'driver'),
    'drivers_approved', count(*) filter (
                          where role = 'driver' and identity_verified),
    'riders',           count(*) filter (where role = 'rider'),
    'new_month',        count(*) filter (where created_at >= v_month),
    'new_today',        count(*) filter (where created_at >= v_day)
  )
  into v_people
  from public.profiles
  where deleted_at is null;

  return jsonb_build_object(
    'codes',  v_codes,
    'trips',  v_trips,
    'people', v_people,
    'epoch',  public.dashboard_epoch(),
    'at',     now()
  );
end;
$fn$;

revoke all on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) التصدير
-- -----------------------------------------------------------------------------
-- **صفوفٌ لا ملخّص.** من ينزّل الأرقام يريد أن يحسبها بنفسه: يفرزها
-- بالمنطقة أو باليوم أو بالسائق. والملخّص يعطيه ما رآه في الشاشة.
--
-- والحدّ خمسة آلاف صفّ: أكبر من ذلك يخنق المتصفّح، ومن يحتاج أكثر
-- يُصدَّر له من القاعدة مباشرةً.
create or replace function public.admin_export_trips(p_code text)
returns table (
  "رقم الرحلة"    text,
  "التاريخ"       text,
  "الحالة"        text,
  "الراكب"        text,
  "هاتف الراكب"   text,
  "السائق"        text,
  "هاتف السائق"   text,
  "من"            text,
  "إلى"           text,
  "المسافة (كم)"  numeric,
  "الأجرة"        numeric,
  "العمولة"       numeric,
  "حصة السائق"    numeric
)
language plpgsql
-- **بلا `stable`.** تكتب سطر تدقيق، و`stable` تفتح معاملةً للقراءة
-- فقط فيُرفض الإدراج. أُصلح في 0074.
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;
  if not public.check_admin_code(p_code) then
    raise exception 'رمز المدير غير صحيح';
  end if;

  perform public.log_action('dashboard.export', 'trips', null,
    'صُدِّرت بيانات اللوحة');

  return query
  select
    left(t.id::text, 8),
    to_char(t.requested_at at time zone 'Asia/Baghdad', 'YYYY-MM-DD HH24:MI'),
    case t.status
      when 'completed' then 'مكتملة'
      when 'cancelled' then 'ملغاة'
      else t.status::text
    end,
    r.full_name, r.phone,
    d.full_name, d.phone,
    t.pickup_address,
    t.dropoff_address,
    -- الفعلية إن سُجّلت، وإلا التقدير — والصفر يعني أن لا هذه ولا تلك.
    round(coalesce(t.actual_distance_m, t.estimated_distance_m, 0)
          / 1000.0, 2),
    t.fare_final_iqd,
    t.commission_iqd,
    t.driver_earning_iqd
  from public.trips t
  left join public.profiles r on r.id = t.rider_id
  left join public.profiles d on d.id = t.driver_id
  where t.requested_at >= coalesce(public.dashboard_epoch(), '-infinity')
  order by t.requested_at desc
  limit 5000;
end;
$fn$;

revoke all on function public.admin_export_trips(text) from public, anon;
grant execute on function public.admin_export_trips(text) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — يضبط الرمز أيضاً
-- -----------------------------------------------------------------------------
-- **بدّل الرمز قبل التشغيل.** ما هنا مثالٌ ظاهر، ومن يقرأ الترحيل
-- يقرؤه. غيّره بعد التطبيق من اللوحة أو بإعادة تشغيل هذا السطر.
insert into public.admin_secrets (key, hash)
values ('action_code',
        extensions.crypt('newcodE&245678', extensions.gen_salt('bf')))
on conflict (key) do nothing;

select
  (select value from public.public_settings where key = 'dashboard_epoch')
    as "نقطة الصفر",
  exists (select 1 from public.admin_secrets where key = 'action_code')
    as "الرمز مضبوط";
