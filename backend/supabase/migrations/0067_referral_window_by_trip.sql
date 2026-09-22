-- =============================================================================
-- 0067 — نافذة إدخال الرمز تُغلق بأول رحلة لا بمرور الأيام
-- =============================================================================
-- **مهلة الأيام كانت اختياراً كسولاً.** سبعةُ أيام رقمٌ لا يعني شيئاً:
-- من سجّل ولم يركب بعد أسبوعين ما زال مستخدماً جديداً يستحق أن يُنسب
-- لداعيه؛ ومن ركب عشر رحلات في يومه الأول لم يعد جديداً بحال.
--
-- **والرحلة هي الحدّ الطبيعي.** الدعوة تكافئ من جلب مستخدماً، لا من
-- التقط زبوناً بعد أن صار زبوناً. فمن ركب مرة واحدة أثبت أنه وجد
-- التطبيق بنفسه.
--
-- **وهي أيضاً أمتن ضد الاحتيال:** الأيام تُنتظر، والرحلة لا تُسترجع.
-- فمن أراد أن يجمع رمزاً بعد أن استقرّ في التطبيق لا يستطيع.
--
-- ونُبقي `referral_code_grace_days` في الإعدادات ولا نقرؤه — حذفه
-- يكسر لوحةً تعرضه، وقراءته تُعيد الشرط الذي ألغيناه.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) هل يستطيع إدخال رمز الآن؟
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
  v_role  public.user_role;
  v_trips integer;
begin
  if v_uid is null then
    return jsonb_build_object('can', false, 'reason', 'no_session');
  end if;

  if not public.referral_enabled() then
    return jsonb_build_object('can', false, 'reason', 'disabled');
  end if;

  select role into v_role from public.profiles where id = v_uid;
  if v_role = 'admin' then
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

  return jsonb_build_object('can', true);
end;
$fn$;

revoke all on function public.can_redeem_referral() from public, anon;
grant execute on function public.can_redeem_referral() to authenticated;


-- -----------------------------------------------------------------------------
-- ٢) الحارس نفسه في مسار التطبيق
-- -----------------------------------------------------------------------------
-- **إخفاء الزرّ ليس حماية.** من يستدعي الدالة مباشرةً يتجاوز الواجهة،
-- فالقاعدة هي التي تمنع لا الشاشة.
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
  v_cap      integer;
  v_rewarded integer;
  v_trips    integer;
begin
  if v_code = '' then
    raise exception 'اكتب رمز الدعوة';
  end if;

  if not public.referral_enabled() then
    raise exception 'نظام الدعوة متوقّف حالياً';
  end if;

  select * into v_me from public.profiles where id = p_invitee;
  if v_me.id is null then raise exception 'حساب غير موجود'; end if;

  if exists (select 1 from public.referrals where invitee_id = p_invitee) then
    raise exception 'أدخلتَ رمز دعوة من قبل';
  end if;

  -- **الرحلة تُغلق النافذة، لا مرور الأيام.** انظر رأس الملف.
  select count(*) into v_trips
  from public.trips
  where rider_id = p_invitee or driver_id = p_invitee;

  if v_trips > 0 then
    raise exception
      'رمز الدعوة يُدخَل قبل أول رحلة. حسابك تجاوز هذه المرحلة.';
  end if;

  select * into v_inviter from public.profiles where referral_code = v_code;
  if v_inviter.id is null then
    raise exception 'رمز الدعوة غير صحيح';
  end if;

  if v_inviter.id = p_invitee then
    raise exception 'لا يمكنك استعمال رمزك';
  end if;

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
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select public.can_redeem_referral() as "هل أستطيع إدخال رمز؟";
