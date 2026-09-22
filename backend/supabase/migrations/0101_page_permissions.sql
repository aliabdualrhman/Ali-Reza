-- =============================================================================
-- 0101 — كل صفحةٍ وكل زرٍّ في اللوحة بصلاحية
-- =============================================================================
-- طلب علي: «موظفٌ لا يرى لوحة الأرقام أصلاً، أو يراها. يلغي الرحلات أو
-- لا. اعمل كل الصلاحيات، والمدير يوزّعها».
--
-- فالصلاحيات صارت نوعين، ومجموعةً لكل صفحة:
--
--   • «عرض»  — تُظهر الصفحة في القائمة الجانبية.
--   • «فعل»  — تُظهر زرّاً، **وتُفحص في القاعدة** قبل أن يُنفَّذ.
--
-- وصفحة «المستخدمين» (توزيع الصلاحيات نفسها) للمالك وحده — لا صلاحية لها،
-- لأن من يوزّع الصلاحيات يملكها كلها.
--
-- **وثلاث صلاحيات كانت تُفحص في القاعدة ولا تظهر في القائمة**:
-- `drivers.suspend` و`profiles.review` و`drivers.topup`. فلا يستطيع المالك
-- منحها لأحد — يبقى الموظف عاجزاً عن فعلٍ يراه زرّاً أمامه. الأوليان
-- تدخلان القائمة الآن، والثالثة لدالةٍ لا تستعملها اللوحة.
--
-- **حدود هذا الترحيل — بصراحة:** إخفاء الصفحة يمنع الموظف من رؤيتها في
-- اللوحة، والأفعال تُمنع في القاعدة. أمّا **قراءة الصفوف** مباشرةً (بلا
-- لوحة) فما زالت لكل مشرف، لأن صفحةً واحدة تقرأ من جداول كثيرة: صفحة
-- السائق تقرأ رحلاته ومحفظته ووثائقه. ربطُ قراءة كل جدولٍ بصلاحية خطوةٌ
-- منفصلة. ولوحة الأرقام وتصدير الرحلات وقنوات الوصول — وهي خلاصات
-- الأعمال — تُقفل هنا في القاعدة.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) القائمة — مجمّعةً بالصفحة
-- -----------------------------------------------------------------------------
alter table public.permission_catalog
  add column if not exists page text;

comment on column public.permission_catalog.page is
  'الصفحة التي تخصّها الصلاحية — تجمع بها صفحة المستخدمين المربّعات.';

insert into public.permission_catalog (code, label, sort_order, page) values
  -- لوحة الأرقام
  ('dashboard.view',     'رؤية لوحة الأرقام',                               10, 'لوحة الأرقام'),

  -- السائقون
  ('drivers.view',       'رؤية صفحة السائقين وأرصدتهم',                     20, 'السائقون'),
  ('drivers.review',     'مراجعة وثائق السائقين واعتمادها',                 21, 'السائقون'),
  ('drivers.suspend',    'إيقاف السائقين وحظرهم وإلغاء اعتمادهم',           22, 'السائقون'),

  -- الركّاب
  ('riders.view',        'رؤية صفحة الركّاب',                               30, 'الركّاب'),

  -- الحسابات (للسائقين والركّاب معاً)
  ('profiles.edit',      'تعديل بيانات المستخدمين وحظر الركّاب',            40, 'الحسابات'),
  ('profiles.review',    'مراجعة طلبات تعديل البيانات',                     41, 'الحسابات'),
  ('accounts.create',    'إنشاء حسابات جديدة',                              42, 'الحسابات'),
  ('accounts.delete',    'حذف الحسابات',                                    43, 'الحسابات'),
  ('wallets.adjust',     'شحن الرصيد وخصمه مباشرةً (من صفحة السائق والراكب)', 44, 'الحسابات'),

  -- الرحلات
  ('trips.view',         'رؤية صفحة الرحلات',                               50, 'الرحلات'),
  ('trips.cancel',       'إلغاء رحلة جارية',                                51, 'الرحلات'),
  ('trips.export',       'تصدير الرحلات إلى Excel (يحتاج رمز المدير أيضاً)', 52, 'الرحلات'),

  -- رموز التعبئة
  ('topups.view',        'رؤية رموز التعبئة',                               60, 'رموز التعبئة'),
  ('topups.generate',    'توليد رموز التعبئة وإبطال غير المستعمل منها',     61, 'رموز التعبئة'),
  ('topups.delete',      'حذف رموز التعبئة (المستهلكة والملغاة)',           62, 'رموز التعبئة'),

  -- طلبات السحب
  ('payouts.view',       'رؤية طلبات السحب',                                70, 'طلبات السحب'),
  ('payouts.process',    'دفع طلبات السحب ورفضها',                          71, 'طلبات السحب'),

  -- الكوبونات
  ('coupons.view',       'رؤية الكوبونات',                                  80, 'الكوبونات'),
  ('coupons.manage',     'إنشاء الكوبونات وإيقافها',                        81, 'الكوبونات'),

  -- الإعدادات والمناطق
  ('settings.view',      'رؤية الإعدادات والمناطق',                         90, 'الإعدادات'),
  ('settings.manage',    'تعديل الإعدادات والأسعار والمناطق',               91, 'الإعدادات'),

  -- قنوات الوصول
  ('growth.view',        'رؤية تقرير قنوات الوصول',                        100, 'قنوات الوصول'),

  -- الإشعارات
  ('notifications.view', 'رؤية صفحة الإشعارات',                            110, 'الإشعارات'),
  ('notifications.send', 'إرسال الإشعارات وإدارة القوالب',                  111, 'الإشعارات'),

  -- المتاجر
  ('stores.review',      'رؤية المتاجر ومراجعتها واعتمادها وإيقافها',       120, 'المتاجر'),
  ('deliveries.settle',  'إغلاق مستحقات المتاجر والنزاعات',                 121, 'المتاجر')
