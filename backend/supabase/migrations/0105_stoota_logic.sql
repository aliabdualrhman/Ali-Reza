-- =============================================================================
-- 0105 — الستوتة: طلبات المتاجر وحدها، وحين يطلبها المتجر بالذات
-- =============================================================================
-- **يُطبَّق بعد 0104 لا معه** — انظر رأس ذلك الملف.
--
-- طلب علي: «ستوتة تُضاف إلى تطبيق السائق، ومن يسجّل بها تكون طلباته
-- مندوب توصيل فقط، والطلب إليه حصراً إذا طلب المتجر ستوتة».
--
-- فثلاثة أقفال، كلّها في القاعدة لا في التطبيق:
--
--   ١) المتجر يستطيع أن يطلب ستوتة (`request_delivery`).
--   ٢) طلبُ الستوتة يذهب إلى الستوتات وحدها، **وغيرُه لا يذهب إليها
--      أبداً** — لا ركّاب ولا تسوّق ولا توصيل بدراجة.
--   ٣) مفاتيح سائق الستوتة مثبّتة: التوصيل مفتوح، والركّاب والتسوّق
--      مغلقان — بمُشغّلٍ لا بواجهةٍ تُخفي زرّاً.
--
-- **ولماذا القفل الثالث بمُشغّل؟** لأن `accepts_rides` عمودٌ يُكتب من
-- دوالّ عدة؛ ونسيانُ واحدةٍ منها يعني ستوتةً تستقبل راكباً في الشارع.

set search_path = public, extensions;


-- -----------------------------------------------------------------------------
-- ١) الحدّ الأدنى لأجرة الستوتة
-- -----------------------------------------------------------------------------
insert into public.public_settings (key, value)
values ('delivery_min_fee_stoota_iqd', '5000')
on conflict (key) do nothing;


-- -----------------------------------------------------------------------------
-- ٢) البحث عن سائق — الستوتة معزولة في الاتجاهين
-- -----------------------------------------------------------------------------
create or replace function public.find_nearby_drivers(
  p_pickup   extensions.geography,
  p_radius_m integer  default 3000,
  p_limit    integer  default 10,
  p_exclude  uuid[]   default '{}'::uuid[],
  p_kind     public.vehicle_kind default 'bike'::public.vehicle_kind
)
returns table (
  driver_id     uuid,
  distance_m    integer,
  rating_avg    numeric,
  full_name     text,
  vehicle_plate text
)
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select
    d.id,
    st_distance(d.current_location, p_pickup)::integer as distance_m,
    d.rating_avg,
    p.full_name,
    d.vehicle_plate
  from public.drivers d
  join public.profiles p on p.id = d.id
  where d.is_available_for_matching
    and d.current_location is not null
    and d.location_updated_at > now() - interval '90 seconds'
    and not (d.id = any(p_exclude))
    and p.is_blocked = false
    and st_dwithin(d.current_location, p_pickup, p_radius_m)
    -- **الستوتة أولاً.** `p_kind` فارغٌ في التسوّق ويعني «أي مركبة» —
    -- وذلك يشمل الستوتة لو لم نستثنها هنا صراحةً. فالقاعدة: طلب الستوتة
    -- للستوتات وحدها، وكلُّ ما عداه ليس لها.
    and (case
           when p_kind = 'stoota' then d.vehicle_kind = 'stoota'
           else d.vehicle_kind <> 'stoota'
         end)
    and (
      p_kind is null
      or case p_kind
           when 'stoota' then true
           when 'tuktuk' then d.vehicle_kind = 'tuktuk'
           else d.vehicle_kind = 'bike'
                or (d.vehicle_kind = 'tuktuk' and d.accepts_bike_trips)
         end
    )
    and not exists (
      select 1 from public.trips t
      where t.driver_id = d.id
        and t.status in ('accepted', 'driver_arrived', 'in_progress')
    )
  order by st_distance(d.current_location, p_pickup)
  limit p_limit;
$fn$;


