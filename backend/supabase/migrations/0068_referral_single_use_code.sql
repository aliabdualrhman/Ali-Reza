-- =============================================================================
-- 0068 — الرمز لمدعوٍّ واحد، ونافذته شرطان لا شرط
-- =============================================================================
-- ------------------------------------------------------------------
-- ١) ثغرةٌ تركها ٠٠٦٧
-- ------------------------------------------------------------------
-- **أصلحنا الدالة الخطأ.** ٠٠٦٧ شدّ `apply_referral_code` — وهي التي
-- يستدعيها مُشغّل التسجيل — وترك `redeem_referral_code`، وهي التي
-- يستدعيها التطبيق حين يكتب المستخدم رمزاً من «حسابي». فبقي أكثر
-- المسارين استعمالاً بلا الشرط الجديد.
--
-- والسبب أنهما كانتا نسختين متطابقتين تقريباً. فنجعل الثانية تنادي
-- الأولى: كل حارسٍ نضيفه بعد اليوم يُكتب مرة واحدة.
--
-- ------------------------------------------------------------------
-- ٢) النافذة: الأيام **و** أول رحلة
-- ------------------------------------------------------------------
-- شرطان، وأيّهما وقع أوّلاً أغلق الباب:
--
--   • **المهلة تبقى** — من مضى على تسجيله أسبوعان ولم يذكر داعياً لم
--     يأتِ من دعوة. والمدّة من اللوحة كما كانت.
--
--   • **وأول رحلة تُغلقها قبلها** — الدعوة تكافئ من جلب مستخدماً، لا من
--     التقط زبوناً بعد أن صار زبوناً. ومن ركب مرة أثبت أنه وجد التطبيق
--     بنفسه، ولو كان ذلك في يومه الأول.
--
-- والرحلة أمتن من المهلة: الأيام تُنتظر، والرحلة لا تُسترجع.
--
-- ------------------------------------------------------------------
-- ٣) الرمز: مدعوٌّ واحد ثم يتجدّد
-- ------------------------------------------------------------------
-- كان الرمز واحداً يقبله مدعوّان. صار كلٌّ منه لمدعوٍّ واحد: ما إن
-- يُدخله أحد حتى يُتقاعد ويُولَّد لصاحبه رمزٌ جديد.
--
-- **والتجديد تلقائيّ فلا يخسر الداعي شيئاً** — يفتح الشاشة فيجد رمزاً
-- جاهزاً، ويبقى سقفه كما هو.
--
-- **والمتقاعد لا يعود.** نفحص التوليد ضدّ `referrals.code_used` أيضاً،
-- وإلا وقع رمزٌ قديم لشخصٍ آخر بعد شهر، فذهبت دعوةٌ إلى غريب بسبب
-- رسالةٍ لم تُمسح من هاتف أحدهم.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) التوليد يتجنّب المتقاعد
-- -----------------------------------------------------------------------------
create index if not exists referrals_code_used_idx
  on public.referrals (code_used);

create or replace function public.generate_referral_code()
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $fn$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code  text;
  v_try   integer := 0;
begin
  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code
        || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
    end loop;

    exit when not exists (
        select 1 from public.profiles where referral_code = v_code)
      and not exists (
        select 1 from public.referrals where code_used = v_code);

    v_try := v_try + 1;
    -- ٣٢^٦ ≈ مليار احتمال. عشر محاولات فاشلة تعني عطلاً لا تزاحماً.
    if v_try > 10 then
      raise exception 'تعذّر توليد رمز دعوة';
    end if;
  end loop;

  return v_code;
end;
$fn$;

comment on column public.profiles.referral_code is
  'الرمز الصالح الآن. يُتقاعد فور استعماله ويُولَّد غيره.';


-- -----------------------------------------------------------------------------
-- ٢) رمزٌ جديد بطلب صاحبه
-- -----------------------------------------------------------------------------
-- **لأن الرمز قد يُسرَّب.** من نشره في مكانٍ عام ثم ندم يحتاج أن يُبطله
-- بلا أن ينتظر مدعوّاً يستهلكه.
create or replace function public.rotate_referral_code()
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_code text;
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;

  v_code := public.generate_referral_code();
  update public.profiles set referral_code = v_code where id = v_uid;
  return v_code;
end;
$fn$;

revoke all on function public.rotate_referral_code() from public, anon;
grant execute on function public.rotate_referral_code() to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) هل يستطيع إدخال رمز الآن؟
-- -----------------------------------------------------------------------------
-- **يقرؤها التطبيق ليُخفي الزرّ.** وزرٌّ يُضغط فيُرفض أسوأ من زرٍّ غائب:
-- الأول يوهم بفرصةٍ ضائعة، والثاني لا يُسأل عنه.
create or replace function public.can_redeem_referral()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_me    public.profiles;
  v_grace integer;
  v_trips integer;
begin
  if v_uid is null then
    return jsonb_build_object('can', false, 'reason', 'no_session');
  end if;

  if public.referral_setting('referral_enabled', 1) = 0 then
    return jsonb_build_object('can', false, 'reason', 'disabled');
  end if;

  select * into v_me from public.profiles where id = v_uid;
  if v_me.id is null or v_me.role = 'admin' then
    return jsonb_build_object('can', false, 'reason', 'admin');
  end if;

  if exists (select 1 from public.referrals where invitee_id = v_uid) then
    return jsonb_build_object('can', false, 'reason', 'already_used');
  end if;

  -- **أيّ رحلة تُغلق النافذة** — مكتملةً كانت أم ملغاة. فمن طلب رحلةً
  -- وألغاها استعمل التطبيق فعلاً، ولم يعد مستخدماً جديداً.
  select count(*) into v_trips
  from public.trips
  where rider_id = v_uid or driver_id = v_uid;

  if v_trips > 0 then
    return jsonb_build_object('can', false, 'reason', 'has_trips');
  end if;

  v_grace := public.referral_setting('referral_code_grace_days', 7)::integer;
  if v_me.created_at < now() - make_interval(days => v_grace) then
    return jsonb_build_object('can', false, 'reason', 'expired');
  end if;

  return jsonb_build_object('can', true, 'days_left',
    greatest(0, v_grace - extract(day from now() - v_me.created_at)::integer));
