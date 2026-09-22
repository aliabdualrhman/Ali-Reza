-- =============================================================================
-- 0057 — إعدادٌ نصّي عطّل إكمال الرحلات
-- =============================================================================
-- **العطل.** ظهر للسائق عند إنهاء رحلته:
--
--     تعذّر إتمام العملية. (رمز: 22P02)
--
-- و`22P02` هو `invalid_text_representation` — أي أن تحويل نصٍّ إلى رقم
-- فشل. والنصّ هو إعدادُنا نحن:
--
--     ('referral_enabled', 'true')          ← خزّنّاه نصّاً في 0054
--     referral_setting() → value::numeric   ← وقرأناه رقماً
--
-- فـ`'true'::numeric` ترمي، والمُشغّل `try_award_referral` يعمل عند
-- اكتمال **كل** رحلة، فيسقط `complete_trip` كله معه.
--
-- **أي أن إعداداً تسويقياً عطّل قلب المنتج.** والدرس أكبر من السطر:
-- ميزةٌ جانبية يجب ألا تملك القدرة على كسر المسار الأساسي أبداً.
--
-- فنصلح أمرين لا واحداً:
--
--   ١. `referral_setting` تتسامح: قيمةٌ غير رقمية تُعيد الافتراضي ولا
--      ترمي. فلو كتب المدير «نعم» في خانة رقمية غداً، خسر إعداده ولم
--      يخسر رحلات سائقيه.
--
--   ٢. `referral_enabled()` تقرأ النصّ كما يكتبه إنسان: true أو 1 أو
--      نعم أو on — كلها تعني مفعَّلاً.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) قراءة رقمية لا ترمي أبداً
-- -----------------------------------------------------------------------------
create or replace function public.referral_setting(p_key text, p_default numeric)
returns numeric
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_raw text;
begin
  select nullif(btrim(value), '') into v_raw
  from public.public_settings where key = p_key;

  if v_raw is null then return p_default; end if;

  -- **نفحص الشكل قبل التحويل.** `begin … exception` أنظف لكنه يفتح
  -- كتلة فرعية لكل قراءة، وهذه الدالة تُستدعى مرات في كل رحلة.
  if v_raw ~ '^-?[0-9]+(\.[0-9]+)?$' then
    return v_raw::numeric;
  end if;

  return p_default;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) المفتاح المنطقي يُقرأ كما يكتبه إنسان
-- -----------------------------------------------------------------------------
-- **المدير يكتب «true» أو «1» أو «نعم».** ولا يجوز أن يكون الفرق بينها
-- فرقاً بين نظامٍ يعمل ونظامٍ يتعطّل.
create or replace function public.referral_enabled()
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select coalesce(
    (select lower(btrim(value)) in ('true', '1', 'yes', 'on', 'نعم', 'مفعل')
     from public.public_settings where key = 'referral_enabled'),
    true);   -- المفتاح غائب = مفعَّل، فهو حالة التركيب الافتراضية
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) مواضع الاستدعاء الثلاثة
-- -----------------------------------------------------------------------------
-- `try_award_referral` — المُشغّل الذي أسقط `complete_trip`.
create or replace function public.try_award_referral()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_ref      public.referrals;
  v_role     public.user_role;
  v_needed   integer;
  v_done     integer;
  v_amount   numeric(10,2);
  v_expiry   integer;
  v_cap      integer;
  v_rewarded integer;
