-- =============================================================================
-- 0099 — صلاحيات رموز التعبئة تُفحص في القاعدة لا في اللوحة وحدها
-- =============================================================================
-- طلب علي: «فلان يولّد الرموز ولا يحذفها حتى المستهلكة، ويُكتب من ولّد
-- كل رمز، وشحن الرصيد من صفحة السائق صلاحيةٌ تُمنح أو تُمنع».
--
-- وفحصُ ما هو موجود كشف أن الصلاحيات **كانت أسماءً في قائمة لا أقفالاً**:
--
--   ١) `generate_topup_codes` تفحص `is_admin()` وحدها. فكل موظفٍ في
--      اللوحة **يصنع مالاً** ولو نُزعت عنه «توليد رموز التعبئة» —
--      مربّع الاختيار لم يكن يمنع شيئاً.
--
--   ٢) الحذف (واحداً وجماعياً) كذلك: `is_admin()` وحدها.
--
--   ٣) وسياسة الجدول `for all using (is_admin())` — **أيّ مشرفٍ يُدرج
--      رمزاً بأي مبلغ مباشرةً عبر PostgREST**، متجاوزاً الدوال كلّها
--      وسجلّها. والإبطال من اللوحة كان تعديلاً مباشراً من هذا الباب.
--
-- فالجدول يُقرأ فقط، والكتابة كلها بدوالٍ تفحص الصلاحية وتُسجِّل.
--
-- **ولا يتأثّر المالك بشيء.** `has_perm` تمرّر `is_owner()` قبل كل فحص.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الصلاحيات في القائمة
-- -----------------------------------------------------------------------------
insert into public.permission_catalog (code, label, sort_order) values
  ('topups.delete', 'حذف رموز التعبئة (المستهلكة والملغاة)', 105)
on conflict (code) do update set label = excluded.label,
                                 sort_order = excluded.sort_order;

-- **التسمية تقول أين.** «إضافة الأرصدة وخصمها» لم تكن تقول إنها هي زرّ
-- الشحن في صفحة السائق — فيبحث المدير عن صلاحيةٍ موجودة ويظنّها ناقصة.
update public.permission_catalog
set label = 'شحن الرصيد وخصمه مباشرةً (من صفحة السائق والراكب)'
where code = 'wallets.adjust';

-- والتوليد يشمل الإبطال: من يُصدر الرمز يستطيع إيقافه قبل أن يُستعمل.
update public.permission_catalog
set label = 'توليد رموز التعبئة وإبطال غير المستعمل منها'
where code = 'topups.generate';


-- -----------------------------------------------------------------------------
-- ٢) صلاحياتي — لتُخفي اللوحة ما لا يملكه صاحبها
-- -----------------------------------------------------------------------------
-- **القاعدة هي القفل، واللوحة لا تُخفي إلا ما سيُرفض.** زرٌّ يُضغط فيردّ
-- «غير مصرّح» أسوأ من زرٍّ لا يظهر.
create or replace function public.my_permissions()
returns text[]
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select case
    when public.is_owner() then
      (select coalesce(array_agg(code order by code), '{}')
       from public.permission_catalog)
    else
      coalesce((select staff_permissions from public.profiles
                where id = auth.uid() and role = 'admin'), '{}')
  end;
$fn$;

revoke all on function public.my_permissions() from public, anon;
grant execute on function public.my_permissions() to authenticated;


-- -----------------------------------------------------------------------------
-- ٣) التوليد — بصلاحيته لا بدور المشرف
-- -----------------------------------------------------------------------------
-- منسوخةٌ من التعريف الحيّ في القاعدة (pg_get_functiondef)، والتغيير
-- سطر الفحص وحده.
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
  i      integer;
  v_code text;
  v_row  public.topup_codes;
