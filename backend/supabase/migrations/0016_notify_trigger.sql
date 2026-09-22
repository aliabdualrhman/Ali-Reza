set search_path = public, extensions;

-- =============================================================================
-- 0016 — استدعاء دالة الإشعارات عند إنشاء عرض
-- =============================================================================
-- **شرط مسبق:** انشر الدالة `notify-driver` من لوحة Supabase أولاً، وأضف
-- سرّ `FIREBASE_SERVICE_ACCOUNT`. بدونهما يفشل الاستدعاء بصمت (وهو مقبول
-- — العرض يصل عبر البثّ اللحظي ما دام التطبيق مفتوحاً).
-- =============================================================================

-- pg_net يتيح لبوستغرس إطلاق طلبات HTTP **غير متزامنة**.
--
-- عدم التزامن جوهري هنا: لو انتظر المُشغّل رد Firebase لتأخّر إنشاء العرض
-- ثانية أو ثانيتين — وهي عمر ثمين من مهلة الخمس عشرة ثانية.
create extension if not exists pg_net with schema extensions;

-- -----------------------------------------------------------------------------
-- إعدادات الاستدعاء
-- -----------------------------------------------------------------------------
-- نخزّنها في جدول لا في نص الدالة: تغيير المفتاح لاحقاً يصير تحديث صف
-- بدل إعادة تعريف دالة.
--
-- **لا يُقرأ من التطبيق إطلاقاً** — RLS مفعّلة بلا سياسة قراءة، فحتى
-- المدير لا يراه من اللوحة. الدوال security definer وحدها تصل إليه.
-- -----------------------------------------------------------------------------
create table if not exists public.app_config (
  key         text primary key,
  value       text not null,
  updated_at  timestamptz not null default now()
);

alter table public.app_config enable row level security;
-- لا سياسات: لا أحد يقرأ ولا يكتب من التطبيق. عمداً.

comment on table public.app_config is
  'إعدادات داخلية للخادم. لا تُقرأ من التطبيقات — RLS بلا سياسات.';

-- -----------------------------------------------------------------------------
-- المُشغّل
-- -----------------------------------------------------------------------------
create or replace function public.notify_driver_of_offer()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text;
  v_key text;
begin
  select value into v_url from public.app_config where key = 'edge_notify_url';
  select value into v_key from public.app_config where key = 'edge_service_key';

  -- الإعداد ناقص — لا نُفشل إنشاء العرض بسببه.
  --
  -- الإشعار تحسين لا شرط: العرض يصل عبر البثّ اللحظي ما دام التطبيق
  -- مفتوحاً. إسقاط الرحلة لأن الإشعار لم يُضبط خطأ فادح.
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
    timeout_milliseconds := 5000
  );

  return new;
end;
$$;

drop trigger if exists trip_offers_notify on public.trip_offers;
create trigger trip_offers_notify
  after insert on public.trip_offers
  for each row execute function public.notify_driver_of_offer();

-- =============================================================================
-- بعد نشر الدالة، شغّل هذا بقيمك (احذف علامات التعليق)
-- =============================================================================
-- المفتاح المطلوب هو **service_role** من Settings → API. يُخزَّن في القاعدة
-- ولا يصل التطبيقات إطلاقاً — RLS بلا سياسات تمنع قراءته.
-- =============================================================================
/*
insert into public.app_config (key, value) values
  ('edge_notify_url',
   'https://jacixgrnovflddrzbegd.supabase.co/functions/v1/notify-driver'),
  ('edge_service_key', 'ضع_service_role_key_هنا')
on conflict (key) do update set value = excluded.value, updated_at = now();
*/

-- تحقّق من التركيب
select
  tgname                                        as "المُشغّل",
  case when tgenabled = 'O' then 'مفعّل' else 'معطّل' end as "الحالة",
  (select count(*) from public.app_config)      as "إعدادات مضبوطة"
from pg_trigger
where tgname = 'trip_offers_notify';
