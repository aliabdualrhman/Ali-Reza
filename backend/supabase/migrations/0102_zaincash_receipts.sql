-- =============================================================================
-- 0102 — رمز التعبئة برقم عملية زين كاش، والرقم يُستعمل مرة واحدة
-- =============================================================================
-- طلب علي:
--
--   «بائع زين كاش» لا يولّد رمزاً إلا برقم عملية (Trans ID) لشراءٍ عبر
--   زين كاش. و«بائع كاش» يولّد بلا رقم. والرقم إن استُعمل مرة يُرفض بعدها
--   — فالسائق الذي يرسل الوصل نفسه مرتين لا يأخذ رصيدين.
--
-- **ورقم العملية يولّد رمزاً واحداً لا دفعة.** لو ولّد عشرة لاستطاع البائع
-- أن يقبض ٥٠٠٠ من سائق ويولّد بوصله عشرة رموز يبيع تسعةً منها لنفسه —
-- وهو بالضبط ما يُراد منعه.
--
-- **والرقم يبقى مستعملاً ولو حُذف رمزه.** السجلّ في جدولٍ مستقل لا يُحذف
-- منه شيء (لا سياسة كتابة، ولا دالة حذف). لو كان عموداً في الرمز وحده
-- لكفى حذفُ الرمز لإعادة فتح الوصل.
--
-- **وما لا نستطيع التحقق منه:** أن المبلغ المكتوب هو ما حُوِّل فعلاً. لا
-- واجهة لزين كاش نسألها. فالمبلغ يُحفظ مع رقم العملية، ويُطابَق مع كشف
-- حساب زين كاش — والرقم الذي لا يظهر في الكشف تزويرٌ باسم بائعه.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الصلاحيتان
-- -----------------------------------------------------------------------------
insert into public.permission_catalog (code, label, sort_order, page) values
  ('topups.generate',
   'بائع كاش — توليد الرموز بلا رقم عملية، وإبطالها', 61, 'رموز التعبئة'),
  ('topups.generate_zaincash',
   'بائع زين كاش — توليد رمزٍ برقم عملية زين كاش فقط', 63, 'رموز التعبئة')
on conflict (code) do update
  set label = excluded.label, sort_order = excluded.sort_order,
      page = excluded.page;


-- -----------------------------------------------------------------------------
-- ٢) سجلّ أرقام العمليات
-- -----------------------------------------------------------------------------
create table if not exists public.topup_receipts (
  trans_id    text primary key,
  amount_iqd  numeric(12,2) not null,
  code_count  integer not null,
  created_by  uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);

comment on table public.topup_receipts is
  'أرقام عمليات زين كاش المستعملة. لا يُحذف منها شيء — حذفُ صفٍّ يعيد فتح الوصل.';

alter table public.topup_receipts enable row level security;

drop policy if exists topup_receipts_read on public.topup_receipts;
create policy topup_receipts_read on public.topup_receipts
  for select to authenticated
  using (public.has_perm('topups.view')
         or public.has_perm('topups.generate')
         or public.has_perm('topups.generate_zaincash'));

alter table public.topup_codes
  add column if not exists trans_id text references public.topup_receipts(trans_id);

create index if not exists topup_codes_trans_id_idx
  on public.topup_codes (trans_id) where trans_id is not null;


-- **رقمٌ واحد بأشكالٍ كثيرة.** «١٢٣٤ ٥٦٧٨» و«12345678» و«1234-5678» عمليةٌ
-- واحدة؛ ولو قارنّا النصّ كما كُتب لمرّ الوصل الثاني بإضافة مسافة.
create or replace function public.normalize_trans_id(p text)
returns text
language sql
immutable
as $fn$
  select nullif(
    upper(regexp_replace(
      translate(coalesce(p, ''),
                '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
                '01234567890123456789'),
      '[^0-9A-Za-z]', '', 'g')),
    '');
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) فحص الرقم قبل التوليد — لتقول اللوحة «مستخدم» وهو يكتبه
-- -----------------------------------------------------------------------------
create or replace function public.check_trans_id(p_trans_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_id  text := public.normalize_trans_id(p_trans_id);
  v_row public.topup_receipts;
  v_by  text;
begin
  if not (public.has_perm('topups.generate')
          or public.has_perm('topups.generate_zaincash')) then
    raise exception 'لا تملك صلاحية توليد الرموز'
      using errcode = 'insufficient_privilege';
  end if;

  if v_id is null then
    return jsonb_build_object('valid', false);
  end if;

  select * into v_row from public.topup_receipts where trans_id = v_id;
  if v_row.trans_id is null then
    return jsonb_build_object('valid', true, 'used', false, 'trans_id', v_id);
  end if;

  select full_name into v_by from public.profiles where id = v_row.created_by;
  return jsonb_build_object(
    'valid', true, 'used', true, 'trans_id', v_id,
    'amount', v_row.amount_iqd, 'by', v_by, 'at', v_row.created_at);
end;
$fn$;

revoke all on function public.check_trans_id(text) from public, anon;
grant execute on function public.check_trans_id(text) to authenticated;


-- -----------------------------------------------------------------------------
-- ٤) التوليد برقم العملية
-- -----------------------------------------------------------------------------
-- **يُحذف التوقيع القديم لا يُستبدل.** إضافة معاملٍ تُنشئ دالةً ثانيةً
-- بالاسم نفسه، فتبقى القديمة — بلا فحص رقم العملية — بابًا مفتوحاً لمن
-- يستدعيها بثلاثة معاملات.
drop function if exists public.generate_topup_codes(integer, numeric, text);