end;
$fn$;

revoke all on function public.can_redeem_referral() from public, anon;
grant execute on function public.can_redeem_referral() to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) إدخال الرمز — الحارس في القاعدة لا في الشاشة
-- -----------------------------------------------------------------------------
-- **إخفاء الزرّ ليس حماية.** من يستدعي الدالة مباشرةً يتجاوز الواجهة.
create or replace function public.apply_referral_code(
  p_invitee uuid,
  p_code    text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_me       public.profiles;
  v_inviter  public.profiles;
  v_code     text := upper(btrim(coalesce(p_code, '')));
  v_grace    integer;
  v_cap      integer;
  v_rewarded integer;
  v_trips    integer;
begin
  if v_code = '' then
    raise exception 'اكتب رمز الدعوة';
  end if;

  if public.referral_setting('referral_enabled', 1) = 0 then
    raise exception 'نظام الدعوة متوقّف حالياً';
  end if;

  select * into v_me from public.profiles where id = p_invitee;
  if v_me.id is null then
    raise exception 'حساب غير موجود';
  end if;

  if exists (select 1 from public.referrals where invitee_id = p_invitee) then
    raise exception 'أدخلتَ رمز دعوة من قبل';
  end if;

  -- ---- النافذة: الرحلة أولاً ثم المهلة ----
  select count(*) into v_trips
  from public.trips
  where rider_id = p_invitee or driver_id = p_invitee;

  if v_trips > 0 then
    raise exception 'رمز الدعوة يُدخَل قبل أول رحلة';
  end if;

  v_grace := public.referral_setting('referral_code_grace_days', 7)::integer;
  if v_me.created_at < now() - make_interval(days => v_grace) then
    raise exception 'انتهت مهلة إدخال رمز الدعوة (% أيام من التسجيل)', v_grace;
  end if;

  select * into v_inviter from public.profiles where referral_code = v_code;
  if v_inviter.id is null then
    -- **رمزٌ مستعمَلٌ ورمزٌ خاطئ رسالتهما واحدة؟ لا.** من أعطاه صديقه
    -- رمزاً استهلكه غيره يستحق أن يعرف، وإلا اتّهم نفسه بخطأ الكتابة.
    if exists (select 1 from public.referrals where code_used = v_code) then
      raise exception 'هذا الرمز استُعمل من قبل. اطلب من صديقك رمزه الجديد.';
    end if;
    raise exception 'رمز الدعوة غير صحيح';
  end if;

  if v_inviter.id = p_invitee then
    raise exception 'لا يمكنك استعمال رمزك';
  end if;

  -- **سائقٌ يدعو سائقاً وراكبٌ يدعو راكباً.** المكافأتان مختلفتان
  -- ومصدراهما مختلفان، وخلطُهما يفتح باباً لا نعرف كلفته.
  if v_inviter.role is distinct from v_me.role then
    raise exception 'رمز الدعوة لا يصلح لهذا النوع من الحسابات';
  end if;

  if v_me.role = 'admin' or v_inviter.role = 'admin' then
    raise exception 'حسابات المشرفين خارج نظام الدعوة';
  end if;

  -- الحارس ٢: جهاز مشترك. مبهم عمداً — لا نُعلّم المحتال أين الحارس.
  if exists (
    select 1
    from public.user_devices a
    join public.user_devices b on b.token = a.token
    where a.user_id = v_inviter.id and b.user_id = p_invitee
  ) then
    raise exception 'تعذّر قبول الرمز';
  end if;

  -- الحارس ٦: السقف الكلّي
  v_cap := public.referral_setting('referral_max_per_user', 2)::integer;
  select count(*) into v_rewarded
  from public.referrals
  where inviter_id = v_inviter.id and status = 'rewarded';

  if v_rewarded >= v_cap then
    raise exception 'بلغ صاحب هذا الرمز الحد الأقصى للدعوات';
  end if;

  insert into public.referrals (inviter_id, invitee_id, code_used)
  values (v_inviter.id, p_invitee, v_code);

  -- **يتقاعد الرمز هنا.** الصفّ أعلاه يحفظه في `code_used` فيبقى أثره
  -- ولا يعود مفتاحاً، والداعي يجد رمزاً جديداً بلا أن يطلب.
  update public.profiles
  set referral_code = public.generate_referral_code()
  where id = v_inviter.id;

  return jsonb_build_object(
    'inviter', split_part(v_inviter.full_name, ' ', 1),
    'required_trips',
      public.referral_setting('referral_required_trips', 3)::integer
  );
end;
$fn$;

revoke all on function public.apply_referral_code(uuid, text)
  from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- ٥) نسخة المستخدم — نداءٌ واحدٌ للمنطق نفسه
-- -----------------------------------------------------------------------------
create or replace function public.redeem_referral_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'لا توجد جلسة'; end if;
  return public.apply_referral_code(v_uid, p_code);
end;
$fn$;

revoke all on function public.redeem_referral_code(text) from public, anon;
grant execute on function public.redeem_referral_code(text) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — يُتوقّع no_session في محرّر SQL
-- -----------------------------------------------------------------------------
select public.can_redeem_referral() as "هل أستطيع إدخال رمز؟";
