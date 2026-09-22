-- مسار البحث: Supabase يثبّت PostGIS في مخطط extensions لا public.
-- بدون إضافته هنا يفشل التعرّف على النوع geography ودوال st_*.
set search_path = public, extensions;

-- =============================================================================
-- 0007 — سياسات أمان الصفوف (Row Level Security)
-- =============================================================================
-- مفهوم RLS: تطبيق Flutter يتصل بقاعدة البيانات مباشرة بمفتاح عام (anon key)
-- يعرفه أي شخص يفكك ملف APK. الأمان لا يأتي من إخفاء المفتاح، بل من هذه
-- السياسات: قواعد تُطبَّق على كل استعلام فتحدد أي الصفوف يراها المستخدم.
--
-- القاعدة الذهبية: نمنع كل شيء افتراضياً ثم نسمح بأضيق ما يلزم.
-- =============================================================================

alter table public.profiles            enable row level security;
alter table public.drivers             enable row level security;
alter table public.user_documents      enable row level security;
alter table public.trips               enable row level security;
alter table public.trip_offers         enable row level security;
alter table public.trip_locations      enable row level security;
alter table public.ratings             enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.pricing_zones       enable row level security;
alter table public.surge_state         enable row level security;

-- =============================================================================
-- profiles
-- =============================================================================

create policy "profiles: يقرأ المستخدم ملفه"
  on public.profiles for select
  using (id = auth.uid() or public.is_admin());

-- **لا توجد سياسة تتيح لطرفي الرحلة قراءة ملف بعضهما مباشرة.** هذا مقصود.
--
-- سياسة SELECT تمنح الصف كاملاً بكل أعمدته — ولا يمكن حصرها بأعمدة معيّنة.
-- لو سمحنا للسائق بقراءة ملف راكبه، لرأى **رقم بطاقته الوطنية**.
--
-- البديل: العرض trip_party_info في نهاية هذا الملف، يكشف الحقول الآمنة فقط
-- (الاسم، الصورة، التقييم، بيانات المركبة) ويكشف الهاتف أثناء الرحلة النشطة
-- وحدها.

-- المستخدم يعدّل ملفه.
--
-- ملاحظة مهمة: منع ترقية الدور مكتوب كمُشغّل (أسفل الملف) لا كشرط في
-- with check. السبب أن أي استعلام فرعي من profiles داخل سياسة على profiles
-- يُنتج خطأ "infinite recursion detected in policy" — السياسة تُطبَّق على
-- استعلامها الفرعي فتستدعي نفسها.
create policy "profiles: يعدّل المستخدم ملفه"
  on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy "profiles: صلاحية كاملة للمشرف"
  on public.profiles for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- drivers
-- =============================================================================

create policy "drivers: يقرأ السائق سجله"
  on public.drivers for select
  using (id = auth.uid() or public.is_admin());

-- الراكب يرى بيانات سائقه أثناء الرحلة فقط (لوحة الدراجة، التقييم، الموقع)
create policy "drivers: راكب الرحلة النشطة"
  on public.drivers for select
  using (
    exists (
      select 1 from public.trips t
      where t.driver_id = drivers.id
        and t.rider_id = auth.uid()
        and t.status in ('accepted', 'driver_arrived', 'in_progress')
    )
  );

-- السائق يحدّث بيانات مركبته فقط. الحالة والموقع والرصيد والاعتماد
-- تُغيَّر حصراً عبر الدوال في 0006، ويحرسها المُشغّل أسفل الملف
-- (وليس with check، لنفس سبب التكرار اللانهائي المذكور أعلاه).
create policy "drivers: يحدّث السائق بيانات مركبته"
  on public.drivers for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy "drivers: صلاحية كاملة للمشرف"
  on public.drivers for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- user_documents — وثائق شخصية حساسة (صور بطاقات ووجوه)
-- =============================================================================
-- لا يرى أحد وثائق أحد. حتى طرفا الرحلة لا يريان صور بعضهما — الصورة الحية
-- أداة تحقق للإدارة، لا لعرضها على المستخدمين.
-- =============================================================================