begin
  if not public.referral_enabled() then
    return new;
  end if;

  for v_ref in
    select * from public.referrals
    where invitee_id in (new.rider_id, new.driver_id)
      and status = 'pending'
  loop
    select role into v_role from public.profiles where id = v_ref.invitee_id;

    -- الحارس ٥: الداعي والمدعوّ في رحلة واحدة.
    if v_ref.inviter_id in (new.rider_id, new.driver_id) then
      update public.referrals
      set status = 'rejected',
          rejection = 'الداعي والمدعوّ طرفا رحلة واحدة'
      where id = v_ref.id;
      continue;
    end if;

    v_needed := public.referral_setting('referral_required_trips', 3)::integer;
    v_done   := public.qualifying_trip_count(v_ref.invitee_id, v_ref.created_at);

    if v_done < v_needed then continue; end if;

    v_cap := public.referral_setting('referral_max_per_user', 2)::integer;
    select count(*) into v_rewarded
    from public.referrals
    where inviter_id = v_ref.inviter_id and status = 'rewarded';

    if v_rewarded >= v_cap then
      update public.referrals
      set status = 'rejected', rejection = 'بلغ الداعي السقف'
      where id = v_ref.id;
      continue;
    end if;

    v_amount := case when v_role = 'driver'
      then public.referral_setting('referral_driver_bonus_iqd', 5000)
      else public.referral_setting('referral_rider_bonus_iqd', 2000)
    end;

    perform set_config('app.bypass_guards', 'on', true);

    if v_role = 'driver' then
      update public.drivers
      set bonus_balance_iqd = bonus_balance_iqd + v_amount
      where id = v_ref.inviter_id;
    else
      v_expiry := public.referral_setting('referral_bonus_expiry_days', 30)::integer;

      insert into public.rider_wallets (id) values (v_ref.inviter_id)
      on conflict (id) do nothing;

      update public.rider_wallets
      set bonus_balance_iqd = bonus_balance_iqd + v_amount,
          bonus_expires_at  = greatest(
            coalesce(bonus_expires_at, now()),
            now() + make_interval(days => v_expiry)),
          updated_at = now()
      where id = v_ref.inviter_id;
    end if;

    update public.referrals
    set status = 'rewarded', reward_iqd = v_amount, rewarded_at = now()
    where id = v_ref.id;

    insert into public.balance_entries
      (user_id, kind, amount_iqd, reason, note)
    values (v_ref.inviter_id, 'bonus', v_amount, 'referral',
            'مكافأة دعوة صديق');

    perform set_config('app.bypass_guards', 'off', true);

    perform public.log_action(
      'referral.reward', 'referrals', v_ref.id::text,
      format('%s دينار — دعوة %s', v_amount::bigint, v_role)
    );
  end loop;

  return new;

-- **حارسٌ أخير على المسار الأساسي.** ما سبق يمنع العطل المعروف، وهذا
-- يمنع ما لا نعرفه: أيّ خطأ في احتساب مكافأةٍ لا يجوز أن يمنع سائقاً من
-- إنهاء رحلته وقبض أجرته. تُفقد المكافأة ويبقى السجلّ `pending` —
-- ونصلحها لاحقاً بلا أن يقف أحد في الشارع.
exception when others then
  raise warning 'تعذّر احتساب مكافأة الدعوة للرحلة %: %', new.id, sqlerrm;
  return new;
end;
$fn$;


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

  v_grace := public.referral_setting('referral_code_grace_days', 7)::integer;
  if v_me.created_at < now() - make_interval(days => v_grace) then
    raise exception 'انتهت مهلة إدخال رمز الدعوة (% أيام من التسجيل)', v_grace;
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

  if exists (
    select 1
    from public.user_devices a
    join public.user_devices b on b.token = a.token
    where a.user_id = v_inviter.id and b.user_id = p_invitee
  ) then
    raise exception 'تعذّر قبول الرمز';
  end if;

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
-- ٤) القيمة تُخزَّن رقماً أيضاً
-- -----------------------------------------------------------------------------
-- الدالة صارت تتسامح، لكنّ تخزين `1` يبقى أوضح لمن يقرأ الجدول.
update public.public_settings
set value = '1', updated_at = now()
where key = 'referral_enabled' and lower(btrim(value)) = 'true';


grant execute on function public.referral_enabled() to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق — يجب أن يعمل بلا خطأ
-- -----------------------------------------------------------------------------
select
  public.referral_enabled()                              as "الدعوة مفعَّلة",
  public.referral_setting('referral_driver_bonus_iqd', 0) as "مكافأة السائق",
  public.referral_setting('referral_required_trips', 0)   as "الرحلات المطلوبة";
