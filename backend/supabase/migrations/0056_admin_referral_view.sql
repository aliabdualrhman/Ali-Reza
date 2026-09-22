-- =============================================================================
-- 0056 — قناة الوصول والدعوات في لوحة المدير
-- =============================================================================
-- **بيانات بلا واجهة تقرؤها ليست بيانات.** نحفظ منذ 0055 من أين سمع كل
-- مستخدم عنّا، ونسجّل كل دعوة ومصيرها — ولا شيء يعرضها.
--
-- وهذه أرخص معلومة تسويقية تملكها: تخبرك أيّ قناة تجلب زبوناً فعلاً قبل
-- أن تنفق ديناراً على إعلان. وسؤالٌ واحد عند التسجيل يكفي.
--
-- **ودالةٌ واحدة تخدم الطرفين** — سائقاً كان أم راكباً. فملف المستخدم
-- في اللوحة واحدٌ في معناه، وشطرُه دالتين يجعل إحداهما تتخلّف عن أختها
-- عند أول تعديل.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) بطاقة الدعوة لمستخدم
-- -----------------------------------------------------------------------------
create or replace function public.admin_referral_info(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_p public.profiles;
begin
  -- **الصلاحيتان مقبولتان.** من يرى السائقين يرى دعواتهم، ومن يرى
  -- الركّاب يرى دعواتهم. ولا نُنشئ صلاحية ثالثة لبطاقةٍ واحدة.
  if not (public.has_perm('drivers.view') or public.has_perm('riders.view')) then
    raise exception 'لا تملك صلاحية عرض المستخدمين'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_p from public.profiles where id = p_id;
  if v_p.id is null then raise exception 'المستخدم غير موجود'; end if;

  return jsonb_build_object(
    'heard_from',      v_p.heard_from,
    'heard_from_note', v_p.heard_from_note,
    'referral_code',   v_p.referral_code,

    -- دعواتٌ أرسلها هو
    'invited_total',    (select count(*) from public.referrals
                         where inviter_id = p_id),
    'invited_rewarded', (select count(*) from public.referrals
                         where inviter_id = p_id and status = 'rewarded'),
    'invited_pending',  (select count(*) from public.referrals
                         where inviter_id = p_id and status = 'pending'),
    'earned_iqd',       coalesce((select sum(reward_iqd) from public.referrals
                                  where inviter_id = p_id
                                    and status = 'rewarded'), 0),

    -- **ومن دعاه هو.** سؤالٌ يُطرح كثيراً عند الشكّ في حساب: من أدخله؟
    -- وسلسلةُ حساباتٍ يدعو بعضها بعضاً أوضحُ إشارةٍ على الاحتيال.
    'invited_by', (
      select jsonb_build_object(
               'name',   inv.full_name,
               'phone',  inv.phone,
               'status', r.status,
               'at',     r.created_at)
      from public.referrals r
      join public.profiles inv on inv.id = r.inviter_id
      where r.invitee_id = p_id
    )
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) تقرير قنوات الوصول
-- -----------------------------------------------------------------------------
-- **الرقم وحده لا يكفي — نحتاج من بقي منهم.** مئة مستخدم من إعلان لم
-- يركب منهم أحد أسوأ من عشرة من صديق ركبوا كلهم. فنعدّ من أكمل رحلة
-- إلى جانب من سجّل.
create or replace function public.admin_acquisition_report()
returns table (
  source        text,
  signups       integer,
  activated     integer,
  activation_pct numeric
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  return query
  select
    coalesce(p.heard_from, 'unknown')::text,
    count(*)::integer,
    count(*) filter (where act.done)::integer,
    round(
      100.0 * count(*) filter (where act.done) / nullif(count(*), 0), 1)
  from public.profiles p
  left join lateral (
    select exists (
      select 1 from public.trips t
      where (t.rider_id = p.id or t.driver_id = p.id)
        and t.status = 'completed'
    ) as done
  ) act on true
  where p.role in ('rider', 'driver')
    and p.deleted_at is null
  group by 1
  order by 2 desc;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.admin_referral_info(uuid) from public, anon;
revoke all on function public.admin_acquisition_report() from public, anon;

grant execute on function public.admin_referral_info(uuid) to authenticated;
grant execute on function public.admin_acquisition_report() to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
-- **لا نستدعي الدوال نفسها هنا.** كلّها تفحص `is_admin()` أو
-- `has_perm()`، وهما تقرآن `auth.uid()` — ومحرّر SQL يعمل بحساب قاعدة
-- البيانات لا بحساب مديرٍ مسجَّل، فلا جلسة ولا مُعرِّف.
--
-- فتردّ `42501: للمشرف وحده`، **وهو نجاحُ الحارس لا فشلُ الترحيل**.
-- نفحص أن الدوال أُنشئت، وتُختبر من اللوحة.
select proname as "الدالة أُنشئت"
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and proname in ('admin_referral_info', 'admin_acquisition_report')
order by 1;


-- وقنوات الوصول بلا حارس — استعلامٌ مباشر لا دالة.
-- (الكل 'لم يُسأل' الآن: السؤال يصل المستخدمين مع الإصدار القادم)
select
  coalesce(heard_from, 'لم يُسأل') as "القناة",
  count(*)                          as "التسجيلات"
from public.profiles
where role in ('rider', 'driver') and deleted_at is null
group by 1
order by 2 desc;
