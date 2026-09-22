-- =============================================================================
-- 0051 — رصيد الهدية منفصلٌ عن الرصيد الفعلي
-- =============================================================================
-- **الأساس الذي يقوم عليه نظام الدعوة كله.**
--
-- سنمنح السائقين رصيداً مجانياً — على دعوة صديق، أو تحفيزاً من المدير.
-- ولو أضفناه إلى `wallet_balance_iqd` لطلب السائق سحبه نقداً عبر
-- `request_payout`، فتتحوّل الهدية إلى نزيف نقدي مباشر من الخزينة.
--
-- **والمالان مختلفان في طبيعتهما لا في مصدرهما وحده:**
--
--   • **الفعلي** — ربحُ عملٍ، أو تعبئةٌ دفع ثمنها، أو تعويض. **ماله هو**،
--     ويسحبه متى شاء.
--
--   • **الهدية** — منحةٌ منّا لغرض: أن يستعملها في المنصة فيبقى فيها.
--     تُنفق على العمولة ولا تخرج نقداً أبداً.
--
-- **ولماذا عمودٌ ثانٍ لا `is_bonus` على الحركات؟** لأن السحب يقرأ رصيداً
-- واحداً في استعلامٍ واحد. وحسابُه بجمع حركاتٍ مصنَّفة يعني أن كل خطأ في
-- تصنيف حركةٍ واحدة يفتح باب السحب. العمود الصريح يجعل الخطأ مستحيلاً
-- لا مستبعَداً.
--
-- **وللمدير أن يخصم من الاثنين** — عقوبةً أو تصحيحاً. المنع على السائق
-- في السحب، لا على المدير في الإدارة.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) العمود
-- -----------------------------------------------------------------------------
alter table public.drivers
  add column if not exists bonus_balance_iqd numeric(12,2) not null default 0;

-- **لا يهبط تحت الصفر أبداً.** الرصيد الفعلي يسالب عمداً — فهو دَين
-- عمولات على السائق. أما الهدية فمنحة: وسالبُها يعني أننا نطالبه بردّ
-- ما وهبناه.
alter table public.drivers
  drop constraint if exists drivers_bonus_not_negative;
alter table public.drivers
  add constraint drivers_bonus_not_negative
  check (bonus_balance_iqd >= 0);

comment on column public.drivers.bonus_balance_iqd is
  'رصيد هدية — يُنفق على العمولة ولا يُسحب نقداً. منفصل عن wallet_balance_iqd عمداً.';


-- -----------------------------------------------------------------------------
-- ٢) سجلّ الحركات
-- -----------------------------------------------------------------------------
-- **بلا سجلّ لا يُصدَّق رقم.** حين يسأل سائق «من أين جاءت هذه الخمسة
-- آلاف؟» أو «لماذا نقص رصيدي؟» يجب أن يكون الجواب سطراً مكتوباً لا
-- ذاكرة موظف. وهو أيضاً أثرُ التدقيق الوحيد على المنح: من منح، ومتى،
-- ولماذا.
create table if not exists public.balance_entries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,

  -- 'real' مالٌ يُسحب · 'bonus' هديةٌ تُنفق
  kind        text not null check (kind in ('real', 'bonus')),

  -- موجب = إضافة · سالب = خصم
  amount_iqd  numeric(12,2) not null,

  -- 'referral' دعوة · 'admin' حقن أو خصم يدوي · 'trip' أجرة أو عمولة
  -- 'topup' تعبئة · 'payout' سحب · 'expiry' انتهاء صلاحية هدية
  reason      text not null,

  note        text,
  trip_id     uuid references public.trips(id) on delete set null,

  -- من نفّذ الحركة. فارغ = النظام (رحلة، انتهاء صلاحية).
  actor_id    uuid references public.profiles(id) on delete set null,

  created_at  timestamptz not null default now()
);

create index if not exists balance_entries_user_idx
  on public.balance_entries (user_id, created_at desc);

create index if not exists balance_entries_reason_idx
  on public.balance_entries (reason, created_at desc);

