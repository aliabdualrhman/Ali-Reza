-- =============================================================================
-- 0062 — توثيق رقم الهاتف برمزٍ يصل واتساب
-- =============================================================================
-- **رقم الهاتف اليوم مكتوبٌ لا مُثبَت.** يكتبه المستخدم عند التسجيل، ولا
-- شيء يتحقّق أنه يملكه. والقيد الوحيد أنه فريد.
--
-- وأثره يظهر حيث يؤلم:
--
--   • **سائقٌ برقمٍ خاطئ لا يصله السحب** — نرسل المال إلى رقمٍ ليس له.
--   • **وراكبٌ لا يستطيع سائقه الاتصال به** حين يقف بالباب ولا يجده.
--   • **وحساباتٌ وهمية** بأرقام مخترَعة تلتهم مكافآت الدعوة.
--
-- ------------------------------------------------------------------
-- ثلاثة قرارات
-- ------------------------------------------------------------------
--
-- **١) واتساب أولاً ثم رسالة نصّية.** واتساب أرخص وأوثق وصولاً في
-- العراق؛ ومن لا يملكه تصله رسالة عادية. مزوّدنا يدعم الارتداد التلقائي
-- (`whatsapp-sms`) فلا نبني بديلاً بأنفسنا.
--
-- **٢) لا يُوقف التسجيل.** يُطلب من الجميع، ومن فشل عنده أو تخطّاه يدخل
-- حسابه **غير موثَّق** ويوثّقه لاحقاً من «حسابي». لأن حاجزاً في أول
-- دقيقة يفقدنا الناس قبل أن يروا التطبيق — والرقم يبقى مطلوباً، لا
-- لحظتُه.
--
-- **٣) الرمز يُخزَّن مُجزَّأً لا نصّاً.** من يقرأ الجدول لا يستطيع أن
-- يوثّق حساب غيره. وهو احتياطٌ ضد تسريب لا نتوقّعه — والاحتياط أرخص من
-- الثقة.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الرموز
-- -----------------------------------------------------------------------------
create table if not exists public.phone_verifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,

  phone        text not null,

  -- **مُجزَّأ لا نصّ.** انظر القرار ٣ أعلاه.
  code_hash    text not null,

  -- معرّف المزوّد — لتتبّع التسليم عند الشكوى.
  provider_id  text,

  attempts     smallint not null default 0,
  verified_at  timestamptz,
  expires_at   timestamptz not null,
  created_at   timestamptz not null default now()
);

create index if not exists phone_verifications_user_idx
  on public.phone_verifications (user_id, created_at desc);

alter table public.phone_verifications enable row level security;

-- **لا يقرؤه أحد من التطبيق.** التحقّق يجري في دالة، ومن يقرأ الصفّ
-- يرى `code_hash` ويحاول كسره. المدير يراه للدعم.
drop policy if exists phone_verifications_admin on public.phone_verifications;
create policy phone_verifications_admin on public.phone_verifications
  for select to authenticated using (public.is_admin());


-- -----------------------------------------------------------------------------
-- ٢) الإعدادات
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value, label) values
  ('otp_enabled',        '1',   'تفعيل توثيق الهاتف'),
  ('otp_ttl_minutes',    '10',  'صلاحية رمز التحقق بالدقائق'),
  ('otp_max_attempts',   '5',   'عدد المحاولات قبل إبطال الرمز'),
  ('otp_cooldown_sec',   '60',  'المهلة بين طلبين للرمز (ثانية)'),
  ('otp_daily_limit',    '5',   'أقصى عدد رموز للمستخدم يومياً')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- ٣) طلب رمز
