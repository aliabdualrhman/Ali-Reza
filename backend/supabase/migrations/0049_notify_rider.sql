-- =============================================================================
-- 0049 — الراكب يُشعَر بتقدّم رحلته
-- =============================================================================
-- **النقص.** تطبيق الراكب بلا إشعارات إطلاقاً — لا رمز ولا قناة ولا
-- مُشغّل. يطلب رحلةً ثم يقفل الشاشة لحظةً، وهو ما يفعله كل إنسان، فلا
-- يعلم أن سائقاً قبِل، ولا أنه وصل ويقف بالباب، ولا أن الطلب أُلغي.
--
-- **وأثقلها `driver_arrived`.** السائق واقفٌ في الشارع والراكب داخل
-- البيت ينتظر ولا يعلم. دقيقتان وينصرف السائق ويُلغى الطلب، ويخسر
-- الطرفان — ونحن نخسر الاثنين معاً.
--
-- **ولماذا مُشغّل على `trips` لا استدعاء من الكود؟** لأن الحالة تتغيّر
-- من أماكن كثيرة: قبول السائق، وصوله، إلغاء الراكب، إلغاء المدير،
-- انتهاء المهلة في `dispatch_tick`. مُشغّلٌ واحد على الجدول يلتقطها
-- كلها؛ واستدعاءٌ في كل موضع يُنسى في أحدها ولا أحد يلاحظ.
--
-- **شرط مسبق:** انشر الدالة `notify-rider` من لوحة Supabase، ثم أضف
-- عنوانها إلى `app_config` (السطر في آخر الملف).

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- المُشغّل
-- -----------------------------------------------------------------------------
create or replace function public.notify_rider_of_status()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text;
  v_key text;
begin
  -- **حارسٌ في القاعدة لا في الدالة وحدها.** كل تحديث لصفّ الرحلة يُطلق
  -- المُشغّل — ورفعُ الأجرة وتغيير الوجهة وتحديث الموقع تحديثاتٌ لا
  -- تغيّر الحالة. بلا هذا السطر نُرسل طلب HTTP في كل واحد منها.
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- الحالات التي لا تستحق إيقاظ أحد. الدالة تفحصها أيضاً، لكنّ الفحص
  -- هنا يوفّر الطلب من أصله.
  if new.status not in
     ('accepted','driver_arrived','completed','cancelled','no_drivers') then
    return new;
  end if;

  select value into v_url from public.app_config where key = 'edge_notify_rider_url';
  select value into v_key from public.app_config where key = 'edge_service_key';

  -- الإعداد ناقص — لا نُفشل تحديث الرحلة بسببه. الإشعار تحسين لا شرط:
  -- الشاشة تتابع الحالة لحظياً ما دام التطبيق مفتوحاً.
  if v_url is null or v_key is null then
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               ),
    -- **نمرّر الصفّ القديم أيضاً.** الدالة تحتاجه لتتأكد أن الحالة
    -- تبدّلت فعلاً — حارسان أهون من إشعارٍ مكرّر على هاتف راكب.
    body    := jsonb_build_object(
                 'record', to_jsonb(new),
                 'old_record', to_jsonb(old)
               ),
    timeout_milliseconds := 5000
  );

  return new;
end;
$$;

drop trigger if exists trips_notify_rider on public.trips;
create trigger trips_notify_rider
  after update of status on public.trips
  for each row execute function public.notify_rider_of_status();


-- =============================================================================
-- بعد نشر الدالة، شغّل هذا (احذف علامات التعليق)
-- =============================================================================
/*
insert into public.app_config (key, value) values
  ('edge_notify_rider_url',
   'https://jacixgrnovflddrzbegd.supabase.co/functions/v1/notify-rider')
on conflict (key) do update set value = excluded.value, updated_at = now();
*/


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  tgname as "المُشغّل",
  case when tgenabled = 'O' then 'مفعّل' else 'معطّل' end as "الحالة",
  (select count(*) from public.app_config
   where key = 'edge_notify_rider_url')                  as "العنوان مضبوط"
from pg_trigger
where tgname = 'trips_notify_rider';
