set search_path = public, extensions;

-- =============================================================================
-- 0022 — رموز التعبئة، وطلبات السحب، والتقييم المتبادل
-- =============================================================================
-- الدفع نقدي، فالسائق يقبض الأجرة كاملةً بيده ونقيّد حصة المنصة ديناً
-- عليه. هذا الملف يبني الطريقين اللذين يسدّد بهما ذلك الدين ويقبض بهما
-- ما يفيض له:
--
--   ١) **رمز تعبئة** من ست عشرة خانة — نبيعه للسائق ويدخله في التطبيق.
--   ٢) **طلب سحب** حين يصير رصيده موجباً وكبيراً — ندفعه له زين كاش.
--
-- وأُضيف التقييم المتبادل: كان الراكب وحده يقيّم. السائق يستحق أن يعرف
-- من يركب خلفه، ويستحق الراكب أن يُعرف بحسن تعامله.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- ١) حدّ الدين: من ٢٥٬٠٠٠ إلى ٣٬٠٠٠
-- -----------------------------------------------------------------------------
-- **لماذا خفضٌ بهذا الحجم؟** خمسة وعشرون ألفاً تعني أن سائقاً قد يجمع دين
-- سبع عشرة رحلة قبل أن يُوقفه النظام. مع الدفع النقدي هذا مبلغ حقيقي في
-- جيبه لا في حسابنا، وكلما كبر صعب تحصيله. ثلاثة آلاف = رحلتان تقريباً،
-- فيسدّد باستمرار ولا يتراكم عليه ما يعجزه.
alter table public.pricing_zones
  alter column min_wallet_balance_iqd set default -3000;

update public.pricing_zones
set min_wallet_balance_iqd = -3000
where min_wallet_balance_iqd = -25000;


-- -----------------------------------------------------------------------------
-- ٢) رموز التعبئة
-- -----------------------------------------------------------------------------
-- **لماذا الرمز في جدول مستقل لا عمود في السائق؟** لأنه يُولَّد قبل أن
-- نعرف من سيستعمله. ندير المخزون كما تُدار بطاقات الشحن: نولّد دفعةً،
-- ونرسلها، ونعرف أيها استُهلك ومتى ومن استهلكه.
create table if not exists public.topup_codes (
  id           uuid primary key default gen_random_uuid(),

  -- ست عشرة خانة رقمية بلا فواصل. نخزّنه نصاً لا رقماً: الأصفار البادئة
  -- جزء من الرمز، والرقم يبتلعها.
  code         text not null unique
                 check (code ~ '^[0-9]{16}$'),

  amount_iqd   numeric(12,2) not null check (amount_iqd > 0),

  -- من ولّده ومتى — للتدقيق حين يختلف سائق على رمز
  created_by   uuid references public.profiles(id),
  created_at   timestamptz not null default now(),
  batch_note   text,

  -- من استهلكه ومتى. فارغان = ما زال صالحاً.
  redeemed_by  uuid references public.drivers(id) on delete set null,
  redeemed_at  timestamptz,

  -- إبطال يدوي لرمز ضاع أو أُرسل خطأً
  is_void      boolean not null default false
);

create index if not exists topup_codes_unused_idx
  on public.topup_codes (created_at desc)
  where redeemed_by is null and not is_void;

comment on table public.topup_codes is
  'رموز تعبئة رصيد السائقين. تُولَّد من لوحة التحكم وتُستهلك مرة واحدة.';


-- -----------------------------------------------------------------------------
-- ٣) توليد دفعة رموز — للمشرف وحده
-- -----------------------------------------------------------------------------
create or replace function public.generate_topup_codes(
  p_count  integer,
  p_amount numeric,
  p_note   text default null
)
returns setof public.topup_codes
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  i     integer;
  v_code text;
  v_row public.topup_codes;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  if p_count < 1 or p_count > 200 then
    raise exception 'العدد بين ١ و٢٠٠ في الدفعة الواحدة';
  end if;

  if p_amount <= 0 then
    raise exception 'قيمة الرمز يجب أن تكون أكبر من صفر';
  end if;

  for i in 1..p_count loop
    -- ست عشرة خانة عشوائية. `gen_random_bytes` مصدر تعمية حقيقي لا
    -- `random()` — رمزٌ يُخمَّن هو مالٌ يُسرَق.
    --
    -- الحلقة تعالج التصادم النادر بدل أن تُسقط الدفعة كلها.
    loop
      select string_agg((get_byte(gen_random_bytes(1), 0) % 10)::text, '')
      into v_code
      from generate_series(1, 16);

      exit when not exists (
        select 1 from public.topup_codes where code = v_code
      );
    end loop;

    insert into public.topup_codes (code, amount_iqd, created_by, batch_note)
    values (v_code, p_amount, auth.uid(), p_note)
    returning * into v_row;

    return next v_row;
  end loop;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) استهلاك الرمز — يستدعيه السائق من تطبيقه