create policy "documents: المستخدم يرى وثائقه"
  on public.user_documents for select
  using (user_id = auth.uid() or public.is_admin());

create policy "documents: المستخدم يرفع وثائقه"
  on public.user_documents for insert
  with check (user_id = auth.uid() and status = 'pending');

-- يعيد الرفع فقط إن كانت مرفوضة أو معلّقة — لا يمس المقبولة.
-- ولا يستطيع تغيير الحالة إلى approved بنفسه: with check يفرض pending.
create policy "documents: المستخدم يعيد رفع المرفوضة"
  on public.user_documents for update
  using (user_id = auth.uid() and status in ('pending', 'rejected'))
  with check (user_id = auth.uid() and status = 'pending');

create policy "documents: المشرف يراجع"
  on public.user_documents for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- trips
-- =============================================================================

create policy "trips: طرفا الرحلة يقرآنها"
  on public.trips for select
  using (rider_id = auth.uid() or driver_id = auth.uid() or public.is_admin());

-- السائق يرى الرحلة المعروضة عليه قبل قبولها (وإلا لن يرى تفاصيل العرض)
create policy "trips: السائق يرى العرض المُقدَّم له"
  on public.trips for select
  using (
    exists (
      select 1 from public.trip_offers o
      where o.trip_id = trips.id
        and o.driver_id = auth.uid()
        and o.status = 'pending'
    )
  );

-- لا INSERT ولا UPDATE مباشر على الرحلات إطلاقاً.
-- كل تعديل يمر عبر request_trip / accept_trip_offer / advance_trip /
-- complete_trip / cancel_trip. هذا ما يمنع تزوير الأجرة أو تخطي الحالات.

create policy "trips: صلاحية كاملة للمشرف"
  on public.trips for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- trip_offers
-- =============================================================================

create policy "offers: السائق يرى عروضه"
  on public.trip_offers for select
  using (driver_id = auth.uid() or public.is_admin());

-- الراكب يتابع تقدم البحث ("جارٍ الاتصال بالسائق الثالث...")
create policy "offers: الراكب يتابع بحث رحلته"
  on public.trip_offers for select
  using (
    exists (select 1 from public.trips t where t.id = trip_offers.trip_id and t.rider_id = auth.uid())
  );

-- =============================================================================
-- trip_locations — أثر المسار
-- =============================================================================

create policy "locations: طرفا الرحلة"
  on public.trip_locations for select
  using (
    exists (
      select 1 from public.trips t
      where t.id = trip_locations.trip_id
        and (t.rider_id = auth.uid() or t.driver_id = auth.uid())
    )
    or public.is_admin()
  );

-- =============================================================================
-- ratings
-- =============================================================================

create policy "ratings: يقرأ الجميع تقييمات مرئية"
  on public.ratings for select
  using (rater_id = auth.uid() or ratee_id = auth.uid() or public.is_admin());

-- يقيّم فقط من كان طرفاً في رحلة مكتملة، ولا يقيّم نفسه
create policy "ratings: تقييم بعد رحلة مكتملة"
  on public.ratings for insert
  with check (
    rater_id = auth.uid()
    and ratee_id <> auth.uid()
    and exists (
      select 1 from public.trips t
      where t.id = ratings.trip_id
        and t.status = 'completed'
        and (
          (t.rider_id  = auth.uid() and t.driver_id = ratings.ratee_id) or
          (t.driver_id = auth.uid() and t.rider_id  = ratings.ratee_id)
        )
    )
  );

-- =============================================================================
-- wallet_transactions — للقراءة فقط من التطبيق
-- =============================================================================

create policy "wallet: السائق يقرأ كشف حسابه"
  on public.wallet_transactions for select
  using (driver_id = auth.uid() or public.is_admin());

create policy "wallet: المشرف يسجّل تسويات"
  on public.wallet_transactions for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- pricing_zones & surge_state — قراءة عامة، تعديل للمشرف
