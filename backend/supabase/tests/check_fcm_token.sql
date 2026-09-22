select
  p.full_name as "الاسم",
  p.role      as "الدور",
  case when p.fcm_token is null then 'لا' else 'نعم ('||length(p.fcm_token)||' حرف)' end
              as "رمز الإشعارات"
from public.profiles p
where p.role = 'driver'
order by p.created_at desc;
