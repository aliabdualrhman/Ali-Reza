-- =============================================================================
-- 0043 — المدير يستبدل الصورة الشخصية والوثائق
-- =============================================================================
-- **الحاجة.** يتصل سائق: «صورة بطاقتي مقلوبة» أو «رفعت صورة الدراجة
-- الخطأ». والمدير يرى الصورة أمامه ولا يملك إلا أن يرفض الوثيقة ويطلب
-- منه إعادة الرفع — فيبقى السائق معطّلاً حتى يتفرّغ ويعيد المحاولة،
-- وربما يئس فذهب إلى منافس.
--
-- **العائق.** سياسة التخزين في 0010 تشترط أن يكون رافع الملف صاحب
-- المجلد:
--
--     (storage.foldername(name))[1] = auth.uid()::text
--
-- فالمدير يقرأ وثائق الجميع (`is_admin()` في سياسة القراءة) ولا يكتب
-- لأحد. وهذا صواب في أصله — لكنه يمنع الإصلاح كما يمنع العبث.
--
-- **ما يضيفه هذا الملف:**
--
--   • سياسة تخزين تسمح لمن يملك `profiles.edit` بالكتابة في أي مجلد
--   • `admin_set_document` — تسجّل الوثيقة الجديدة وتُسجَّل في التدقيق
--
-- **ولماذا لا نكتفي بالسياسة؟** لأن رفع الملف نصف العمل: الصف في
-- `user_documents` هو ما يراه المدير ويُبنى عليه الاعتماد. والدالة
-- تربط الاثنين وتترك أثراً.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) سياسة التخزين — كتابة المدير في مجلدات المستخدمين
-- -----------------------------------------------------------------------------
-- **مقيّدة بـ`profiles.edit` لا بـ`is_admin()`.** موظف الدعم الذي يرى
-- الوثائق ليجيب المتصل لا ينبغي أن يستطيع استبدال بطاقة سائق معتمَد.
-- الصلاحية نفسها التي تحكم تعديل الاسم تحكم استبدال الوثيقة.
drop policy if exists "documents: كتابة المدير" on storage.objects;
create policy "documents: كتابة المدير"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'documents'
    and public.has_perm('profiles.edit')
  );

drop policy if exists "documents: تحديث المدير" on storage.objects;
create policy "documents: تحديث المدير"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'documents'
    and public.has_perm('profiles.edit')
  )
  with check (
    bucket_id = 'documents'
    and public.has_perm('profiles.edit')
  );


-- -----------------------------------------------------------------------------
-- ٢) تسجيل وثيقة بديلة
-- -----------------------------------------------------------------------------
-- **تستبدل ولا تكرّر.** لو أدرجنا صفاً جديداً في كل مرة لتراكمت خمس
-- صور بطاقة لسائق واحد، ولا يعرف المدير أيّها المعتمَدة. نحدّث الصفّ
-- القائم إن وُجد.
--
-- **واستثناء `vehicle_photo`:** السائق يرفع عدة صور لمركبته (أمام،
-- خلف، لوحة)، فتعدّدها مقصود. لذا نضيف لا نستبدل في هذا النوع وحده.
--
-- **والحالة تعود `pending`:** وثيقة استبدلها المدير لم يراجعها أحد
-- بعد. اعتمادها التلقائي يجعل الاستبدال طريقاً لتمرير ما لم يُفحص.
create or replace function public.admin_set_document(
  p_user_id      uuid,
  p_doc_type     public.document_type,
  p_storage_path text,
  p_notes        text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_id       uuid;
  v_name     text;
  v_replaced boolean := false;
begin
  if not public.has_perm('profiles.edit') then
    raise exception 'لا تملك صلاحية تعديل بيانات المستخدمين'
      using errcode = 'insufficient_privilege';
  end if;

  select full_name into v_name from public.profiles where id = p_user_id;
  if v_name is null then raise exception 'المستخدم غير موجود'; end if;

  if coalesce(trim(p_storage_path), '') = '' then
    raise exception 'مسار الملف مفقود';
  end if;

  -- **الملف يجب أن يكون مرفوعاً قبل النداء.** مسارٌ لا ملف خلفه يُنتج
  -- وثيقةً تظهر في اللوحة وتفتح على فراغ — وهو أسوأ من غيابها.
  if not exists (
    select 1 from storage.objects
    where bucket_id = 'documents' and name = p_storage_path
  ) then
    raise exception 'لم يُعثر على الملف في المخزن';
  end if;

  if p_doc_type <> 'vehicle_photo' then
    update public.user_documents
    set storage_path = p_storage_path,
        status       = 'pending',
        review_notes = p_notes,
        reviewed_by  = null,
        reviewed_at  = null,
        updated_at   = now()
    where user_id = p_user_id and doc_type = p_doc_type
    returning id into v_id;

    v_replaced := v_id is not null;
  end if;

  if v_id is null then
    insert into public.user_documents
      (user_id, doc_type, storage_path, status, review_notes)
    values (p_user_id, p_doc_type, p_storage_path, 'pending', p_notes)
    returning id into v_id;
  end if;

  perform public.log_action(
    case when v_replaced then 'document.replace' else 'document.add' end,
    'user_documents',
    v_id::text,
    v_name || ' — ' || p_doc_type::text
  );

  return v_id;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) حذف وثيقة
-- -----------------------------------------------------------------------------
-- لصور المركبة المتعددة: يرفع السائق خمساً وتكفي ثلاث.
create or replace function public.admin_delete_document(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_doc public.user_documents; v_name text;
begin
  if not public.has_perm('profiles.edit') then
    raise exception 'لا تملك صلاحية تعديل بيانات المستخدمين'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_doc from public.user_documents where id = p_id;
  if not found then raise exception 'الوثيقة غير موجودة'; end if;

  -- **الصورة الحية لا تُحذف بل تُستبدل.** حذفها يُفرغ `avatar_url`
  -- فيفقد الراكب وجه سائقه، ولا مُشغّل يعيده.
  if v_doc.doc_type = 'live_selfie' then
    raise exception 'الصورة الحية تُستبدل ولا تُحذف';
  end if;

  select full_name into v_name from public.profiles where id = v_doc.user_id;

  delete from public.user_documents where id = p_id;

  perform public.log_action(
    'document.delete', 'user_documents', p_id::text,
    coalesce(v_name, '؟') || ' — ' || v_doc.doc_type::text
  );
end;
$fn$;


-- -----------------------------------------------------------------------------
-- ٤) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function
  public.admin_set_document(uuid, public.document_type, text, text)
  from public, anon;
revoke all on function public.admin_delete_document(uuid) from public, anon;

grant execute on function
  public.admin_set_document(uuid, public.document_type, text, text)
  to authenticated;
grant execute on function public.admin_delete_document(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
-- **الصورة الشخصية تتبع الصورة الحية تلقائياً.** مُشغّل
-- `sync_avatar_from_selfie` (0019) يلتقط أي تحديث لـ`storage_path` من
-- نوع `live_selfie` ويحدّث `profiles.avatar_url`. فاستبدال المدير
-- للصورة الحية يغيّر الصورة الشخصية بلا سطر إضافي — وهذا مقصود:
-- مصدر واحد للصورة لا اثنان يتباعدان.
select
  doc_type    as "نوع الوثيقة",
  count(*)    as "العدد",
  count(*) filter (where status = 'pending') as "بانتظار المراجعة"
from public.user_documents
group by doc_type
order by count(*) desc;
