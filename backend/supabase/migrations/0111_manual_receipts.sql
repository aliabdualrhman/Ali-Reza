-- =============================================================================
-- 0111 — وصل زين كاش يدوياً، وحذفه بصلاحيةٍ خاصّة
-- =============================================================================
-- طلب علي: «زرّ إضافة وصل زين كاش يدوياً، وإمكانية المسح للمدير ولمن
-- يخوّله وحدهم».
--
-- **ولماذا وصلٌ بلا رمز؟** لأن المال يصل بطرقٍ لا تمرّ برمزٍ: تُشحن محفظة
-- سائقٍ مباشرةً من صفحته، أو يسدّد دَينه بتحويلٍ على زين كاش. والوصل
-- حينها لا يُسجَّل في مكان — فيعود السائق بالوصل نفسه بعد أسبوع.
--
-- **والحذف بابٌ خطير، فله صلاحيته وحده.** حذف الوصل **يعيده قابلاً
-- للاستعمال**؛ وهذا كل ما يحتاجه موظفٌ سيّئ النية: يسجّل الوصل، يشحن،
-- يحذف السجلّ، ثم يشحن به ثانيةً. فلا تُعطَ هذه الصلاحية إلا لمن تثق به
-- كما تثق بنفسك. وكل حذفٍ يُسجَّل باسم فاعله ولا يُمحى.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الصلاحية
-- -----------------------------------------------------------------------------
insert into public.permission_catalog (code, label, sort_order, page) values
  ('topups.receipt_delete',
   'حذف وصل زين كاش — يعيده قابلاً للاستعمال', 64, 'رموز التعبئة')
on conflict (code) do update
  set label = excluded.label, sort_order = excluded.sort_order,
      page = excluded.page;

-- سببُ التسجيل اليدويّ يبقى مع الوصل: «شحن مباشر لفلان»، «تسديد دَين».
alter table public.topup_receipts
  add column if not exists note text;


-- -----------------------------------------------------------------------------
-- ٢) تسجيل وصلٍ يدوياً
-- -----------------------------------------------------------------------------
create or replace function public.admin_add_receipt(
  p_trans_id text,
  p_amount   numeric,
  p_note     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_id   text := public.normalize_trans_id(p_trans_id);
  v_used public.topup_receipts;
  v_by   text;
begin
  if not (public.has_perm('topups.generate')
          or public.has_perm('topups.generate_zaincash')) then
    raise exception 'لا تملك صلاحية تسجيل الوصولات'
      using errcode = 'insufficient_privilege';
  end if;

  if v_id is null then
    raise exception 'اكتب رقم عملية زين كاش';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'اكتب المبلغ المحوَّل';
  end if;

  select * into v_used from public.topup_receipts where trans_id = v_id;
  if v_used.trans_id is not null then
    select full_name into v_by from public.profiles where id = v_used.created_by;
    raise exception 'رقم العملية مستخدم — سُجّل بقيمة % دينار بواسطة % في %',
      v_used.amount_iqd::bigint, coalesce(v_by, '—'),
      to_char(v_used.created_at at time zone 'Asia/Baghdad',
              'YYYY-MM-DD HH24:MI');
  end if;

  -- **`code_count = 0`** يميّز الوصل اليدويّ: مالٌ وصل بلا رمزٍ وُلّد له.
  insert into public.topup_receipts
    (trans_id, amount_iqd, code_count, created_by, note)
  values (v_id, p_amount, 0, auth.uid(),
          nullif(btrim(coalesce(p_note, '')), ''));

  perform public.log_action(
    'receipt.add', 'topup_receipt', v_id,
    format('سجّل وصل زين كاش %s بقيمة %s دينار%s',
           v_id, p_amount::bigint,
           case when coalesce(btrim(p_note), '') = '' then ''
                else ' — ' || btrim(p_note) end)
  );

  return jsonb_build_object('trans_id', v_id, 'amount', p_amount);
end;
$fn$;

revoke all on function public.admin_add_receipt(text, numeric, text)
  from public, anon;
grant execute on function public.admin_add_receipt(text, numeric, text)
  to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) حذف وصل
-- -----------------------------------------------------------------------------
create or replace function public.admin_delete_receipt(p_trans_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_id  text := public.normalize_trans_id(p_trans_id);
  v_row public.topup_receipts;
  v_n   integer;
begin
  if not public.has_perm('topups.receipt_delete') then
    raise exception 'لا تملك صلاحية حذف الوصولات'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.topup_receipts where trans_id = v_id;
  if v_row.trans_id is null then
    raise exception 'الوصل غير موجود';
  end if;

  -- **الرمز المولَّد منه يمنع الحذف.** لو حذفناه لأشار الرمز إلى وصلٍ
  -- لا وجود له — والقاعدة ترفض ذلك أصلاً بمفتاحها الأجنبي. نقولها
  -- بالعربية بدل خطأٍ تقنيّ لا يُفهم.
  select count(*) into v_n
  from public.topup_codes where trans_id = v_id;
  if v_n > 0 then
    raise exception
      'وُلّد من هذا الوصل % رمزاً. احذف الرمز أولاً إن أردت حذف الوصل.', v_n;
  end if;

  -- **يُسجَّل قبل الحذف.** بعده لا يبقى صفٌّ نقرأ منه المبلغ.
  perform public.log_action(
    'receipt.delete', 'topup_receipt', v_id,
    format('حذف وصل زين كاش %s بقيمة %s دينار — صار قابلاً للاستعمال ثانيةً',
           v_id, v_row.amount_iqd::bigint)
  );

  delete from public.topup_receipts where trans_id = v_id;
end;
$fn$;

revoke all on function public.admin_delete_receipt(text) from public, anon;
grant execute on function public.admin_delete_receipt(text) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('admin_add_receipt', 'admin_delete_receipt'))   as "الدالتان (٢)",
  (select count(*) from public.permission_catalog
     where code = 'topups.receipt_delete')                           as "صلاحية الحذف (١)",
  (select count(*) from information_schema.columns
     where table_schema = 'public' and table_name = 'topup_receipts'
       and column_name = 'note')                                     as "عمود السبب (١)";
