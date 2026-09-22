-- =============================================================================
-- 0055 — الرمز و«من أين سمعت عنّا» عند التسجيل
-- =============================================================================
-- **لماذا في المُشغّل لا في التطبيق؟** `redeem_referral_code` تعمل
-- بـ`auth.uid()`، وهي معدومة لحظة إنشاء الحساب — الجلسة تبدأ بعد تأكيد
-- البريد. فلو تركنا الأمر للتطبيق لوجب أن يتذكّر الرمز بين شاشتين
-- وإقلاعين وربما إعادة تثبيت، ثم يستدعيه بعد أول دخول. **وكل خطوة في
-- هذه السلسلة تُنسى أو تُقاطَع.**
--
-- والمُشغّل يلتقطه من `raw_user_meta_data` لحظة الإنشاء، مرة واحدة، بلا
-- ذاكرة يحملها التطبيق.
--
-- **ونفصل المنطق عن هويّة المستدعي:** `apply_referral_code` تأخذ
-- المدعوّ صراحةً، و`redeem_referral_code` تغلّفها بـ`auth.uid()`.
-- فالحراسات مكتوبة مرة واحدة ويقرؤها البابان — ولا يتباعدان.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) المنطق الداخلي — المدعوّ صريحٌ لا مستنتَج
-- -----------------------------------------------------------------------------
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

  if public.referral_setting('referral_enabled', 1) = 0 then
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

  -- الحارس ٢: جهاز مشترك. **مبهم عمداً** — لا نُعلّم المحتال أين الحارس.
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


-- **الغلاف الذي يستدعيه التطبيق.** لا منطق فيه — الحراسات في الداخل.
create or replace function public.redeem_referral_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if auth.uid() is null then raise exception 'لا توجد جلسة'; end if;
  return public.apply_referral_code(auth.uid(), p_code);
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٢) المُشغّل يلتقط الرمز و«من أين سمعت عنّا»
-- -----------------------------------------------------------------------------
create or replace function public.capture_signup_referral()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, auth
as $fn$
declare
  v_meta jsonb;
  v_code text;
begin
  select raw_user_meta_data into v_meta from auth.users where id = new.id;
  if v_meta is null then return new; end if;

  -- **قناة الوصول قبل الرمز.** تُحفظ دائماً حتى لو لم يكن هناك رمز —
  -- فهي أرخص بحث تسويقي: تخبرك أيّ قناة تجلب فعلاً قبل أن تنفق ديناراً.
  update public.profiles
  set heard_from      = nullif(btrim(v_meta ->> 'heard_from'), ''),
      heard_from_note = nullif(btrim(v_meta ->> 'heard_from_note'), '')
  where id = new.id;

  v_code := nullif(btrim(v_meta ->> 'referral_code'), '');
  if v_code is null then return new; end if;

  -- **الفشل لا يُسقط التسجيل.** رمزٌ خاطئ أو منتهٍ أو مكرّر لا يجوز أن
  -- يمنع رجلاً من إنشاء حسابه — يخسر مكافأة صديقه لا حسابه هو.
  begin
    perform public.apply_referral_code(new.id, v_code);
  exception when others then
    raise notice 'تعذّر تطبيق رمز الدعوة %: %', v_code, sqlerrm;
  end;

  return new;
end;
$fn$;

drop trigger if exists profiles_capture_referral on public.profiles;
create trigger profiles_capture_referral
  after insert on public.profiles
  for each row execute function public.capture_signup_referral();


-- -----------------------------------------------------------------------------
-- ٣) الصلاحيات
-- -----------------------------------------------------------------------------
-- **`apply_referral_code` لا تُمنح لأحد.** تأخذ المدعوّ صراحةً، ومن
-- يستطيع استدعاءها يستطيع نسب أي حساب إلى أي داعٍ. للمُشغّل وحده.
revoke all on function public.apply_referral_code(uuid, text)
  from public, anon, authenticated;

revoke all on function public.redeem_referral_code(text) from public, anon;
grant execute on function public.redeem_referral_code(text) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  coalesce(heard_from, '—') as "من أين سمع",
  count(*)                  as "العدد"
from public.profiles
where role in ('rider', 'driver')
group by 1
order by 2 desc;