-- -----------------------------------------------------------------------------
-- **يكتب الصفّ ويترك الإرسال للخادم.** مفتاح المزوّد سرّي (`sk_live_…`)
-- ولا يجوز أن يمرّ بالتطبيق إطلاقاً — فيلتقط مُشغّلٌ الصفَّ ويستدعي دالة
-- الحافة، تماماً كما نفعل مع الإشعارات.
create or replace function public.request_phone_code()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_phone  text;
  v_ver    boolean;
  v_code   text;
  v_ttl    integer;
  v_cool   integer;
  v_limit  integer;
  v_last   timestamptz;
  v_today  integer;
  v_row    public.phone_verifications;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  if public.referral_setting('otp_enabled', 1) = 0 then
    raise exception 'توثيق الهاتف متوقّف حالياً';
  end if;

  select phone, phone_verified into v_phone, v_ver
  from public.profiles where id = v_uid;

  if v_ver then
    raise exception 'رقمك موثَّق بالفعل';
  end if;
  if coalesce(btrim(v_phone), '') = '' then
    raise exception 'لا يوجد رقم هاتف في حسابك';
  end if;

  -- ---- مهلةٌ بين طلبين ----
  -- **حارسٌ ماليّ لا أمنيّ فقط.** كل رسالة تكلّف، وزرٌّ يُضغط عشرين مرة
  -- بالخطأ يستهلك رصيداً حقيقياً.
  v_cool := public.referral_setting('otp_cooldown_sec', 60)::integer;
  select max(created_at) into v_last
  from public.phone_verifications where user_id = v_uid;

  if v_last is not null and v_last > now() - make_interval(secs => v_cool) then
    raise exception 'انتظر % ثانية قبل طلب رمز جديد',
      ceil(extract(epoch from (v_last + make_interval(secs => v_cool) - now())))::integer;
  end if;

  -- ---- سقفٌ يومي ----
  v_limit := public.referral_setting('otp_daily_limit', 5)::integer;
  select count(*) into v_today
  from public.phone_verifications
  where user_id = v_uid and created_at > now() - interval '24 hours';

  if v_today >= v_limit then
    raise exception 'بلغتَ الحد اليومي لطلب الرموز. حاول غداً.';
  end if;

  -- ---- الرمز ----
  -- ستة أرقام: أقصر يُخمَّن، وأطول يُكتب خطأً على هاتف.
  v_code := lpad((floor(random() * 1000000))::integer::text, 6, '0');
  v_ttl  := public.referral_setting('otp_ttl_minutes', 10)::integer;

  -- **نُبطل ما سبق.** رمزان صالحان في آنٍ يعنيان أن رمزاً قديماً مسرّباً
  -- يبقى نافذاً بعد أن طلب صاحبه غيره.
  update public.phone_verifications
  set expires_at = now()
  where user_id = v_uid and verified_at is null and expires_at > now();

  insert into public.phone_verifications
    (user_id, phone, code_hash, expires_at)
  values (
    v_uid,
    v_phone,
    extensions.crypt(v_code, extensions.gen_salt('bf')),
    now() + make_interval(mins => v_ttl)
  )
  returning * into v_row;

  -- **الرمز نصّاً في الحمولة لا في الجدول.** المُشغّل يمرّره إلى دالة
  -- الحافة التي ترسله، ولا يبقى منه أثر بعدها.
  return jsonb_build_object(
    'id',      v_row.id,
    'phone',   v_phone,
    'code',    v_code,
    'ttl_min', v_ttl
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) تأكيد الرمز
-- -----------------------------------------------------------------------------
create or replace function public.verify_phone_code(p_code text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_row  public.phone_verifications;
  v_max  integer;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  select * into v_row
  from public.phone_verifications
  where user_id = v_uid and verified_at is null
  order by created_at desc
  limit 1;

  if v_row.id is null then
    raise exception 'اطلب رمزاً أولاً';
  end if;
  if v_row.expires_at <= now() then
    raise exception 'انتهت صلاحية الرمز. اطلب رمزاً جديداً.';
  end if;

  v_max := public.referral_setting('otp_max_attempts', 5)::integer;
  if v_row.attempts >= v_max then
    raise exception 'تجاوزتَ عدد المحاولات. اطلب رمزاً جديداً.';
  end if;

  -- **نعدّ المحاولة قبل الفحص.** لو عددناها بعده لخرج المخمّن من الدالة
  -- عند كل خطأ بلا أن تُحسب محاولته.
  update public.phone_verifications
  set attempts = attempts + 1 where id = v_row.id;

  if extensions.crypt(btrim(p_code), v_row.code_hash) <> v_row.code_hash then
    return false;
  end if;

  update public.phone_verifications
  set verified_at = now() where id = v_row.id;

  -- يتخطّى حارس 0007 الذي يمنع التطبيق من توثيق نفسه — وهذه هي
  -- «المراجعة» التي يقصدها الحارس.
  perform set_config('app.bypass_guards', 'on', true);

  update public.profiles
  set phone_verified = true
  where id = v_uid;

  perform set_config('app.bypass_guards', 'off', true);

  return true;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) المُشغّل يرسل