-- -----------------------------------------------------------------------------
-- **الدين يُسدَّد أولاً تلقائياً.** سائق عليه ٢٠٠٠ يعبّئ ٥٠٠٠ فيصير رصيده
-- ٣٠٠٠ موجباً. لا نحتاج منطقاً خاصاً لذلك: المحفظة رقم واحد بإشارة،
-- والإضافة تفعلها الحسبة نفسها. نذكرها هنا لأنها سؤال يتكرر.
create or replace function public.redeem_topup_code(p_code text)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_code    public.topup_codes;
  v_balance numeric(12,2);
begin
  if not exists (select 1 from public.drivers where id = auth.uid()) then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  -- تنظيف ما قد يكتبه السائق من مسافات أو شَرَطات
  p_code := regexp_replace(coalesce(p_code, ''), '[^0-9]', '', 'g');

  if p_code !~ '^[0-9]{16}$' then
    raise exception 'الرمز يجب أن يكون ١٦ رقماً';
  end if;

  -- القفل يمنع استهلاك الرمز مرتين من جهازين في اللحظة نفسها
  select * into v_code from public.topup_codes
  where code = p_code
  for update;

  if not found then
    raise exception 'رمز غير صحيح';
  end if;

  if v_code.is_void then
    raise exception 'هذا الرمز مُلغى';
  end if;

  if v_code.redeemed_by is not null then
    raise exception 'هذا الرمز مستعمل من قبل';
  end if;

  update public.topup_codes
  set redeemed_by = auth.uid(), redeemed_at = now()
  where id = v_code.id;

  perform public.post_wallet_transaction(
    p_driver_id   => auth.uid(),
    p_txn_type    => 'topup',
    p_amount_iqd  => v_code.amount_iqd,
    p_description => 'تعبئة برمز'
  );

  select wallet_balance_iqd into v_balance
  from public.drivers where id = auth.uid();

  return v_balance;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) طلبات السحب
-- -----------------------------------------------------------------------------
-- النوع يُنشأ مرة واحدة. `create type` لا يقبل `if not exists`، والملف
-- يجب أن يبقى آمناً للتكرار.
do $do$
begin
  if not exists (select 1 from pg_type where typname = 'payout_status') then
    create type public.payout_status as enum ('pending', 'paid', 'rejected');
  end if;
end
$do$;

create table if not exists public.payout_requests (
  id           uuid primary key default gen_random_uuid(),
  driver_id    uuid not null references public.drivers(id) on delete cascade,

  amount_iqd   numeric(12,2) not null check (amount_iqd > 0),
  status       public.payout_status not null default 'pending',

  -- رقم زين كاش. نلتقطه وقت الطلب لا وقت الدفع: قد يتغيّر هاتف السائق
  -- بين الأمرين، والمبلغ يجب أن يذهب إلى الرقم الذي طلب به.
  zain_phone   text not null,

  requested_at timestamptz not null default now(),
  processed_at timestamptz,
  processed_by uuid references public.profiles(id),
  admin_note   text
);

create index if not exists payout_requests_pending_idx
  on public.payout_requests (requested_at)
  where status = 'pending';

create index if not exists payout_requests_driver_idx
  on public.payout_requests (driver_id, requested_at desc);


-- الحد الأدنى للسحب. **فوق الخمسة آلاف** — أي أن خمسة آلاف بالضبط لا
-- تُسحب. رسوم التحويل وعناء المتابعة اليدوية لا يستحقّان مبلغاً أصغر.
create or replace function public.min_payout_iqd()
returns numeric language sql immutable as $fn$ select 5000::numeric $fn$;


create or replace function public.request_payout(p_amount numeric)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_balance numeric(12,2);
  v_phone   text;
  v_row     public.payout_requests;
begin
  select d.wallet_balance_iqd, p.phone
  into v_balance, v_phone
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.id = auth.uid()
  for update of d;

  if not found then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= public.min_payout_iqd() then
    raise exception 'أقل مبلغ للسحب أكثر من % دينار',
      public.min_payout_iqd()::bigint;
  end if;

  -- **نطرح الطلبات المعلّقة من الرصيد المتاح.** بدون ذلك يطلب السائق
  -- سحب رصيده مرتين قبل أن ندفع له الأولى.
  if p_amount > v_balance - coalesce((
       select sum(amount_iqd) from public.payout_requests
       where driver_id = auth.uid() and status = 'pending'
     ), 0)
  then
    raise exception 'المبلغ أكبر من رصيدك المتاح';
  end if;

  if v_phone is null or v_phone = '' then
    raise exception 'لا يوجد رقم هاتف في حسابك';
  end if;

  insert into public.payout_requests (driver_id, amount_iqd, zain_phone)
  values (auth.uid(), p_amount, v_phone)
  returning * into v_row;

  return v_row;
