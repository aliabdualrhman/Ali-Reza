-- =============================================================================
-- 0061 — دفع الإشعارات وجدولتها
-- =============================================================================
-- 0060 يكتب الإشعار في القاعدة فيراه الجرس فوراً. وهذا الملف يوصله إلى
-- الهواتف، ويُطلق المجدول في وقته.
--
-- **الطبقتان مقصودتان لا مكرّرتان:**
--
--   • **الجرس** يصل الجميع — حتى من لا يملك خدمات Google. لكنه لا
--     يُوقظ أحداً: لا يراه إلا من فتح التطبيق.
--
--   • **الدفع** يُوقظ الهاتف، ويسقط عن جزءٍ من جمهورنا.
--
-- ولا غنى عن واحدةٍ منهما. **ولهذا نكتب أولاً ثم ندفع**: لو فشل الدفع
-- كله بقي الإشعار محفوظاً يُقرأ، ولم نخسر الرسالة.
--
-- **شرط مسبق:** انشر الدالة `notify-broadcast` من لوحة Supabase، ثم
-- أضف عنوانها إلى `app_config` (السطر في آخر الملف).

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) المُشغّل يدفع ما كُتب
-- -----------------------------------------------------------------------------
create or replace function public.push_notification_row()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text;
  v_key text;
begin
  select value into v_url from public.app_config where key = 'edge_broadcast_url';
  select value into v_key from public.app_config where key = 'edge_service_key';

  -- **الإعداد ناقص لا يُسقط الإرسال.** الإشعار مكتوبٌ ويُقرأ في الجرس؛
  -- وإفشالُ الكتابة لأن الدفع غير مضبوط يخسرنا الرسالة كلها.
  if v_url is null or v_key is null then
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := jsonb_build_object('record', to_jsonb(new)),
    -- **مهلةٌ أطول من إشعار العرض.** ذاك يخصّ هاتفاً واحداً، وهذا قد
    -- يخاطب مئات — والدفع بالدفعات يحتاج وقتاً.
    timeout_milliseconds := 20000
  );

  return new;
end;
$fn$;

drop trigger if exists notifications_push on public.notifications;
create trigger notifications_push
  after insert on public.notifications
  for each row execute function public.push_notification_row();


-- -----------------------------------------------------------------------------
-- ٢) المجدول
-- -----------------------------------------------------------------------------
-- **يمرّ كل ساعة لا كل دقيقة.** الجدولة بالساعة لا بالدقيقة، ومرورٌ
-- كل دقيقة يعني ١٤٤٠ استعلاماً يومياً ليعمل أحدها.
create or replace function public.run_notification_schedules()
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_row   record;
  v_now   timestamptz := now();
  -- بغداد UTC+3 بلا توقيت صيفي. `at time zone` يقرأ قاعدة IANA فيبقى
  -- صحيحاً لو تغيّر القانون يوماً.
  v_local timestamptz := v_now at time zone 'Asia/Baghdad';
  v_hour  integer := extract(hour from (v_now at time zone 'Asia/Baghdad'));
  v_dow   integer := extract(dow  from (v_now at time zone 'Asia/Baghdad'));
  v_sent  integer := 0;
begin
  for v_row in
    select s.*, t.title, t.body
    from public.notification_schedules s
    join public.notification_templates t on t.id = s.template_id
    where s.is_active
      and s.send_at_hour = v_hour
      and (s.frequency <> 'weekly' or s.weekday = v_dow)
      -- **حارسٌ ضد التكرار.** لو مرّ المجدول مرتين في الساعة نفسها —
      -- وهو يحدث عند إعادة تشغيل أو تأخّر — لأرسل الرسالة مرتين.
      and (s.last_sent_at is null
           or s.last_sent_at < v_now - interval '23 hours')
  loop
    insert into public.notifications
      (audience, title, body, kind, sent_by, recipients)
    values (
      v_row.audience, v_row.title, v_row.body, 'scheduled', v_row.created_by,
      public.notification_audience_count(v_row.audience, false)
    );

    update public.notification_schedules
    set last_sent_at = v_now
    where id = v_row.id;

    update public.notification_templates
    set used_count = used_count + 1
    where id = v_row.template_id;

    -- **مرةً واحدة تعني مرةً واحدة.** الجدولة `once` تُطفأ بعد إرسالها،
    -- وإلا عادت في اليوم التالي بلا أن يطلبها أحد.
    if v_row.frequency = 'once' then
      update public.notification_schedules
      set is_active = false where id = v_row.id;
    end if;

    v_sent := v_sent + 1;
  end loop;

  return v_sent;
end;
$fn$;


-- **إجراءٌ لا دالة، وبلا `security definer` ولا `set`.** كلاهما يجعل
-- السياق ذرّياً فيمنع `commit` — وهو الدرس الذي كلّفنا شهراً من التوزيع
-- المعطّل في 0040.
create or replace procedure public.notification_schedule_tick()
language plpgsql
as $proc$
begin
  perform public.run_notification_schedules();
  commit;
exception when others then
  raise warning 'تعذّر تشغيل المجدول: %', sqlerrm;
end;
$proc$;


do $$
begin
  perform cron.unschedule('notification-schedules');
exception when others then null;
end $$;

select cron.schedule(
  'notification-schedules',
  '5 * * * *',            -- الدقيقة الخامسة من كل ساعة
  $$call public.notification_schedule_tick()$$
);


-- -----------------------------------------------------------------------------
-- ٣) الصلاحيات
-- -----------------------------------------------------------------------------
revoke all on function public.run_notification_schedules() from public, anon;


-- =============================================================================
-- بعد نشر الدالة، شغّل هذا (احذف علامات التعليق)
-- =============================================================================
/*
insert into public.app_config (key, value) values
  ('edge_broadcast_url',
   'https://jacixgrnovflddrzbegd.supabase.co/functions/v1/notify-broadcast')
on conflict (key) do update set value = excluded.value, updated_at = now();
*/


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  jobname as "المهمة",
  schedule as "الجدول",
  active   as "مفعّلة"
from cron.job
where jobname = 'notification-schedules';
