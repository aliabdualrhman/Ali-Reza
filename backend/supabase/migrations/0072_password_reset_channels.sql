-- =============================================================================
-- 0072 — استعادة كلمة المرور: بالبريد أو بالواتساب
-- =============================================================================
-- كانت الاستعادة بالبريد وحده. ومنذ صار الهاتف قناةً موثَّقة — بل صار
-- أكثر ما يُوثَّق في وضع الهاتف — بقي من وثّق رقمه ولم يفتح بريده بلا
-- طريقٍ إلى حسابه إن نسي كلمته.
--
-- ------------------------------------------------------------------
-- والقناتان لا تُبنيان بالطريقة نفسها
-- ------------------------------------------------------------------
--   • **البريد** يديره GoTrue بنفسه: يرسل رمزاً، ويتحقّق منه، ويعطي
--     جلسةً يغيّر بها صاحبها كلمته. لا نكتب فيه سطراً، ولا نلمس مفتاحاً
--     سرّياً. وهذا أأمن ما يكون.
--
--   • **الواتساب** رمزه رمزُنا، ولا يعرفه GoTrue. فلا بدّ من دالةٍ
--     طرفية تتحقّق منه ثم تغيّر الكلمة بمفتاح `service_role`.
--
-- **وهذا الباب أخطر ما في النظام:** من فتحه أخذ حساباً كاملاً برصيده.
-- فحراساته أشدّ من حراسات التوثيق العادي:
--
--   ١. الرمز مُجزَّأ (bcrypt) كما في `phone_verifications`.
--   ٢. صلاحية عشر دقائق، ومحاولاتٌ معدودة.
--   ٣. **لمرة واحدة**: يُستهلك عند النجاح فلا يُعاد استعماله.
--   ٤. **لا يُرسل إلا لرقمٍ موثَّق.** غير الموثَّق قد لا يملكه صاحب
--      الحساب أصلاً — فإرساله إليه تسليمُ الحساب لغريب.
--   ٥. مهلةٌ بين طلبين وسقفٌ يومي — للكلفة وللتخمين معاً.
--   ٦. `consume_reset_code` ممنوعةٌ عن `anon` و`authenticated`: لا
--      يستدعيها إلا الدالة الطرفية بمفتاح الخدمة.
--
-- ------------------------------------------------------------------
-- وما نكشفه عمداً
-- ------------------------------------------------------------------
-- `reset_channels` تقول إن كان الحساب موجوداً، وتعرض بريداً ورقماً
-- **مقنَّعين**. وهو ما يكشفه أيّ نظامٍ عند «نسيت كلمة المرور»، والبديل
-- أن يقف رجلٌ أمام شاشةٍ لا تقول له أين ذهب الرمز فيظنّه لم يُرسل.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الجدول
-- -----------------------------------------------------------------------------
create table if not exists public.password_resets (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,

  channel     text not null check (channel in ('phone', 'email')),
  target      text not null,

  code_hash   text not null,
  attempts    smallint not null default 0,
  used_at     timestamptz,
  expires_at  timestamptz not null,
  created_at  timestamptz not null default now()
);

create index if not exists password_resets_user_idx
  on public.password_resets (user_id, created_at desc);

alter table public.password_resets enable row level security;

-- **لا يقرؤه أحد.** حتى المشرف: صفٌّ فيه `code_hash` لا فائدة منه في
-- الدعم، وقراءته إغراءٌ بلا نفع.
drop policy if exists password_resets_none on public.password_resets;

comment on table public.password_resets is
  'رموز استعادة كلمة المرور. مُجزَّأة، لمرة واحدة، وقصيرة الصلاحية.';


insert into public.public_settings (key, value, label) values
  ('reset_ttl_minutes',  '10', 'صلاحية رمز استعادة كلمة المرور (دقائق)'),
  ('reset_max_attempts', '5',  'محاولات رمز الاستعادة قبل إبطاله'),
  ('reset_cooldown_sec', '90', 'المهلة بين طلبَي استعادة (ثانية)'),
  ('reset_daily_limit',  '5',  'أقصى عدد رموز استعادة يومياً')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- ٢) التقنيع