end;
$fn$;


-- السائق يسحب طلبه ما دام معلّقاً
create or replace function public.cancel_payout_request(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  delete from public.payout_requests
  where id = p_id and driver_id = auth.uid() and status = 'pending';

  if not found then
    raise exception 'الطلب غير موجود أو عُولج بالفعل';
  end if;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) المشرف يعلن الدفع
-- -----------------------------------------------------------------------------
-- **الخصم يحدث هنا لا وقت الطلب.** الطلب نيّة، والدفع فعل. لو خصمنا وقت
-- الطلب لصار رصيد السائق ناقصاً وهو لم يقبض بعد، ولو رفضنا الطلب لوجب
-- ردّ المبلغ — عملية إضافية تخطئ.
create or replace function public.mark_payout_paid(p_id uuid, p_note text default null)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.payout_requests where id = p_id for update;
  if not found then
    raise exception 'الطلب غير موجود';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'هذا الطلب مُعالج بالفعل';
  end if;

  perform public.post_wallet_transaction(
    p_driver_id   => v_row.driver_id,
    p_txn_type    => 'payout',
    p_amount_iqd  => -v_row.amount_iqd,
    p_description => 'سحب إلى زين كاش',
    p_created_by  => auth.uid()
  );

  update public.payout_requests
  set status = 'paid', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;


create or replace function public.reject_payout_request(p_id uuid, p_note text)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.payout_requests;
begin
  if not public.is_admin() then
    raise exception 'للمشرف وحده' using errcode = 'insufficient_privilege';
  end if;

  update public.payout_requests
  set status = 'rejected', processed_at = now(), processed_by = auth.uid(),
      admin_note = p_note
  where id = p_id and status = 'pending'
  returning * into v_row;

  if not found then
    raise exception 'الطلب غير موجود أو مُعالج بالفعل';
  end if;

  return v_row;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٧) التقييم المتبادل
-- -----------------------------------------------------------------------------
-- الراكب له تقييم كذلك. نضعه في `profiles` لا في جدول جديد: هو صفة
-- شخص لا كيان مستقل، والسائق يقرؤه من العرض `trip_party_info`.
alter table public.profiles
  add column if not exists rating_avg   numeric(3,2) not null default 5.00,
  add column if not exists rating_count integer      not null default 0;

-- المُشغّل القديم كان يحدّث `drivers` وحدها. صار يوجّه التقييم إلى الطرف
-- الصحيح: تقييم السائق إلى سجل السائق، وتقييم الراكب إلى ملفه.
create or replace function public.apply_driver_rating()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  -- نرفع علم تجاوز الحُرّاس: هذا تعديل نظامي موثوق، لا من المستخدم.
  perform set_config('app.bypass_guards', 'on', true);

  if exists (select 1 from public.drivers where id = new.ratee_id) then
    update public.drivers
    set rating_avg = round(
          ((rating_avg * rating_count) + new.stars)::numeric / (rating_count + 1),
          2
        ),
        rating_count = rating_count + 1
    where id = new.ratee_id;
  end if;

  -- ملف الشخص يُحدَّث في الحالتين: السائق شخص أيضاً، وتقييمه في ملفه
  -- يجعل مصدراً واحداً يكفي أي شاشة لا تعرف دور من تعرضه.
  update public.profiles
  set rating_avg = round(
        ((rating_avg * rating_count) + new.stars)::numeric / (rating_count + 1),
        2
      ),
      rating_count = rating_count + 1
  where id = new.ratee_id;

  perform set_config('app.bypass_guards', 'off', true);

  return new;
end;
$fn$;

-- نملأ تقييمات الملفات من التقييمات القائمة (كانت تذهب إلى `drivers` فقط)
update public.profiles p
set rating_avg   = coalesce(r.avg_stars, 5.00),
    rating_count = coalesce(r.n, 0)
from (
  select ratee_id, round(avg(stars)::numeric, 2) as avg_stars, count(*) as n
  from public.ratings group by ratee_id
) r
where r.ratee_id = p.id;


-- -----------------------------------------------------------------------------
-- ٨) العرض يكشف تقييم الراكب أيضاً
-- -----------------------------------------------------------------------------
drop view if exists public.trip_party_info;

