-- =============================================================================
-- 0113 — حلّ رقم الهاتف أو البريد إلى بريد الدخول
-- =============================================================================
-- تسجيل الدخول كان بالبريد وحده. السائق يكتب عند التسجيل رقمه، ويريده
-- لاحقاً للدخول. GoTrue لا يدخل بالهاتف هنا (الهوية بريد)، فنحلّ
-- المعرّف إلى البريد المخزَّن في profiles قبل signInWithPassword.
--
-- يُنادى قبل الجلسة → صلاحية anon.

set search_path = public, extensions;


create or replace function public.resolve_login_email(p_identifier text)
returns text
language plpgsql
stable
security definer
set search_path = public, extensions
as $fn$
declare
  v_id     text := btrim(coalesce(p_identifier, ''));
  v_digits text := regexp_replace(v_id, '[^0-9]', '', 'g');
  v_phone  text;
  v_email  text;
begin
  if v_id = '' then
    return null;
  end if;

  -- نفس توحيد الرقم في التسجيل واستعادة كلمة المرور.
  if v_digits ~ '^07[3-9][0-9]{8}$' then
    v_phone := '+964' || substring(v_digits from 2);
  elsif v_digits ~ '^9647[3-9][0-9]{8}$' then
    v_phone := '+' || v_digits;
  elsif v_digits ~ '^7[3-9][0-9]{8}$' then
    v_phone := '+964' || v_digits;
  end if;

  if v_phone is not null then
    select p.email into v_email
    from public.profiles p
    where p.phone = v_phone
      and p.deleted_at is null
    limit 1;
  elsif position('@' in v_id) > 0 then
    select p.email into v_email
    from public.profiles p
    where lower(p.email) = lower(v_id)
      and p.deleted_at is null
    limit 1;
  end if;

  return nullif(btrim(coalesce(v_email, '')), '');
end;
$fn$;


revoke all on function public.resolve_login_email(text) from public;
grant execute on function public.resolve_login_email(text) to anon, authenticated;
