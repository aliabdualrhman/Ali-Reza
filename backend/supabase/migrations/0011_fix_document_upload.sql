set search_path = public, extensions;

-- =============================================================================
-- 0011 — إصلاح رفع الوثائق
-- =============================================================================
-- **العَرَض:** كل محاولة رفع صورة حية تفشل برسالة عامة في التطبيق.
--
-- **السبب الأول — تعارض السياسة مع المُشغّل:**
--
--   سياسة الإدراج تشترط status = 'pending'
--   ومُشغّل auto_approve_rider_docs يغيّرها إلى 'approved' للراكب
--
--   مُشغّلات BEFORE تُنفَّذ **قبل** فحص RLS، فالصف الواصل للفحص حالته
--   approved بينما السياسة تشترط pending. النتيجة: رفض كل رفع من راكب.
--
--   المفارقة أن الاعتماد التلقائي نفسه هو ما كان يكسر الرفع.
--
-- **السبب الثاني — upsert على فهرس جزئي:**
--
--   فهرسنا الفريد جزئي (يستثني vehicle_photo لأن صور الدراجة متعددة)،
--   و ON CONFLICT (user_id, doc_type) يتطلب فهرساً كاملاً يطابقه تماماً.
--   بوستغرس يرفض بـ 42P10.
--
-- **الحل:** نقل منطق الرفع كله إلى دالة واحدة في القاعدة، ودمج فرض الحالة
-- مع الاعتماد التلقائي في مُشغّل واحد بدل مُشغّل وسياسة يتنازعان.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- مُشغّل واحد يفرض الحالة ثم يعتمد الراكب
--
-- **لماذا دالة واحدة لا اثنتان؟** ترتيب تنفيذ مُشغّلات BEFORE في بوستغرس
-- أبجدي حسب اسم المُشغّل — اعتماد خفي وهشّ. دمجهما يجعل الترتيب صريحاً
-- في الكود: افرض pending أولاً، ثم اعتمد إن كان راكباً.
-- -----------------------------------------------------------------------------
create or replace function public.enforce_document_status()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role public.user_role;
begin
  -- ١) لا يعتمد المستخدم وثيقته بنفسه.
  --
  -- نفرض pending هنا بدل اشتراطها في سياسة RLS. لماذا؟ لأن السياسة تفحص
  -- الصف **بعد** المُشغّلات، فلو اشترطت pending لتعارضت مع الاعتماد
  -- التلقائي أدناه. الفرض في المُشغّل يحسم التنازع من جذره.
  if not public.is_admin() and not public.guards_bypassed() then
    new.status      := 'pending';
    new.reviewed_by := null;
    new.reviewed_at := null;
  end if;

  -- ٢) الراكب يُعتمد تلقائياً — لا مراجعة يدوية عليه إطلاقاً.
  --
  -- مراجعة صور آلاف الركّاب يدوياً وظيفة بدوام كامل. المراجعة تُحفظ
  -- للسائقين وهم عشرات، لأنهم من ينقل الناس ويقبض المال.
  select role into v_role from public.profiles where id = new.user_id;

  if new.doc_type = 'live_selfie' and v_role = 'rider' then
    new.status      := 'approved';
    new.reviewed_at := now();
  end if;

  return new;
end;
$$;

drop trigger if exists user_documents_auto_approve_riders on public.user_documents;
drop trigger if exists user_documents_enforce_status      on public.user_documents;

create trigger user_documents_enforce_status
  before insert or update on public.user_documents
  for each row execute function public.enforce_document_status();

-- -----------------------------------------------------------------------------
-- السياسات: تتحقق من الملكية فقط، والحالة يفرضها المُشغّل
-- -----------------------------------------------------------------------------
drop policy if exists "documents: المستخدم يرفع وثائقه" on public.user_documents;
create policy "documents: المستخدم يرفع وثائقه"
  on public.user_documents for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "documents: المستخدم يعيد رفع المرفوضة" on public.user_documents;
create policy "documents: المستخدم يعيد رفع المرفوضة"
  on public.user_documents for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- المستخدم يحتاج حذف صفه القديم عند إعادة الرفع.
-- ملاحظة: هذا حذف **سجل** الوثيقة لا **ملف** الصورة — ملفات التخزين
-- تبقى، وحذفها للمشرف وحده كما في 0010، لأنها دليل تحقق.
drop policy if exists "documents: حذف سجل عند إعادة الرفع" on public.user_documents;
create policy "documents: حذف سجل عند إعادة الرفع"
  on public.user_documents for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- =============================================================================
-- دالة تسجيل الوثيقة — المنفذ الوحيد من التطبيق
-- =============================================================================
-- تحلّ محل upsert الذي كان يفشل على الفهرس الجزئي.
--
-- تتصرف حسب النوع:
--   vehicle_photo  →  تُضاف بجانب سابقاتها (صور متعددة للدراجة)
--   ما عداها       →  تستبدل سابقتها (نسخة واحدة لكل نوع)
--
-- وضعها في القاعدة لا في التطبيق يضمن أن تطبيق الراكب وتطبيق السائق
-- ولوحة الإدارة تتصرف بالمنطق نفسه. مصدر واحد للحقيقة.
-- =============================================================================
create or replace function public.submit_document(
  p_doc_type     public.document_type,
  p_storage_path text
)
returns public.user_documents
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.user_documents;
begin
  if v_uid is null then
    raise exception 'يجب تسجيل الدخول أولاً' using errcode = 'insufficient_privilege';
  end if;

  if p_storage_path is null or btrim(p_storage_path) = '' then
    raise exception 'مسار الملف مفقود';
  end if;

  -- المسار يجب أن يبدأ بمعرّف صاحبه — نفس اصطلاح سياسات التخزين في 0010.
  -- بدون هذا الفحص يستطيع مستخدم تسجيل مسار ملف يخص غيره.
  if split_part(p_storage_path, '/', 1) <> v_uid::text then
    raise exception 'مسار الملف لا يطابق حسابك'
      using errcode = 'insufficient_privilege';
  end if;

  -- نسخة واحدة لكل نوع عدا صور الدراجة
  if p_doc_type <> 'vehicle_photo' then
    delete from public.user_documents
    where user_id = v_uid and doc_type = p_doc_type;
  end if;

  insert into public.user_documents (user_id, doc_type, storage_path)
  values (v_uid, p_doc_type, p_storage_path)
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.submit_document(public.document_type, text)
  from public, anon;
grant execute on function public.submit_document(public.document_type, text)
  to authenticated;