on conflict (code) do update
  set label = excluded.label,
      sort_order = excluded.sort_order,
      page = excluded.page;


-- **والقائمة تُرجع الصفحة معها** — لتُجمع المربّعات في صفحة المستخدمين
-- تحت عناوينها بدل قائمةٍ واحدة من ثلاثين سطراً. تغيير نوع الإرجاع
-- يستلزم حذف الدالة أولاً.
drop function if exists public.known_permissions();
create function public.known_permissions()
returns table (code text, label text, page text)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select code, label, coalesce(page, 'أخرى')
  from public.permission_catalog
  order by sort_order, code;
$fn$;

revoke all on function public.known_permissions() from public, anon;
grant execute on function public.known_permissions() to authenticated;


-- -----------------------------------------------------------------------------
-- ٢) خلاصات الأعمال تُقفل بصلاحيتها في القاعدة
-- -----------------------------------------------------------------------------
-- **سطر الفحص وحده يتغيّر، آلياً من التعريف الحيّ.** إعادة كتابة دالةٍ
-- طولها أربعة آلاف حرف بيدٍ تُسقط منطقاً — وقد وقع ذلك في 0080 حين
-- كُتبت `dispatch_next_offer` من الذاكرة. فنقرأ التعريف كما هو في
-- القاعدة، ونستبدل السطر، ونرفض إن لم نجده مرةً واحدة بالضبط.
do $do$
declare
  r      record;
  v_def  text;
  v_old  constant text := 'if not public.is_admin() then';
  v_n    integer;
begin
  for r in
    select * from (values
      ('admin_dashboard',          'dashboard.view'),
      ('admin_export_trips',       'trips.export'),
      ('admin_acquisition_report', 'growth.view')
    ) as t(fn, perm)
  loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = r.fn;

    if v_def is null then
      raise exception 'الدالة % غير موجودة', r.fn;
    end if;

    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);

    if v_n = 0 and v_def like format('%%has_perm(''%s'')%%', r.perm) then
      continue;  -- طُبّق من قبل
    end if;
    if v_n <> 1 then
      raise exception 'الدالة %: سطر الفحص موجود % مرة لا مرةً واحدة', r.fn, v_n;
    end if;

    execute replace(v_def, v_old,
                    format('if not public.has_perm(%L) then', r.perm));
  end loop;
end;
$do$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.permission_catalog where page is null)  as "صلاحيات بلا صفحة (٠)",
  (select count(*) from public.permission_catalog)                     as "عدد الصلاحيات",
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('admin_dashboard', 'admin_export_trips',
                     'admin_acquisition_report')
     and prosrc like '%has_perm(%')                                   as "خلاصات بصلاحيتها (٣)";
