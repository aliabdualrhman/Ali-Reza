-- =============================================================================
-- 0087 — السعر الحقيقي للسلعة يُشعِر الراكب
-- =============================================================================
-- **`set_goods_price` لا تُغيّر الحالة**، فمُشغّل 0049/0086 لا يراها:
-- ذلك المُشغّل معلَّقٌ على `update of status` ويخرج فوراً إن لم تتبدّل.
-- فكان السائق يكتب ثمن السلعة الحقيقي — وقد يفوق التقدير أضعافاً —
-- ولا يعلم الراكب حتى يقف السائق ببابه ويطلب مبلغاً لم يسمع به.
--
-- **وهذا أخطر ما في التسوّق كلّه.** الجدال في الشارع على مالٍ لم
-- يُتَّفق عليه يُفقدنا الراكب والسائق معاً.
--
-- مُشغّلٌ ثانٍ إذن، على العمود وحده، يستدعي دالة الحافة نفسها
-- بحدثٍ اسمه `goods_priced`.

set search_path = public, extensions;


create or replace function public.notify_goods_priced()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text;
  v_key text;
begin
  -- **مرّةً واحدة في عمر الطلب.** يُملأ من `null` إلى رقم؛ وأي تحديثٍ
  -- بعده (تصحيحٌ من المدير مثلاً) لا يستحق إيقاظ الراكب ثانيةً.
  if new.goods_actual_iqd is null
     or old.goods_actual_iqd is not distinct from new.goods_actual_iqd then
    return new;
  end if;

  select value into v_url from public.app_config where key = 'edge_notify_rider_url';
  select value into v_key from public.app_config where key = 'edge_service_key';

  -- الإعداد ناقص — لا نُفشل كتابة السعر بسببه. السائق ينتظر الردّ،
  -- وإسقاطُ الطلب لأجل إشعارٍ يُعطّل التسوّق كلَّه.
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
                 'old_record', to_jsonb(old),
                 'event', 'goods_priced'
               ),
    timeout_milliseconds := 5000
  );

  return new;
end;
$fn$;


drop trigger if exists trips_notify_goods_priced on public.trips;
create trigger trips_notify_goods_priced
  after update of goods_actual_iqd on public.trips
  for each row execute function public.notify_goods_priced();


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select count(*) as "المُشغّل موجود (يجب ١)"
from pg_trigger
where tgrelid = 'public.trips'::regclass
  and tgname = 'trips_notify_goods_priced';
