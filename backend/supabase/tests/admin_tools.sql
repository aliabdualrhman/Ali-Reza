set search_path = public, extensions;

-- =============================================================================
-- أدوات المدير — مؤقتة حتى تُبنى لوحة التحكم
-- =============================================================================
-- لا توجد لوحة إدارة بعد، والسائق لا يعمل حتى تُعتمد وثائقه. هذا الملف
-- يسدّ الفجوة: تُشغّل منه ما تحتاجه من محرر SQL.
--
-- **كل قسم مستقل** — شغّل الذي تحتاجه فقط، لا الملف كله.
-- =============================================================================


-- =============================================================================
-- ١) ترقية حسابك إلى مدير
-- =============================================================================
-- المُشغّل handle_new_user يرفض دور admin القادم من التطبيق عمداً — وإلا
-- لاستطاع أي شخص ترقية نفسه وقت التسجيل. فالترقية من هنا حصراً.
--
-- بدّل البريد ببريدك.
-- =============================================================================
/*
update public.profiles
set role = 'admin'
where email = 'ali.ruddah1995@gmail.com'
returning full_name as "الاسم", email as "البريد", role as "الدور";
*/


-- =============================================================================
-- ٢) عرض السائقين المنتظرين وحالة وثائقهم
-- =============================================================================
select
  p.full_name                                   as "الاسم",
  p.phone                                       as "الهاتف",
  d.vehicle_type                                as "الدراجة",
  d.verification_status                         as "الحالة",
  count(ud.id) filter (where ud.status = 'approved') as "مقبولة",
  count(ud.id) filter (where ud.status = 'pending')  as "معلّقة",
  count(ud.id) filter (where ud.status = 'rejected') as "مرفوضة",
  string_agg(distinct ud.doc_type::text, ', ')  as "الوثائق المرفوعة"
from public.drivers d
join public.profiles p on p.id = d.id
left join public.user_documents ud on ud.user_id = d.id
group by p.full_name, p.phone, d.vehicle_type, d.verification_status
order by d.verification_status, p.full_name;


-- =============================================================================
-- ٣) اعتماد سائق — قبول كل وثائقه دفعة واحدة
-- =============================================================================
-- **لا نعدّل drivers.verification_status مباشرة.** المُشغّل
-- recompute_verification يحسبها من حالة الوثائق، وأي كتابة يدوية عليها
-- يمحوها أول تحديث وثيقة. نقبل الوثائق، وهو يعتمد السائق تلقائياً.
--
-- بدّل البريد ببريد السائق.
-- =============================================================================
/*
update public.user_documents
set status      = 'approved',
    reviewed_at = now(),
    reviewed_by = (select id from public.profiles where role = 'admin' limit 1)
where user_id = (
  select id from public.profiles where email = 'ali.ruddah1995+driver@gmail.com'
);

-- تحقّق أن المُشغّل اعتمده
select p.full_name as "الاسم", d.verification_status as "حالة الاعتماد"
from public.drivers d
join public.profiles p on p.id = d.id
where p.email = 'ali.ruddah1995+driver@gmail.com';
*/


-- =============================================================================
-- ٤) رفض وثيقة مع سبب
-- =============================================================================
/*
update public.user_documents
set status       = 'rejected',
    review_notes = 'الصورة غير واضحة، أعد التصوير بإضاءة أفضل',
    reviewed_at  = now()
where user_id = (select id from public.profiles where email = 'DRIVER_EMAIL')
  and doc_type = 'national_id_front';
*/


-- =============================================================================
-- ٥) متابعة الرحلات الجارية
-- =============================================================================
select
  t.trip_number                   as "رقم",
  t.status                        as "الحالة",
  rp.full_name                    as "الراكب",
  dp.full_name                    as "السائق",
  t.fare_estimated_iqd            as "الأجرة",
  t.pickup_address                as "من",
  t.dropoff_address               as "إلى",
  to_char(t.requested_at at time zone 'Asia/Baghdad', 'HH24:MI') as "وقت الطلب"
from public.trips t
join public.profiles rp on rp.id = t.rider_id
left join public.profiles dp on dp.id = t.driver_id
where t.status in ('searching','accepted','driver_arrived','in_progress')
order by t.requested_at desc;


-- =============================================================================
-- ٦) السائقون المتصلون الآن
-- =============================================================================
-- location_updated_at أهم من status: سائق أغلق التطبيق فجأة تبقى حالته
-- online بينما موقعه متوقف. الخادم يستبعده بعد ٩٠ ثانية.
-- =============================================================================
select
  p.full_name                                              as "الاسم",
  d.status                                                 as "الحالة",
  round(extract(epoch from (now() - d.location_updated_at))) as "منذ (ثانية)",
  round(st_y(d.current_location::geometry)::numeric, 5)    as "خط العرض",
  round(st_x(d.current_location::geometry)::numeric, 5)    as "خط الطول",
  d.wallet_balance_iqd                                     as "المحفظة"
from public.drivers d
join public.profiles p on p.id = d.id
where d.status <> 'offline'
order by d.location_updated_at desc nulls last;


-- =============================================================================
-- ٧) تسجيل تسديد من سائق
-- =============================================================================
-- حين يسلّم السائق العمولات المستحقة نقداً، نسجّلها لتعود محفظته نحو الصفر.
-- المبلغ **موجب** لأنه إضافة لرصيده.
-- =============================================================================
/*
select public.post_wallet_transaction(
  p_driver_id   => (select id from public.profiles where email = 'DRIVER_EMAIL'),
  p_txn_type    => 'topup',
  p_amount_iqd  => 5000,
  p_description => 'تسديد نقدي',
  p_created_by  => (select id from public.profiles where role = 'admin' limit 1)
);
*/