comment on table public.balance_entries is
  'كل حركة رصيد — فعليّها وهديّتها. سجلٌّ لا يُحذف منه.';

alter table public.balance_entries enable row level security;

-- صاحب الحساب يقرأ حركاته. **ولا يكتب أحد من التطبيق** — الكتابة
-- بالدوال وحدها، وإلا كتب كلٌّ رصيده بيده.
drop policy if exists balance_entries_own_read on public.balance_entries;
create policy balance_entries_own_read on public.balance_entries
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());


-- -----------------------------------------------------------------------------
-- ٣) السحب يقرأ الفعلي وحده
-- -----------------------------------------------------------------------------
-- **هذا هو جوهر الملف.** كانت الدالة تقرأ `wallet_balance_iqd` وستبقى —
-- لكنّ الهدية لن تدخلها أبداً، فالفصل في العمود يكفي.
--
-- ونعيد كتابتها مع ذلك لسببين: نُضيف حارساً صريحاً يمنع أي التباس
-- مستقبلي، ونجعل رسالة الخطأ تشرح للسائق أن هديته ليست قابلة للسحب —
-- فمن يرى رصيدين ويستطيع سحب أحدهما يحتاج أن يُقال له لماذا.
create or replace function public.request_payout(p_amount numeric)
returns public.payout_requests
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_balance   numeric(12,2);
  v_bonus     numeric(12,2);
  v_pending   numeric(12,2);
  v_available numeric(12,2);
  v_phone     text;
  v_row       public.payout_requests;
begin
  select d.wallet_balance_iqd, d.bonus_balance_iqd, p.phone
  into v_balance, v_bonus, v_phone
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.id = auth.uid()
  for update of d;

  if not found then
    raise exception 'هذه الخدمة للسائقين' using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'أدخل مبلغاً صحيحاً';
  end if;

  select coalesce(sum(amount_iqd), 0) into v_pending
  from public.payout_requests
  where driver_id = auth.uid() and status = 'pending';

  -- **`v_bonus` لا يدخل الحساب.** مذكورٌ هنا ليقرأه من يعدّل الدالة
  -- لاحقاً فيعرف أنه استُبعد قصداً لا سهواً.
  v_available := v_balance - v_pending - public.payout_reserve_iqd();

  if v_available <= 0 then
    if v_bonus > 0 then
      raise exception
        'يجب أن يبقى % دينار في رصيدك. ورصيد الهدية (%) يُنفق على '
        'العمولة ولا يُسحب نقداً.',
        public.payout_reserve_iqd()::bigint, v_bonus::bigint;
    end if;
    raise exception 'يجب أن يبقى % دينار في رصيدك. لا يوجد مبلغ متاح للسحب',
      public.payout_reserve_iqd()::bigint;
  end if;

  if p_amount > v_available then
    raise exception 'أقصى ما يمكن سحبه الآن % دينار — يجب أن يبقى % في رصيدك',
      v_available::bigint, public.payout_reserve_iqd()::bigint;
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


