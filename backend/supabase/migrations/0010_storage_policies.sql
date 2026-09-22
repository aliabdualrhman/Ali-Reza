-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
set search_path = public, extensions;

-- =============================================================================
-- 0010 — سياسات تخزين الوثائق
-- =============================================================================
-- البكت `documents` خاص (Private)، لكن الخصوصية وحدها لا تكفي: بدون سياسات
-- لا يستطيع أي مستخدم مسجّل الرفع ولا القراءة إطلاقاً، ومع سياسات فضفاضة
-- يقرأ كل مستخدم صور الجميع.
--
-- **اصطلاح المسار — أساس الأمان كله:**
--
--     documents/<user_id>/<doc_type>_<timestamp>.jpg
--
-- أول جزء من المسار هو معرّف صاحب الملف. السياسات تقارنه بـ auth.uid()،
-- فيصير كل مستخدم محصوراً في مجلده لا يخرج منه.
--
-- storage.foldername(name) تفكّك المسار إلى مصفوفة أجزاء، و [1] أولها.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- الرفع — كل مستخدم في مجلده وحده
-- -----------------------------------------------------------------------------
drop policy if exists "documents: رفع في مجلد المستخدم" on storage.objects;
create policy "documents: رفع في مجلد المستخدم"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- -----------------------------------------------------------------------------
-- القراءة — ملفاتك أنت، أو أي ملف إن كنت مشرفاً
--
-- المشرف يحتاجها لمراجعة وثائق السائقين واعتمادهم.
-- لا أحد غيرهما: حتى طرفا الرحلة لا يريان صور بعضهما.
-- -----------------------------------------------------------------------------
drop policy if exists "documents: قراءة ملفاتي" on storage.objects;
create policy "documents: قراءة ملفاتي"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documents'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin()
    )
  );

-- -----------------------------------------------------------------------------
-- الاستبدال — لإعادة رفع وثيقة مرفوضة
-- -----------------------------------------------------------------------------
drop policy if exists "documents: استبدال ملفاتي" on storage.objects;
create policy "documents: استبدال ملفاتي"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- -----------------------------------------------------------------------------
-- الحذف — للمشرف وحده
--
-- **لماذا نمنع المستخدم من حذف وثائقه؟** لأنها دليل تحقق. سائق تورّط في
-- حادثة يجب ألا يستطيع محو صورة بطاقته بضغطة. الاستبدال مسموح، المحو لا.
-- -----------------------------------------------------------------------------
drop policy if exists "documents: حذف للمشرف فقط" on storage.objects;
create policy "documents: حذف للمشرف فقط"
  on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and public.is_admin());

-- =============================================================================
-- ضبط البكت: الحد الأقصى للحجم والأنواع المسموحة
-- =============================================================================
-- الحد يمنع رفع فيديو بدل صورة أو إغراق التخزين. وحصر الأنواع يمنع رفع
-- ملف تنفيذي بامتداد صورة.
-- =============================================================================
update storage.buckets
set file_size_limit   = 5242880,        -- ٥ ميجابايت
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'],
    public = false                       -- تأكيد، ولو أُنشئ خاصاً أصلاً
where id = 'documents';

-- =============================================================================
-- دالة مساعدة: بناء مسار وثيقة بالاصطلاح الصحيح
-- =============================================================================
-- نضعها في القاعدة لا في التطبيق حتى لا يختلف اصطلاح المسار بين تطبيق
-- الراكب وتطبيق السائق ولوحة الإدارة. مصدر واحد للحقيقة.
-- =============================================================================
create or replace function public.document_storage_path(
  p_doc_type public.document_type,
  p_ext      text default 'jpg'
)
returns text
language sql
stable
as $$
  select auth.uid()::text || '/' || p_doc_type::text || '_' ||
         extract(epoch from now())::bigint::text || '.' || p_ext;
$$;

grant execute on function public.document_storage_path(public.document_type, text)
  to authenticated;