-- -----------------------------------------------------------------------------
-- ٣) المتجر يطلب ستوتة
-- -----------------------------------------------------------------------------
-- **سطران يُستبدلان في التعريف الحيّ لا إعادةُ كتابة الدالة.** طولها
-- مئتا سطر، ونسخُها بيدٍ يُسقط منطقاً — كما وقع في 0080.
do $do$
declare
  v_def text;
  v_old1 constant text :=
    '    when ''tuktuk'' then ''tuktuk''::public.vehicle_kind' || E'\r\n' || '  end;';
  v_new1 constant text :=
    '    when ''tuktuk'' then ''tuktuk''::public.vehicle_kind' || E'\r\n' ||
    '    when ''stoota'' then ''stoota''::public.vehicle_kind' || E'\r\n' || '  end;';
  v_old2 constant text :=
    '  v_min := case v_kind' || E'\r\n' ||
    '    when ''tuktuk'' then public.referral_setting(''delivery_min_fee_tuktuk_iqd'', 3000)';
  v_new2 constant text :=
    '  v_min := case v_kind' || E'\r\n' ||
    '    when ''stoota'' then public.referral_setting(''delivery_min_fee_stoota_iqd'', 5000)' || E'\r\n' ||
    '    when ''tuktuk'' then public.referral_setting(''delivery_min_fee_tuktuk_iqd'', 3000)';
  v_old3 constant text :=
    'case when v_kind = ''tuktuk'' then '' بالتكتك'' else '''' end;';
  v_new3 constant text :=
    'case v_kind when ''tuktuk'' then '' بالتكتك'' when ''stoota'' then '' بالستوتة'' else '''' end;';
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.proname = 'request_delivery';

  if v_def is null then
    raise exception 'request_delivery غير موجودة';
  end if;

  if position('''stoota''' in v_def) > 0 then
    return;  -- طُبّق من قبل
  end if;

  if position(v_old1 in v_def) = 0
     or position(v_old2 in v_def) = 0
     or position(v_old3 in v_def) = 0 then
    raise exception 'request_delivery تغيّرت — عدّلها يدوياً بدل هذا الاستبدال';
  end if;

  v_def := replace(v_def, v_old1, v_new1);
  v_def := replace(v_def, v_old2, v_new2);
  v_def := replace(v_def, v_old3, v_new3);
  execute v_def;
end;
$do$;


-- -----------------------------------------------------------------------------
-- ٤) مفاتيح سائق الستوتة مثبّتة
-- -----------------------------------------------------------------------------
create or replace function public.force_stoota_switches()
returns trigger
language plpgsql
set search_path = public, extensions
as $fn$
begin
  if new.vehicle_kind = 'stoota' then
    -- التوصيل وحده. والقيم تُفرض لا تُرفض: دالةٌ تكتب `accepts_rides`
    -- لسائق ستوتة لا تُفشل عملها، بل لا يُكتب لها أثر.
    new.accepts_delivery       := true;
    new.accepts_rides          := false;
    new.accepts_shopping       := false;
    new.accepts_bike_trips     := false;
    new.accepts_bike_deliveries := false;
  end if;
  return new;
end;
$fn$;

drop trigger if exists drivers_force_stoota on public.drivers;
create trigger drivers_force_stoota
  before insert or update on public.drivers
  for each row execute function public.force_stoota_switches();

-- وتصحيح ما سُجِّل قبل المُشغّل (إن وُجد).
update public.drivers
set accepts_delivery = true,
    accepts_rides = false,
    accepts_shopping = false
where vehicle_kind = 'stoota'
  and (accepts_delivery is distinct from true
       or accepts_rides is distinct from false
       or accepts_shopping is distinct from false);


-- -----------------------------------------------------------------------------
-- فحص بعد التطبيق
-- -----------------------------------------------------------------------------
select
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'request_delivery'
     and prosrc like '%stoota%')                      as "المتجر يطلب ستوتة (١)",
  (select count(*) from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname = 'find_nearby_drivers'
     and prosrc like '%stoota%')                      as "التوزيع يعزل الستوتة (١)",
  (select count(*) from pg_trigger
   where tgname = 'drivers_force_stoota')             as "مفاتيح الستوتة مثبّتة (١)",
  (select value from public.public_settings
   where key = 'delivery_min_fee_stoota_iqd')         as "أقل أجرة ستوتة";