-- -----------------------------------------------------------------------------
-- ٤) المدير يضيف ويخصم — من أيّ الرصيدين
-- -----------------------------------------------------------------------------
-- **يسأل عن النوع ولا يخمّنه.** حقنٌ بلا تحديد يجعل كل مبلغ قابلاً
-- للسحب افتراضاً — وهو الخطأ الذي يُفقد المال بلا أن يلاحظه أحد.
create or replace function public.admin_adjust_balance(
  p_driver_id uuid,
  p_amount    numeric,       -- موجب إضافة · سالب خصم
  p_kind      text,          -- 'real' أو 'bonus'
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_name  text;
  v_real  numeric(12,2);
  v_bonus numeric(12,2);
begin
  if not public.has_perm('wallets.adjust') then
    raise exception 'لا تملك صلاحية تعديل الأرصدة'
      using errcode = 'insufficient_privilege';
  end if;

  if p_kind not in ('real', 'bonus') then
    raise exception 'النوع يجب أن يكون real أو bonus';
  end if;

  if p_amount is null or p_amount = 0 then
    raise exception 'أدخل مبلغاً غير صفري';
  end if;

  -- **السبب مطلوب لا اختياري.** حركةٌ بلا سبب مكتوب تصير لغزاً بعد شهر:
  -- لا المدير يتذكّر، ولا السائق يُقنَع، ولا التدقيق يفيد.
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'اكتب سبب التعديل';
  end if;

  select p.full_name into v_name
  from public.profiles p where p.id = p_driver_id and p.role = 'driver';

  if v_name is null then
    raise exception 'هذا الحساب ليس سائقاً';
  end if;

  if p_kind = 'real' then
    update public.drivers
    set wallet_balance_iqd = wallet_balance_iqd + p_amount
    where id = p_driver_id;
  else
    -- **الخصم لا يهبط تحت الصفر.** لو خصم المدير ألفاً من هديةٍ قدرها
    -- خمسمئة، لصار الرصيد سالباً — أي دَيناً على السائق لهديةٍ وهبناها.
    -- نخصم ما يوجد ونكتفي.
    update public.drivers
    set bonus_balance_iqd = greatest(0, bonus_balance_iqd + p_amount)
    where id = p_driver_id;
  end if;

  select wallet_balance_iqd, bonus_balance_iqd
  into v_real, v_bonus
  from public.drivers where id = p_driver_id;

  insert into public.balance_entries
    (user_id, kind, amount_iqd, reason, note, actor_id)
  values
    (p_driver_id, p_kind, p_amount, 'admin', btrim(p_note), auth.uid());

  perform public.log_action(
    'wallet.adjust', 'drivers', p_driver_id::text,
    format('%s — %s %s دينار (%s) — %s',
           v_name,
           case when p_amount > 0 then 'إضافة' else 'خصم' end,
           abs(p_amount)::bigint,
           case when p_kind = 'real' then 'فعلي' else 'هدية' end,
           btrim(p_note))
  );

  return jsonb_build_object(
    'real',  v_real,
    'bonus', v_bonus
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٥) الصلاحية
-- -----------------------------------------------------------------------------
create or replace function public.known_permissions()
returns table (code text, label text)
language sql
immutable
as $fn$
  values
    ('drivers.review',  'مراجعة السائقين واعتمادهم'),
    ('drivers.view',    'عرض السائقين وأرصدتهم'),
    ('riders.view',     'عرض الركّاب وبياناتهم'),
    ('profiles.edit',   'تعديل بيانات المستخدمين مباشرةً'),
    ('accounts.create', 'إنشاء حسابات جديدة من اللوحة'),
    ('accounts.delete', 'حذف حسابات المستخدمين'),
    ('wallets.adjust',  'إضافة الأرصدة وخصمها'),
    ('trips.view',      'عرض الرحلات'),
    ('trips.cancel',    'إلغاء رحلة جارية'),
    ('topups.generate', 'توليد رموز التعبئة'),
    ('topups.view',     'عرض رموز التعبئة'),
    ('payouts.process', 'معالجة طلبات السحب'),
    ('coupons.manage',  'إنشاء الكوبونات وإيقافها'),
    ('settings.manage', 'تعديل الإعدادات العامة')
$fn$;

update public.profiles
set staff_permissions = array(
      select distinct unnest(staff_permissions || array['wallets.adjust'])
    )
where role = 'admin'
  and lower(email) = 'ali.alkawary@gmail.com'
  and not ('wallets.adjust' = any(staff_permissions));


-- -----------------------------------------------------------------------------
-- ٦) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function
  public.admin_adjust_balance(uuid, numeric, text, text) from public, anon;
grant execute on function
  public.admin_adjust_balance(uuid, numeric, text, text) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  count(*)                                        as "سائقون",
  coalesce(sum(wallet_balance_iqd), 0)::bigint    as "مجموع الفعلي",
  coalesce(sum(bonus_balance_iqd),  0)::bigint    as "مجموع الهدية"
from public.drivers;
