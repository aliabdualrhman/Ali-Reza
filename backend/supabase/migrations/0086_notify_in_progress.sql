-- =============================================================================
-- 0086 — مرحلة «بدأت» تُشعِر أيضاً — لطلب التسوّق
-- =============================================================================
-- **مُشغّل 0049 لا يمرّر `in_progress` إطلاقاً**، وكان ذلك صحيحاً حين
-- كانت الرحلة رحلةَ راكب: تبدأ والراكب على الدراجة ينظر إلى السائق،
-- فإشعارٌ حينها ضجيج.
--
-- **أما التسوّق فالراكب في بيته.** ومراحله ثلاث لا اثنتان:
--
--   وصل السائق إلى المتجر  →  تسوّق وخرج إليك  →  وصل إلى بابك
--
-- والوسطى هي `in_progress`، وهي أهمّها: بها يعرف الراكب أن الشراء تمّ
-- وأنّ عليه أن يجهّز نقده. وكانت تمرّ صامتة.
--
-- **ولا نُشعر برحلة الراكب عند `in_progress`.** دالة الحافة تردّ
-- `null` لها، فالمرور بالمُشغّل لا يُنتج إشعاراً — يكلّف طلب HTTP
-- واحداً ويُنهيه الفحص هناك. وذلك أهون من مُشغّلين متوازيين.

set search_path = public, extensions;


create or replace function public.notify_rider_of_status()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text;
  v_key text;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- **`in_progress` أُضيفت.** انظر رأس الملف: التسوّق يحتاجها،
  -- والرحلة العادية تُصفّى في دالة الحافة.
  if new.status not in
     ('accepted','driver_arrived','in_progress','completed',
      'cancelled','no_drivers') then
    return new;
  end if;

  select value into v_url from public.app_config where key = 'edge_notify_rider_url';
  select value into v_key from public.app_config where key = 'edge_service_key';

  -- الإعداد ناقص — لا نُفشل تحديث الرحلة بسببه. الإشعار تحسين لا شرط.
  if v_url is null or v_key is null then
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := jsonb_build_object(
                 'record', to_jsonb(new),
                 'old_record', to_jsonb(old)
               ),
    timeout_milliseconds := 5000
  );

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select count(*) as "in_progress مُمرَّرة (يجب ١)"
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname = 'notify_rider_of_status'
  and prosrc like '%in_progress%';