create view public.trip_party_info
with (security_barrier = true)
as
select
  t.id   as trip_id,
  p.id   as person_id,
  case when p.id = t.driver_id then 'driver' else 'rider' end as party,

  p.full_name,

  -- صورة السائق فقط. صف الراكب يحمل null دائماً.
  case when p.id = t.driver_id then p.avatar_url else null end as avatar_url,

  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end as phone,

  -- من الملف لا من سجل السائق: يعمل للطرفين بمصدر واحد.
  p.rating_avg,
  p.rating_count,

  d.vehicle_type,
  d.vehicle_plate,
  d.vehicle_make,
  d.vehicle_model,
  d.vehicle_color

from public.trips t
join public.profiles p
  on p.id = t.rider_id or p.id = t.driver_id
left join public.drivers d on d.id = p.id
where t.rider_id = auth.uid() or t.driver_id = auth.uid();

comment on view public.trip_party_info is
  'الحقول الآمنة فقط عن طرفي الرحلة. صورة السائق دون الراكب، ولا يكشف '
  'رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;


-- -----------------------------------------------------------------------------
-- ٩) تقييماتي — بلا هويات
-- -----------------------------------------------------------------------------
-- **لماذا دالة لا سياسة قراءة على `ratings`؟** لأن سياسة SELECT تمنح
-- الصف كاملاً بأعمدته، ومنها `rater_id`. فيعرف السائق **من** أعطاه نجمة
-- واحدة — وذلك يفتح باب الانتقام ويجعل الراكب يخشى الصدق.
--
-- هذه تعيد النجوم والتعليق والتاريخ فقط. من قيّم يبقى مجهولاً أبداً.
create or replace function public.my_ratings(p_limit integer default 50)
returns table (
  stars      smallint,
  comment    text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select r.stars, r.comment, r.created_at
  from public.ratings r
  where r.ratee_id = auth.uid()
  order by r.created_at desc
  limit least(coalesce(p_limit, 50), 200);
$fn$;


-- -----------------------------------------------------------------------------
-- ١٠) سياسات الأمان والصلاحيات
-- -----------------------------------------------------------------------------
alter table public.topup_codes     enable row level security;
alter table public.payout_requests enable row level security;

-- الرموز: لا أحد يقرأ الجدول من التطبيق. المشرف يقرؤه بدالة `is_admin`.
--
-- **لماذا لا نسمح للسائق بقراءة رمزه بعد استهلاكه؟** لأن سياسة القراءة
-- تحتاج مطابقة الرمز، والمطابقة تعني القدرة على التخمين صفاً بصف.
drop policy if exists "topup_codes: للمشرف وحده" on public.topup_codes;
create policy "topup_codes: للمشرف وحده"
  on public.topup_codes for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "payouts: السائق يقرأ طلباته" on public.payout_requests;
create policy "payouts: السائق يقرأ طلباته"
  on public.payout_requests for select
  using (driver_id = auth.uid() or public.is_admin());

drop policy if exists "payouts: صلاحية كاملة للمشرف" on public.payout_requests;
create policy "payouts: صلاحية كاملة للمشرف"
  on public.payout_requests for all
  using (public.is_admin()) with check (public.is_admin());

-- الإدراج والحذف يمرّان بالدوال وحدها — لا سياسة للسائق عليهما.

revoke all on function public.generate_topup_codes    from public, anon;
revoke all on function public.redeem_topup_code       from public, anon;
revoke all on function public.request_payout          from public, anon;
revoke all on function public.cancel_payout_request   from public, anon;
revoke all on function public.mark_payout_paid        from public, anon;
revoke all on function public.reject_payout_request   from public, anon;
revoke all on function public.my_ratings              from public, anon;

grant execute on function public.generate_topup_codes(integer, numeric, text)
  to authenticated;
grant execute on function public.redeem_topup_code(text)        to authenticated;
grant execute on function public.request_payout(numeric)        to authenticated;
grant execute on function public.cancel_payout_request(uuid)    to authenticated;
grant execute on function public.mark_payout_paid(uuid, text)   to authenticated;
grant execute on function public.reject_payout_request(uuid, text) to authenticated;
grant execute on function public.my_ratings(integer)            to authenticated;
grant execute on function public.min_payout_iqd()               to authenticated;


-- -----------------------------------------------------------------------------
-- تحقّق
-- -----------------------------------------------------------------------------
select
  (select min_wallet_balance_iqd from public.pricing_zones limit 1)
    as "حدّ الدين",
  public.min_payout_iqd()          as "أقل سحب (أكثر من)",
  (select count(*) from public.topup_codes)     as "رموز مولّدة",
  (select count(*) from public.payout_requests) as "طلبات سحب";
