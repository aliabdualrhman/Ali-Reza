-- =============================================================================
-- ربط مُشغّل الإشعارات بدالة الحافة
-- =============================================================================
--
--   بدّل السطر ١٤ وحده — ولا شيء غيره في هذا الملف.
--
--   الخطأ السابق كان تبديل سطر التحقق بدل سطر الإدراج، فحُفظ النص
--   النموذجي في القاعدة. هذه النسخة فيها موضع واحد فقط.
--
-- =============================================================================

do $$
declare
  -- ═══════════════════════════════════════════════════════════════════
  v_service_key text := 'ضع_المفتاح_هنا';
  -- ═══════════════════════════════════════════════════════════════════

  v_url text := 'https://jacixgrnovflddrzbegd.supabase.co/functions/v1/notify-driver';
begin
  -- فشل مبكر صريح بدل قبول النص النموذجي بصمت
  if v_service_key = 'ضع_المفتاح_هنا' or length(v_service_key) < 30 then
    raise exception 'لم تبدّل المفتاح في السطر ١٥ من هذا الملف';
  end if;

  insert into public.app_config (key, value) values
    ('edge_notify_url',  v_url),
    ('edge_service_key', v_service_key)
  on conflict (key) do update
    set value = excluded.value, updated_at = now();

  raise notice 'رُبطت الإشعارات بنجاح';
end $$;


-- =============================================================================
-- تحقّق — لا يكشف المفتاح كاملاً
-- =============================================================================
select
  key as "المفتاح",
  case
    when key = 'edge_service_key' then left(value, 10) || '......' || right(value, 4)
    else value
  end as "القيمة",
  case
    when key = 'edge_service_key' and length(value) > 30 then 'مضبوط'
    when key = 'edge_notify_url' then 'مضبوط'
    else 'خطأ'
  end as "الحالة"
from public.app_config
order by key;