-- -----------------------------------------------------------------------------
-- **يكفي ليتعرّف صاحبه ولا يكفي ليكتبه غيره.**
create or replace function public.mask_contact(p_value text, p_kind text)
returns text
language sql
immutable
as $fn$
  select case
    when coalesce(btrim(p_value), '') = '' then null
    when p_kind = 'email' then
      left(split_part(p_value, '@', 1), 1) || '•••@' ||
      split_part(p_value, '@', 2)
    else
      -- آخر أربعة أرقام وحدها: '+964 ••• ••• 2451'
      '••• ' || right(p_value, 4)
  end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) أيّ القنوات متاحة؟
-- -----------------------------------------------------------------------------
-- يُنادى قبل أن توجد جلسة، فلا بدّ من `anon`.
create or replace function public.reset_channels(p_identifier text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_id     text := btrim(coalesce(p_identifier, ''));
  v_digits text := regexp_replace(v_id, '[^0-9]', '', 'g');
  v_phone  text;
  v_p      public.profiles;
begin
  if v_id = '' then
    return jsonb_build_object('found', false);
  end if;

  -- **الرقم يُوحَّد كما توحّده القاعدة.** الرجل يكتب 07xx والقاعدة
  -- تخزّن ‎+9647xx، فبلا توحيدٍ لا يجد حسابه أبداً.
  if v_digits ~ '^07[3-9][0-9]{8}$' then
    v_phone := '+964' || substring(v_digits from 2);
  elsif v_digits ~ '^9647[3-9][0-9]{8}$' then
    v_phone := '+' || v_digits;
  elsif v_digits ~ '^7[3-9][0-9]{8}$' then
    v_phone := '+964' || v_digits;
  end if;

  if v_phone is not null then
    select * into v_p from public.profiles
    where phone = v_phone and deleted_at is null;
  else
    select * into v_p from public.profiles
    where lower(email) = lower(v_id) and deleted_at is null;
  end if;

  if v_p.id is null then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found', true,
    'phone_ok', coalesce(v_p.phone_verified, false),
    'email_ok', coalesce(v_p.email_verified, false),
    'phone_masked', public.mask_contact(v_p.phone, 'phone'),
    'email_masked', public.mask_contact(v_p.email, 'email'),
    -- البريد يلزم التطبيق ليناديَ GoTrue به. ولا نكشف الرقم كاملاً.
    'email', case when coalesce(v_p.email_verified, false)
                  then v_p.email else null end
  );
end;
$fn$;

revoke all on function public.reset_channels(text) from public;
grant execute on function public.reset_channels(text) to anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٤) طلب رمزٍ على الواتساب
-- -----------------------------------------------------------------------------
create or replace function public.request_reset_code(p_identifier text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_ch    jsonb := public.reset_channels(p_identifier);
  v_p     public.profiles;
  v_code  text;
  v_ttl   integer;
  v_cool  integer;
  v_limit integer;
  v_last  timestamptz;
  v_today integer;
  v_row   public.password_resets;
begin
  if not (v_ch ->> 'found')::boolean then
    raise exception 'لا يوجد حساب بهذه البيانات';
  end if;
  if not (v_ch ->> 'phone_ok')::boolean then
    raise exception 'رقم هذا الحساب غير موثَّق. استعمل البريد.';
  end if;

  -- نعيد إيجاد الصفّ: `reset_channels` لا تعيد المعرّف عمداً.
  select p.* into v_p
  from public.profiles p
  where p.deleted_at is null
    and public.mask_contact(p.phone, 'phone') = v_ch ->> 'phone_masked'
    and p.phone_verified
    and (
      lower(p.email) = lower(btrim(p_identifier))
      or regexp_replace(p.phone, '[^0-9]', '', 'g')
         like '%' || regexp_replace(btrim(p_identifier), '[^0-9]', '', 'g')
    )
  limit 1;

  if v_p.id is null then
    raise exception 'لا يوجد حساب بهذه البيانات';
  end if;

  -- ---- مهلةٌ بين طلبين ----
  v_cool := public.referral_setting('reset_cooldown_sec', 90)::integer;
  select max(created_at) into v_last
  from public.password_resets where user_id = v_p.id;

  if v_last is not null and v_last > now() - make_interval(secs => v_cool) then
    raise exception 'انتظر % ثانية قبل طلب رمز جديد',
      ceil(extract(epoch from
        (v_last + make_interval(secs => v_cool) - now())))::integer;
  end if;

  -- ---- سقفٌ يومي ----
  v_limit := public.referral_setting('reset_daily_limit', 5)::integer;
  select count(*) into v_today
  from public.password_resets
  where user_id = v_p.id and created_at > now() - interval '24 hours';

  if v_today >= v_limit then
    raise exception 'بلغتَ الحد اليومي لطلب الرموز. حاول غداً.';
  end if;

  v_code := lpad((floor(random() * 1000000))::integer::text, 6, '0');
  v_ttl  := public.referral_setting('reset_ttl_minutes', 10)::integer;

  -- **نُبطل ما سبق.** رمزان صالحان في آنٍ يعنيان أن قديماً مسرّباً يبقى
  -- نافذاً بعد أن طلب صاحبه غيره.
  update public.password_resets
  set expires_at = now()
  where user_id = v_p.id and used_at is null and expires_at > now();

  perform set_config('app.otp_code', v_code, true);

  insert into public.password_resets
    (user_id, channel, target, code_hash, expires_at)
  values (
    v_p.id, 'phone', v_p.phone,
    extensions.crypt(v_code, extensions.gen_salt('bf')),
    now() + make_interval(mins => v_ttl)
  )
  returning * into v_row;

  -- **الرمز لا يُعاد إلى التطبيق.** في التوثيق كان صاحب الجلسة يطلبه
  -- لنفسه؛ وهنا لا جلسة، فمن ينادي الدالة قد لا يكون صاحب الحساب.
  return jsonb_build_object(
    'sent', true,
    'phone_masked', v_ch ->> 'phone_masked',
    'ttl_min', v_ttl
  );
end;
$fn$;

revoke all on function public.request_reset_code(text) from public;
grant execute on function public.request_reset_code(text) to anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٥) الإرسال — كما في 0062
-- -----------------------------------------------------------------------------
create or replace function public.send_reset_code()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text;
  v_key text;