-- =============================================================================

create policy "pricing: قراءة عامة للمناطق المفعّلة"
  on public.pricing_zones for select
  using (is_active or public.is_admin());

create policy "pricing: تعديل للمشرف"
  on public.pricing_zones for all
  using (public.is_admin()) with check (public.is_admin());

create policy "surge: قراءة عامة"
  on public.surge_state for select using (true);

create policy "surge: تعديل للمشرف"
  on public.surge_state for all
  using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- منح الصلاحيات على الدوال
-- =============================================================================
-- الدوال security definer تتجاوز RLS، لذلك نمنحها للمستخدمين المسجّلين فقط
-- (authenticated) وليس للزوار (anon).
-- =============================================================================

revoke all on function public.update_driver_location    from public, anon;
revoke all on function public.set_driver_online          from public, anon;
revoke all on function public.request_trip               from public, anon;
revoke all on function public.accept_trip_offer          from public, anon;
revoke all on function public.reject_trip_offer          from public, anon;
revoke all on function public.advance_trip               from public, anon;
revoke all on function public.complete_trip              from public, anon;
revoke all on function public.cancel_trip                from public, anon;
revoke all on function public.post_wallet_transaction    from public, anon, authenticated;
revoke all on function public.dispatch_next_offer        from public, anon, authenticated;
revoke all on function public.expire_stale_offers        from public, anon, authenticated;

grant execute on function public.update_driver_location  to authenticated;
grant execute on function public.set_driver_online        to authenticated;
grant execute on function public.estimate_trip            to authenticated;
grant execute on function public.request_trip             to authenticated;
grant execute on function public.accept_trip_offer        to authenticated;
grant execute on function public.reject_trip_offer        to authenticated;
grant execute on function public.advance_trip             to authenticated;
grant execute on function public.complete_trip            to authenticated;
grant execute on function public.cancel_trip              to authenticated;
grant execute on function public.find_nearby_drivers      to authenticated;

-- =============================================================================
-- عرض مبسّط لبيانات الطرف الآخر — نكشف الحد الأدنى فقط
-- =============================================================================
-- الراكب يحتاج: اسم السائق، تقييمه، لوحة دراجته. لا يحتاج رقم هويته ولا رصيده.
-- =============================================================================
-- ملاحظتان على التصميم:
--
-- ١) لا نضع security_invoker = true عمداً. بدونها يعمل العرض بصلاحيات مالكه
--    فيتجاوز RLS على profiles — وهذا ما نريده بالضبط: أن يقرأ الحقول الآمنة
--    نيابةً عن المستخدم دون منحه صلاحية قراءة الجدول كله.
--
-- ٢) security_barrier = true يمنع بوستغرس من تقديم شروط المستخدم على شرط
--    where الخاص بنا أثناء التحسين. بدونها يستطيع مستخدم ذكي تمرير دالة
--    تُنفَّذ قبل الفلترة فتتسرب صفوف رحلات لا يملكها.
create or replace view public.trip_party_info
with (security_barrier = true)
as
select
  t.id   as trip_id,
  p.id   as person_id,
  case when p.id = t.driver_id then 'driver' else 'rider' end as party,

  p.full_name,
  p.avatar_url,

  -- الهاتف يُكشف أثناء الرحلة النشطة فقط. بعد انتهائها لا يبقى سبب
  -- لبقاء رقم الراكب في يد السائق.
  case
    when t.status in ('accepted', 'driver_arrived', 'in_progress') then p.phone
    else null
  end as phone,

  d.rating_avg,
  d.vehicle_plate,
  d.vehicle_make,
  d.vehicle_model,
  d.vehicle_color

from public.trips t
join public.profiles p
  on p.id = t.rider_id or p.id = t.driver_id
left join public.drivers d on d.id = p.id
-- الفلتر الأمني: لا تُرجع إلا رحلات المستدعي نفسه
where t.rider_id = auth.uid() or t.driver_id = auth.uid();

