-- =============================================================================
-- 0083 — حارس إلغاء التسوّق يخصّ الراكب وحده
-- =============================================================================
-- **بنيتُه لأمنع الراكب فمنعتُ الجميع.** المنطق كان: لا يُلغى طلبٌ بعد
-- أن يشتريه السائق — وذلك صحيحٌ في حقّ **الراكب**: أن يُلغي بعد أن
-- أنفق غيره ماله سرقةٌ لا انسحاب.
--
-- **أما السائق فهو صاحب المال المخاطَر به.** إن ألغى بعد الشراء خسر
-- بضاعةً في يده، والخسارة خسارته وحده. ومنعُه بحجّة حمايته عبث: قد لا
-- يردّ الراكب على الهاتف، أو يرفض الاستلام، أو يتبيّن أن العنوان خطأ —
-- فيبقى السائق محبوساً في طلبٍ لا مخرج منه، ولا يستطيع أن يقبل غيره
-- لأن الفهرس يمنع رحلتين نشطتين.
--
-- **وحبسُه أسوأ من خسارته:** خسر بضاعةً بعشرين ألفاً، ثم نمنعه من
-- العمل بقيّة يومه.
--
-- ويبقى الأثر: إلغاء السائق يُسجَّل كما هو مسجَّلٌ اليوم، ورسوم إلغائه
-- تسري كالمعتاد — والمدير يرى في اللوحة من ألغى ومتى وبكم.

set search_path = public, extensions;


create or replace function public.guard_shopping_cancel()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.status <> 'cancelled' or old.status = 'cancelled' then
    return new;
  end if;
  if old.kind <> 'shopping' then return new; end if;

  -- المدير يفكّ كل شيء — انظر 0081.
  if public.is_admin() then
    perform public.log_action(
      'shopping.admin_cancel', 'trips', new.id::text,
      format('ألغى المدير طلب تسوّقٍ مشترى — %s دينار بضاعة',
             coalesce(old.goods_actual_iqd, 0)::bigint)
    );
    return new;
  end if;

  -- **السائق يلغي ولو بعد الشراء.** ماله هو، وخسارته هو. انظر رأس
  -- الملف.
  if auth.uid() is distinct from old.rider_id then
    return new;
  end if;

  -- **الراكب وحده يُمنع**، وبعد الشراء وحده.
  if old.goods_actual_iqd is not null
     and coalesce(current_setting('app.bypass_guards', true), 'off') <> 'on'
  then
    raise exception
      'اشترى السائق طلبك فعلاً — لا يمكن الإلغاء. تواصل مع الدعم.';
  end if;

  return new;
end;
$fn$;


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select count(*) as "استثناء السائق مثبَّت (يجب ١)"
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname = 'guard_shopping_cancel'
  and prosrc like '%old.rider_id%';