begin
  if new.channel <> 'phone' then return new; end if;

  select value into v_url from public.app_config where key = 'edge_otp_url';
  select value into v_key from public.app_config where key = 'edge_service_key';
  if v_url is null or v_key is null then return new; end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := jsonb_build_object(
                 'id',    new.id,
                 'phone', new.target,
                 'code',  current_setting('app.otp_code', true)
               ),
    timeout_milliseconds := 10000
  );

  return new;
end;
$fn$;

drop trigger if exists password_resets_send on public.password_resets;
create trigger password_resets_send
  after insert on public.password_resets
  for each row execute function public.send_reset_code();


-- -----------------------------------------------------------------------------
-- ٦) استهلاك الرمز — للدالة الطرفية وحدها
-- -----------------------------------------------------------------------------
-- **ممنوعةٌ عن التطبيق.** تعيد معرّف المستخدم، ومن يملكه مع مفتاح
-- الخدمة يغيّر كلمته. فلا تُمنح إلا لمن يحمل المفتاح أصلاً.
create or replace function public.consume_reset_code(
  p_identifier text,
  p_code       text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_ch  jsonb := public.reset_channels(p_identifier);
  v_row public.password_resets;
  v_max integer;
begin
  if not (v_ch ->> 'found')::boolean then
    raise exception 'رمز غير صالح';
  end if;

  select r.* into v_row
  from public.password_resets r
  join public.profiles p on p.id = r.user_id
  where r.used_at is null
    and r.channel = 'phone'
    and public.mask_contact(p.phone, 'phone') = v_ch ->> 'phone_masked'
  order by r.created_at desc
  limit 1;

  if v_row.id is null then
    raise exception 'اطلب رمزاً أولاً';
  end if;
  if v_row.expires_at <= now() then
    raise exception 'انتهت صلاحية الرمز. اطلب رمزاً جديداً.';
  end if;

  v_max := public.referral_setting('reset_max_attempts', 5)::integer;
  if v_row.attempts >= v_max then
    raise exception 'تجاوزتَ عدد المحاولات. اطلب رمزاً جديداً.';
  end if;

  -- تُعدّ قبل الفحص، وإلا خرج المخمّن بلا أن تُحسب محاولته.
  update public.password_resets
  set attempts = attempts + 1 where id = v_row.id;

  if extensions.crypt(btrim(p_code), v_row.code_hash) <> v_row.code_hash then
    raise exception 'الرمز غير صحيح';
  end if;

  update public.password_resets
  set used_at = now() where id = v_row.id;

  return v_row.user_id;
end;
$fn$;

revoke all on function public.consume_reset_code(text, text)
  from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — بدّل الرقم برقم حسابٍ موثَّق عندك
-- -----------------------------------------------------------------------------
select public.reset_channels('07801711922') as "القنوات المتاحة";
