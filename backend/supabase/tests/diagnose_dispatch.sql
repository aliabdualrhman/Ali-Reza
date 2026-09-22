set search_path = public, extensions;

-- =============================================================================
-- تشخيص محرك المطابقة — استعلام واحد
-- =============================================================================
-- **لماذا استعلام واحد؟** محرر Supabase يعرض نتيجة آخر استعلام فقط. الملف
-- السابق كان ستة استعلامات منفصلة فضاعت خمسة منها.
--
-- كل سطر هنا فحص، مرتّبة حسب تسلسل السلسلة — فأول سطر يقول "لا" هو موضع
-- الانقطاع.
-- =============================================================================

with
-- آخر رحلة تبحث أو استسلمت
last_trip as (
  select * from public.trips
  where status in ('searching', 'no_drivers')
  order by requested_at desc limit 1
),
-- **لماذا نستثني `running`؟** مهمتنا تعمل دقيقة كاملة (١٢ دورة × ٥ ثوانٍ)،
-- فعند أي لحظة نسأل فيها توجد تشغيلة قيد التنفيذ حالتها `running`. عدّها
-- فشلاً أعطانا إنذاراً كاذباً — الفشل الحقيقي حالته `failed`.
cron_runs as (
  select count(*) filter (where d.status = 'succeeded') as ok,
         count(*) filter (where d.status not in ('succeeded', 'running')) as bad,
         max(d.start_time) as last_run
  from cron.job_run_details d
  join cron.job j on j.jobid = d.jobid
  where j.jobname = 'zanbour-dispatch'
    and d.start_time > now() - interval '30 minutes'
),
drv as (
  select d.*, p.full_name, p.fcm_token,
         round(extract(epoch from (now() - d.location_updated_at)))::int as loc_age
  from public.drivers d join public.profiles p on p.id = d.id
  order by d.location_updated_at desc nulls last limit 1
)

select * from (
  -- ١ ────────────────────────────────────────────────────────────────
  select 1 as "#", 'العامل الدوري يعمل؟' as "الفحص",
         case when (select ok from cron_runs) > 0
              then 'نعم — ' || (select ok from cron_runs)::text || ' تشغيلة ناجحة'
              else 'لا ✗' end as "النتيجة",
         coalesce((select last_run from cron_runs)::text, 'لا تشغيلات') as "تفصيل"

  union all
  select 2, 'تشغيلات فاشلة؟',
         case when (select bad from cron_runs) > 0
              then 'نعم ✗ — ' || (select bad from cron_runs)::text
              else 'لا' end,
         coalesce((
           select d.return_message from cron.job_run_details d
           join cron.job j on j.jobid = d.jobid
           where j.jobname = 'zanbour-dispatch' and d.status not in ('succeeded', 'running')
           order by d.start_time desc limit 1
         ), '—')

  -- ٢ ────────────────────────────────────────────────────────────────
  union all
  select 3, 'حالة آخر رحلة',
         coalesce((select status::text from last_trip), 'لا توجد رحلة'),
         coalesce((select 'منذ ' ||
           round(extract(epoch from (now() - requested_at)))::int::text ||
           ' ثانية · ' || coalesce(pickup_address,'') from last_trip), '—')

  union all
  select 4, 'عروض أُرسلت لها',
         coalesce((select count(*)::text from public.trip_offers o
                   where o.trip_id = (select id from last_trip)), '0'),
         coalesce((select string_agg(status::text, ', ')
                   from public.trip_offers o
                   where o.trip_id = (select id from last_trip)), '—')

  -- ٣ ────────────────────────────────────────────────────────────────
  union all
  select 5, 'السائق متاح للمطابقة؟',
         case when (select is_available_for_matching from drv) then 'نعم'
              else 'لا ✗' end,
         coalesce((select 'حالة: ' || status::text || ' · اعتماد: ' ||
                   verification_status::text from drv), 'لا يوجد سائق')

  union all
  select 6, 'عمر موقع السائق',
         coalesce((select loc_age::text || ' ثانية' from drv), 'لا موقع ✗'),
         case when (select loc_age from drv) is null then 'لم يُرسل موقع قط ✗'
              when (select loc_age from drv) > 90
                then 'أكبر من ٩٠ ← يُستبعد من البحث ✗'
              else 'ضمن الحد ✓' end

  -- ٤ ────────────────────────────────────────────────────────────────
  union all
  select 7, 'البحث الجغرافي يجده؟',
         coalesce((
           select count(*)::text from last_trip t,
           lateral public.find_nearby_drivers(t.pickup_location, 20000, 5)
         ), '—'),
         coalesce((
           select f.distance_m::text || ' متر عن نقطة الانطلاق'
           from last_trip t,
           lateral public.find_nearby_drivers(t.pickup_location, 20000, 1) f
         ), 'لم يجد أحداً ✗')

  -- ٥ ── سلسلة الإشعار ───────────────────────────────────────────────
  -- تُفحص حتى لو نجحت المطابقة: العرض قد يُنشأ في القاعدة ولا يصل
  -- الهاتف، وهو عطل مختلف تماماً عن ألا يُنشأ عرض أصلاً.
  union all
  select 8, 'رمز الإشعار للسائق مخزّن؟',
         case when (select fcm_token from drv) is null then 'لا ✗' else 'نعم' end,
         coalesce((select left(fcm_token, 14) || '…' from drv),
                  'profiles.fcm_token فارغ — التطبيق لم يسجّله ✗')

  union all
  select 9, 'إعدادات الإشعار مضبوطة؟',
         (select count(*)::text from public.app_config
          where key in ('edge_notify_url', 'edge_service_key')) || ' من ٢',
         case when (select count(*) from public.app_config
                    where key in ('edge_notify_url','edge_service_key')) = 2
              then 'الرابط والمفتاح موجودان ✓'
              else 'ناقص ← المُشغّل يخرج صامتاً بلا استدعاء ✗' end

  union all
  select 10, 'مُشغّل الإشعار مفعّل؟',
         coalesce((select case when tgenabled = 'O' then 'نعم' else 'معطّل ✗' end
                   from pg_trigger where tgname = 'trip_offers_notify'), 'غير موجود ✗'),
         '—'

  union all
  select 11, 'آخر استدعاء لدالة الإشعار',
         coalesce((select coalesce(status_code::text, 'بلا رد')
                   from net._http_response order by created desc limit 1),
                  'لا استدعاءات ✗'),
         coalesce((select coalesce(error_msg, left(content, 90), '—')
                   from net._http_response order by created desc limit 1),
                  'pg_net لم يُطلق طلباً قط')

  -- ٦ ────────────────────────────────────────────────────────────────
  union all
  select 12, 'تشغيل يدوي الآن',
         'نُفِّذ',
         (public.dispatch_tick())::text
) x
order by "#";