begin
  if not public.has_perm('topups.generate') then
    raise exception 'لا تملك صلاحية توليد رموز التعبئة'
      using errcode = 'insufficient_privilege';
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
    loop
      select string_agg((get_byte(gen_random_bytes(1), 0) % 10)::text, '')
      into v_code
      from generate_series(1, 16);

      exit when not exists (
        select 1 from public.topup_codes where code = v_code
      );
    end loop;

    -- `created_by` هو من ولّد — واللوحة تعرض اسمه أمام كل رمز.
    insert into public.topup_codes (code, amount_iqd, created_by, batch_note)
    values (v_code, p_amount, auth.uid(), p_note)
    returning * into v_row;

    return next v_row;
  end loop;

  perform public.log_action(
    'topup.generate', 'topup_code', null,
    format('ولّد %s رمزاً بقيمة %s دينار للرمز', p_count, p_amount::bigint)
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) الإبطال — دالةٌ بدل التعديل المباشر
-- -----------------------------------------------------------------------------
create or replace function public.admin_void_topup_code(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.topup_codes;
begin
  if not public.has_perm('topups.generate') then
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
    format('أبطل رمزاً بقيمة %s دينار', v_row.amount_iqd::bigint)
  );
end;
$fn$;

revoke all on function public.admin_void_topup_code(uuid) from public, anon;
grant execute on function public.admin_void_topup_code(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- ٥) الحذف — بصلاحيته
-- -----------------------------------------------------------------------------
create or replace function public.admin_delete_topup_code(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row public.topup_codes;
begin
  if not public.has_perm('topups.delete') then
    raise exception 'لا تملك صلاحية حذف رموز التعبئة'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row from public.topup_codes where id = p_id;
  if v_row.id is null then
    raise exception 'الرمز غير موجود';
  end if;

  if v_row.redeemed_by is null and not v_row.is_void then
    raise exception 'هذا الرمز ما زال صالحاً. أبطله أولاً ثم احذفه.';
  end if;

  -- **يُسجَّل قبل الحذف لا بعده.** بعده لا يبقى صفٌّ نقرأ منه المبلغ.
  perform public.log_action(
    'topup.delete', 'topup_code', v_row.id::text,
    format('حذف رمز %s بقيمة %s دينار',
           case when v_row.is_void then 'مُلغى' else 'مستهلك' end,
           v_row.amount_iqd::bigint)
  );

  delete from public.topup_codes where id = p_id;
end;
$fn$;

create or replace function public.admin_purge_topup_codes(
  p_used boolean default true,
  p_void boolean default true
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_count integer;
begin
  if not public.has_perm('topups.delete') then
    raise exception 'لا تملك صلاحية حذف رموز التعبئة'
      using errcode = 'insufficient_privilege';
  end if;

  if not p_used and not p_void then
    return 0;
  end if;

  with gone as (
    delete from public.topup_codes
    where (p_used and redeemed_by is not null)
       or (p_void and is_void)
    returning 1
  )
  select count(*) into v_count from gone;

  if v_count > 0 then
    perform public.log_action(
      'topup.purge', 'topup_code', null,
      format('حذف %s رمزاً (%s)', v_count,
             case
               when p_used and p_void then 'مستهلكة وملغاة'
               when p_used            then 'مستهلكة'
               else                        'ملغاة'
             end)
    );
  end if;

  return v_count;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٦) الجدول يُقرأ ولا يُكتب مباشرةً
-- -----------------------------------------------------------------------------
-- الكتابة كلها بدوالٍ `security definer` — التوليد، والاستهلاك، والإبطال،
-- والحذف — فلا تحتاج سياسة كتابة. وغيابها يعني أن PostgREST يرفض كل
-- إدراجٍ وتعديلٍ وحذفٍ مباشر، من أي أحد.
--
-- **والقراءة لمن يحتاجها:** عرض الرموز، ومن يولّد (يرى ما ولّد)، ومن
-- يحذف (يرى ما يحذف)، ومن يرى السائقين (صفحة السائق تعرض ما عبّأه).
drop policy if exists "topup_codes: للمشرف وحده" on public.topup_codes;
drop policy if exists topup_codes_read on public.topup_codes;
create policy topup_codes_read on public.topup_codes
  for select to authenticated
  using (
    public.has_perm('topups.view')
    or public.has_perm('topups.generate')
    or public.has_perm('topups.delete')
    or public.has_perm('drivers.view')
  );


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.permission_catalog
   where code = 'topups.delete')                              as "صلاحية الحذف (١)",
  (select count(*) from pg_policies
   where tablename = 'topup_codes' and cmd <> 'SELECT')       as "سياسات كتابة (٠)",
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('generate_topup_codes', 'admin_delete_topup_code',
                     'admin_purge_topup_codes', 'admin_void_topup_code')
     and prosrc like '%has_perm(%')                          as "دوال تفحص الصلاحية (٤)";