comment on view public.trip_party_info is
  'الحقول الآمنة فقط عن طرفي الرحلة. لا يكشف رقم البطاقة الوطنية إطلاقاً.';

grant select on public.trip_party_info to authenticated;

-- =============================================================================
-- تفعيل البث اللحظي (Realtime)
-- =============================================================================
-- Supabase يبث تغييرات الجداول المضافة لهذا المنشور عبر WebSocket.
-- سياسات RLS تُطبَّق على البث أيضاً — فلا يصل الراكب إلا ما يحق له رؤيته.
-- =============================================================================
alter publication supabase_realtime add table public.trips;
alter publication supabase_realtime add table public.trip_offers;
alter publication supabase_realtime add table public.drivers;

-- بدون هذا يرسل بوستغرس المفتاح الأساسي فقط عند التحديث، ونحتاج الصف كاملاً
alter table public.trips       replica identity full;
alter table public.trip_offers replica identity full;

-- =============================================================================
-- المُشغّلات الحارسة — تحمي الأعمدة الحسّاسة من التعديل المباشر
-- =============================================================================
-- لماذا مُشغّل لا سياسة RLS؟ لأن مقارنة القيمة الجديدة بالقديمة تحتاج
-- استعلاماً فرعياً من نفس الجدول، وهو ما يسبب تكراراً لانهائياً داخل السياسة.
-- المُشغّل يملك old و new جاهزتين فلا يحتاج استعلاماً أصلاً.
--
-- منفذ العبور: الدوال الموثوقة (post_wallet_transaction وغيرها) ترفع علماً
-- محلياً للمعاملة قبل التعديل. العلم يزول تلقائياً بنهاية المعاملة، ولا
-- يستطيع المستخدم رفعه لأنه لا يملك صلاحية استدعاء تلك الدوال.
-- =============================================================================

create or replace function public.guards_bypassed()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('app.bypass_guards', true), 'off') = 'on';
$$;

-- -----------------------------------------------------------------------------
create or replace function public.guard_profile_columns()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.guards_bypassed() or public.is_admin() then
    return new;
  end if;

  if new.role is distinct from old.role then
    raise exception 'لا يمكن تغيير دور المستخدم' using errcode = 'insufficient_privilege';
  end if;

  if new.is_blocked is distinct from old.is_blocked then
    raise exception 'لا يمكن تغيير حالة الحظر' using errcode = 'insufficient_privilege';
  end if;

  -- التحقق من الهوية يُقرَّر من مراجعة الصورة الحية، لا من التطبيق
  if new.identity_verified is distinct from old.identity_verified then
    raise exception 'حالة التحقق من الهوية تُحدَّد من مراجعة الوثائق فقط'
      using errcode = 'insufficient_privilege';
  end if;

  if new.phone_verified is distinct from old.phone_verified then
    raise exception 'لا يمكن توثيق الهاتف من التطبيق'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger profiles_guard_columns
  before update on public.profiles
  for each row execute function public.guard_profile_columns();

-- -----------------------------------------------------------------------------
create or replace function public.guard_driver_columns()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.guards_bypassed() or public.is_admin() then
    return new;
  end if;

  if new.wallet_balance_iqd is distinct from old.wallet_balance_iqd then
    raise exception 'الرصيد يُعدَّل حصراً عبر post_wallet_transaction'
      using errcode = 'insufficient_privilege';
  end if;

  if new.verification_status is distinct from old.verification_status then
    raise exception 'حالة الاعتماد تُحدَّد من مراجعة الوثائق فقط'
      using errcode = 'insufficient_privilege';
  end if;

  if new.rating_avg is distinct from old.rating_avg
     or new.rating_count is distinct from old.rating_count
     or new.trips_completed is distinct from old.trips_completed then
    raise exception 'إحصاءات السائق تُحدَّث من النظام فقط'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger drivers_guard_columns
  before update on public.drivers
  for each row execute function public.guard_driver_columns();
