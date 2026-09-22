-- =============================================================================
-- 0048 — رمز لكل جهاز، لا رمز لكل حساب
-- =============================================================================
-- **العطل.** `profiles.fcm_token` عمودٌ واحد (0002)، فالحساب الواحد لا
-- يحمل إلا رمز جهاز واحد. وحين يدخل نفس الحساب على جهاز ثانٍ يكتب رمزه
-- فوق الأول:
--
--     جهاز A يدخل  →  fcm_token = رمز A
--     جهاز B يدخل  →  fcm_token = رمز B      ← داس على A
--
-- فيصير A أعمى بلا أن يعلم: شاشة التشخيص عنده تقول «الخادم يرسل إلى
-- جهاز قديم»، والإشعارات تذهب كلها إلى B وحده.
--
-- **وهذا ليس حالة نادرة عندنا.** بيانات الدخول موزَّعة على المختبِرين،
-- فكل من يدخل يُعمي من قبله؛ ولهذا كان العطل يظهر «على بعض الأجهزة»
-- بلا نمط — كان يعمل على **آخر** جهاز دخل لا على جهازٍ بعينه.
--
-- **والصواب أن الرمز صفة جهاز لا صفة مستخدم.** فنُخرجه إلى جدوله،
-- ويبثّ الخادم إلى كل أجهزة السائق. وهذا ما تفعله كل التطبيقات — فلا
-- أحد يملك هاتفاً واحداً إلى الأبد: يبدّله، ويحمل اثنين، ويعيد التثبيت.
--
-- **ولا نحذف `profiles.fcm_token` الآن.** التطبيقات المنشورة تكتب فيه،
-- ونسخةٌ قديمة على جهاز مختبِر تبقى تعمل حتى يُحدِّث. الخادم يقرأ من
-- الجدول أولاً ويرجع إلى العمود إن كان فارغاً.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الجدول
-- -----------------------------------------------------------------------------
create table if not exists public.user_devices (
  token        text        primary key,
  user_id      uuid        not null references auth.users(id) on delete cascade,
  platform     text        not null default 'android'
                           check (platform in ('android','ios','web')),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

-- **الرمز هو المفتاح لا (المستخدم، الرمز).** الرمز يتبع الجهاز لا
-- الحساب: حين يخرج سائق ويدخل آخر على الهاتف نفسه، يبقى الرمز واحداً
-- ويجب أن **ينتقل** لا أن يُنسخ. مفتاحٌ مركّب يترك الصفّ القديم حيّاً،
-- فتصل عروض السائق الجديد إلى هاتف الأول أيضاً.
create index if not exists user_devices_user_idx
  on public.user_devices (user_id);

-- **تنظيف الرموز الميتة.** الرمز الذي لم يُرَ منذ شهرين يخصّ تثبيتاً
-- مُزال؛ إبقاؤه يعني محاولة إرسال فاشلة في كل عرض.
create index if not exists user_devices_last_seen_idx
  on public.user_devices (last_seen_at);


-- -----------------------------------------------------------------------------
-- ٢) الحماية
-- -----------------------------------------------------------------------------
alter table public.user_devices enable row level security;

-- **قراءة الرموز ممنوعة على الجميع.** لا التطبيق يحتاجها ولا المدير؛
-- الخادم وحده يقرأ بمفتاح `service_role` الذي يتخطّى RLS. ورمزٌ مسرَّب
-- يعني إشعارات مزوَّرة على هاتف سائق.
drop policy if exists user_devices_own_write on public.user_devices;
create policy user_devices_own_write on public.user_devices
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());


-- -----------------------------------------------------------------------------
-- ٣) تسجيل الجهاز — دالة واحدة تكفي التطبيق
-- -----------------------------------------------------------------------------
-- **`insert … on conflict` لا `insert` وحده.** الرمز نفسه قد يصل مرتين
-- (إقلاع التطبيق، ثم حدث الدخول)؛ ومحاولة إدراج مكرّر ترمي خطأً يبتلعه
-- التطبيق صامتاً فلا يُحدَّث `last_seen_at` أبداً.
create or replace function public.register_device(
  p_token    text,
  p_platform text default 'android'
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'لا توجد جلسة';
  end if;

  if coalesce(btrim(p_token), '') = '' then
    return;   -- لا رمز، لا عمل. ليس خطأً يستحق إسقاط الإقلاع.
  end if;

  insert into public.user_devices (token, user_id, platform, last_seen_at)
  values (btrim(p_token), v_uid, coalesce(p_platform, 'android'), now())
  on conflict (token) do update
    set user_id      = excluded.user_id,   -- الجهاز انتقل لمستخدم آخر
        platform     = excluded.platform,
        last_seen_at = now();

  -- نُبقي العمود القديم محدَّثاً ما دامت نسخٌ منشورة تقرؤه.
  update public.profiles set fcm_token = btrim(p_token) where id = v_uid;
end;
$fn$;


-- **الخروج يُزيل هذا الجهاز وحده.** كان الخروج يمسح `fcm_token` فيقطع
-- الإشعارات عن كل أجهزة الحساب؛ والسائق الذي خرج من هاتفه الثاني يفقد
-- عروضه على الأول بلا سبب مفهوم.
create or replace function public.unregister_device(p_token text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return; end if;

  delete from public.user_devices
  where token = btrim(p_token) and user_id = v_uid;

  update public.profiles
  set fcm_token = null
  where id = v_uid and fcm_token = btrim(p_token);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) نقل ما هو موجود
-- -----------------------------------------------------------------------------
-- الرموز المخزّنة اليوم صالحة؛ ننقلها كي لا ينقطع أحد لحظة الترحيل.
insert into public.user_devices (token, user_id, platform, last_seen_at)
select fcm_token, id, 'android', now()
from public.profiles
where fcm_token is not null and btrim(fcm_token) <> ''
on conflict (token) do nothing;


-- -----------------------------------------------------------------------------
-- ٥) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.register_device(text, text)   from public, anon;
revoke all on function public.unregister_device(text)       from public, anon;

grant execute on function public.register_device(text, text) to authenticated;
grant execute on function public.unregister_device(text)     to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  count(*)                        as "أجهزة مسجَّلة",
  count(distinct user_id)         as "مستخدمون",
  count(*) filter (where platform = 'android') as "أندرويد"
from public.user_devices;