-- -----------------------------------------------------------------------------
-- الصفّ يُكتب في `request_phone_code`، والإرسال يحتاج مفتاحاً سرّياً —
-- فيمرّ بدالة الحافة كما تمرّ الإشعارات.
create or replace function public.send_phone_code()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text;
  v_key text;
begin
  select value into v_url from public.app_config where key = 'edge_otp_url';
  select value into v_key from public.app_config where key = 'edge_service_key';

  if v_url is null or v_key is null then
    return new;
  end if;

  -- **الرمز لا يُمرَّر هنا.** الصفّ لا يحمل إلا مُجزَّأه، ودالة الحافة
  -- تقرأ النصّ من إعداد الجلسة الذي وضعته `request_phone_code`.
  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := jsonb_build_object(
                 'id',    new.id,
                 'phone', new.phone,
                 'code',  current_setting('app.otp_code', true)
               ),
    timeout_milliseconds := 10000
  );

  return new;
end;
$fn$;

drop trigger if exists phone_verifications_send on public.phone_verifications;
create trigger phone_verifications_send
  after insert on public.phone_verifications
  for each row execute function public.send_phone_code();


-- **نضع الرمز في إعداد الجلسة قبل الإدراج** ليقرأه المُشغّل. وهو يعيش
-- داخل المعاملة وحدها ولا يُكتب في أيّ جدول.
create or replace function public.request_phone_code()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_phone  text;
  v_ver    boolean;
  v_code   text;
  v_ttl    integer;
  v_cool   integer;
  v_limit  integer;
  v_last   timestamptz;
  v_today  integer;
  v_row    public.phone_verifications;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  if public.referral_setting('otp_enabled', 1) = 0 then
    raise exception 'توثيق الهاتف متوقّف حالياً';
  end if;

  select phone, phone_verified into v_phone, v_ver
  from public.profiles where id = v_uid;

  if v_ver then raise exception 'رقمك موثَّق بالفعل'; end if;
  if coalesce(btrim(v_phone), '') = '' then
    raise exception 'لا يوجد رقم هاتف في حسابك';
  end if;

  v_cool := public.referral_setting('otp_cooldown_sec', 60)::integer;
  select max(created_at) into v_last
  from public.phone_verifications where user_id = v_uid;

  if v_last is not null and v_last > now() - make_interval(secs => v_cool) then
    raise exception 'انتظر % ثانية قبل طلب رمز جديد',
      ceil(extract(epoch from (v_last + make_interval(secs => v_cool) - now())))::integer;
  end if;

  v_limit := public.referral_setting('otp_daily_limit', 5)::integer;
  select count(*) into v_today
  from public.phone_verifications
  where user_id = v_uid and created_at > now() - interval '24 hours';

  if v_today >= v_limit then
    raise exception 'بلغتَ الحد اليومي لطلب الرموز. حاول غداً.';
  end if;

  v_code := lpad((floor(random() * 1000000))::integer::text, 6, '0');
  v_ttl  := public.referral_setting('otp_ttl_minutes', 10)::integer;

  update public.phone_verifications
  set expires_at = now()
  where user_id = v_uid and verified_at is null and expires_at > now();

  perform set_config('app.otp_code', v_code, true);

  insert into public.phone_verifications
    (user_id, phone, code_hash, expires_at)
  values (
    v_uid, v_phone,
    extensions.crypt(v_code, extensions.gen_salt('bf')),
    now() + make_interval(mins => v_ttl)
  )
  returning * into v_row;

  perform set_config('app.otp_code', '', true);

  -- **لا نعيد الرمز للتطبيق.** من يقرأ الاستجابة يوثّق نفسه بلا رسالة.
  return jsonb_build_object(
    'sent',    true,
    'phone',   v_phone,
    'ttl_min', v_ttl
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.request_phone_code()      from public, anon;
revoke all on function public.verify_phone_code(text)   from public, anon;

grant execute on function public.request_phone_code()    to authenticated;
grant execute on function public.verify_phone_code(text) to authenticated;


-- =============================================================================
-- بعد نشر الدالة، شغّل هذا (احذف علامات التعليق)
-- =============================================================================
/*
insert into public.app_config (key, value) values
  ('edge_otp_url',
   'https://jacixgrnovflddrzbegd.supabase.co/functions/v1/send-otp')
on conflict (key) do update set value = excluded.value, updated_at = now();
*/


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  count(*) filter (where phone_verified)     as "أرقام موثَّقة",
  count(*) filter (where not phone_verified) as "غير موثَّقة"
from public.profiles
where role in ('rider','driver') and deleted_at is null;