create or replace function public.generate_topup_codes(
  p_count    integer,
  p_amount   numeric,
  p_note     text default null,
  p_trans_id text default null
)
returns setof public.topup_codes
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  i       integer;
  v_code  text;
  v_row   public.topup_codes;
  v_cash  boolean := public.has_perm('topups.generate');
  v_zain  boolean := public.has_perm('topups.generate_zaincash');
  v_trans text    := public.normalize_trans_id(p_trans_id);
  v_used  public.topup_receipts;
  v_by    text;
begin
  if not (v_cash or v_zain) then
    raise exception 'لا تملك صلاحية توليد رموز التعبئة'
      using errcode = 'insufficient_privilege';
  end if;

  if p_count < 1 or p_count > 200 then
    raise exception 'العدد بين ١ و٢٠٠ في الدفعة الواحدة';
  end if;

  if p_amount <= 0 then
    raise exception 'قيمة الرمز يجب أن تكون أكبر من صفر';
  end if;

  -- **بائع زين كاش لا يولّد بلا وصل.**
  if v_trans is null and not v_cash then
    raise exception 'أدخل رقم عملية زين كاش (Trans ID) — لا توليد بدونه';
  end if;

  if v_trans is not null then
    -- رمزٌ واحد لكل وصل — انظر رأس الملف.
    if p_count <> 1 then
      raise exception 'رقم العملية يولّد رمزاً واحداً فقط';
    end if;

    select * into v_used from public.topup_receipts where trans_id = v_trans;
    if v_used.trans_id is not null then
      select full_name into v_by from public.profiles where id = v_used.created_by;
      raise exception 'رقم العملية مستخدم — وُلّد به رمز بقيمة % دينار بواسطة % في %',
        v_used.amount_iqd::bigint, coalesce(v_by, '—'),
        to_char(v_used.created_at at time zone 'Asia/Baghdad', 'YYYY-MM-DD HH24:MI');
    end if;

    -- **المفتاح الأساسي هو القفل الأخير.** بائعان يُدخلان الوصل نفسه في
    -- اللحظة نفسها يمرّان كلاهما من الفحص أعلاه، ويسقط الثاني هنا.
    begin
      insert into public.topup_receipts (trans_id, amount_iqd, code_count, created_by)
      values (v_trans, p_amount * p_count, p_count, auth.uid());
    exception when unique_violation then
      raise exception 'رقم العملية مستخدم — أُدخل للتوّ من جلسةٍ أخرى';
    end;
  end if;

  for i in 1..p_count loop
    -- ست عشرة خانة عشوائية. `gen_random_bytes` مصدر تعمية حقيقي لا
    -- `random()` — رمزٌ يُخمَّن هو مالٌ يُسرَق.
    loop
      select string_agg((get_byte(gen_random_bytes(1), 0) % 10)::text, '')
      into v_code
      from generate_series(1, 16);

      exit when not exists (
        select 1 from public.topup_codes where code = v_code
      );
    end loop;

    insert into public.topup_codes
      (code, amount_iqd, created_by, batch_note, trans_id)
    values (v_code, p_amount, auth.uid(), p_note, v_trans)
    returning * into v_row;

    return next v_row;
  end loop;

  perform public.log_action(
    'topup.generate', 'topup_code', v_trans,
    case when v_trans is null
      then format('ولّد %s رمزاً بقيمة %s دينار للرمز (كاش)',
                  p_count, p_amount::bigint)
      else format('ولّد رمزاً بقيمة %s دينار — زين كاش %s',
                  p_amount::bigint, v_trans)
    end
  );
end;
$fn$;

revoke all on function public.generate_topup_codes(integer, numeric, text, text)
  from public, anon;
grant execute on function public.generate_topup_codes(integer, numeric, text, text)
  to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) الإبطال — لأيّ البائعَين
-- -----------------------------------------------------------------------------
-- **وإبطال رمز زين كاش لا يُعيد فتح وصله.** الرقم يبقى مستعملاً؛ فمن
-- أخطأ في المبلغ يُبطل ويطلب من المالك رمزاً صحيحاً — لا يُعيد الوصل
-- ليولّد عليه ثانيةً.
create or replace function public.admin_void_topup_code(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.topup_codes;
begin
  if not (public.has_perm('topups.generate')
          or public.has_perm('topups.generate_zaincash')) then
    raise exception 'لا تملك صلاحية إبطال رموز التعبئة'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.topup_codes where id = p_id for update;
  if v_row.id is null then
    raise exception 'الرمز غير موجود';
  end if;
  if v_row.redeemed_by is not null then
    raise exception 'هذا الرمز مستهلك — لا يُبطَل.';
  end if;
  if v_row.is_void then
    return;
  end if;

  update public.topup_codes set is_void = true where id = p_id;

  perform public.log_action(
    'topup.void', 'topup_code', v_row.id::text,
    format('أبطل رمزاً بقيمة %s دينار%s', v_row.amount_iqd::bigint,
           case when v_row.trans_id is null then ''
                else ' — زين كاش ' || v_row.trans_id end)
  );
end;
$fn$;


-- **سياسة قراءة الرموز تشمل بائع زين كاش** — يرى ما ولّده.
drop policy if exists topup_codes_read on public.topup_codes;
create policy topup_codes_read on public.topup_codes
  for select to authenticated
  using (
    public.has_perm('topups.view')
    or public.has_perm('topups.generate')
    or public.has_perm('topups.generate_zaincash')
    or public.has_perm('topups.delete')
    or public.has_perm('drivers.view')
  );


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'generate_topup_codes')                    as "دوال التوليد (١ — لا نسخة قديمة)",
  public.normalize_trans_id(' ١٢٣٤-٥٦٧٨ ab ')                   as "تطبيع الرقم (12345678AB)",
  (select count(*) from public.permission_catalog
   where code = 'topups.generate_zaincash')                   as "صلاحية زين كاش (١)";
