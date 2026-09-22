set search_path = public, extensions;

-- =============================================================================
-- إنشاء أو ترقية حساب المدير
-- =============================================================================
-- يتعامل مع الحالتين: إن وُجد الحساب رقّاه، وإن لم يوجد أنشأه كاملاً.
-- آمن للتكرار — تشغيله مرتين لا يُنشئ حسابين.
--
-- **قبل التشغيل: بدّل القيم الثلاث في الأسفل.**
--
-- ⚠️ كلمة المرور تظهر في نص هذا الاستعلام. بعد التشغيل امسح المحرر،
--    ولا تحفظ الاستعلام في Supabase (لا تضغط Save).
-- =============================================================================

do $$
declare
  -- ---------------------------------------------------------------------------
  -- بدّل هذه الثلاث فقط
  -- ---------------------------------------------------------------------------
  v_email    text := 'ali.alkawary@gmail.com';
  v_password text := 'ضع_كلمة_مرور_جديدة_هنا';
  v_phone    text := '+9647701234567';   -- رقم غير مستعمل في أي حساب آخر
  -- ---------------------------------------------------------------------------

  v_uid uuid;
begin
  -- نتحقق أولاً وبصوت عالٍ.
  --
  -- النسخة السابقة كانت تتخطى تحديث كلمة المرور بصمت إن بقي النص
  -- النموذجي، فيُرقّى الحساب ويبدو كل شيء ناجحاً ثم يفشل الدخول بلا
  -- سبب ظاهر. الفشل المبكر الصريح أفضل من نجاح ناقص.
  if v_password = 'ضع_كلمة_مرور_جديدة_هنا' or length(v_password) < 8 then
    raise exception 'بدّل v_password في أعلى السكربت — ٨ أحرف على الأقل';
  end if;

  if v_phone !~ '^\+9647[3-9][0-9]{8}$' then
    raise exception 'رقم هاتف غير صحيح: %  (الصيغة: +9647XXXXXXXXX)', v_phone;
  end if;

  -- نرفع علم تجاوز الحُرّاس **لكل المسارات** لا لمسار الإنشاء وحده.
  --
  -- المُشغّل guard_profile_columns يمنع تغيير الدور، ويسمح بالتجاوز لمن
  -- رفع هذا العلم أو كان مديراً أصلاً. ولا مدير بعد — فهذه هي المعضلة
  -- التي يحلّها هذا السكربت، والعلم هو مفتاحها.
  --
  -- العلم محلي للمعاملة ويزول بانتهائها، ولا يستطيع المستخدم رفعه من
  -- التطبيق لأنه لا يملك صلاحية استدعاء set_config على هذا النطاق.
  perform set_config('app.bypass_guards', 'on', true);

  -- ١) هل الحساب موجود؟
  select id into v_uid from auth.users where email = v_email;

  if v_uid is not null then
    raise notice 'الحساب موجود — ترقية فقط';

    -- نضمن وجود صف profiles (قد يكون الحساب أُنشئ قبل المُشغّل)
    if not exists (select 1 from public.profiles where id = v_uid) then
      insert into public.profiles
        (id, full_name, email, date_of_birth, address, phone, role)
      values
        (v_uid, 'مدير النظام زنبور', v_email,
         date '1990-01-01', 'بغداد - الإدارة', v_phone, 'admin');
      raise notice 'أُنشئ الملف الشخصي';
    else
      -- المُشغّل guard_profile_columns يمنع تغيير الدور من التطبيق.
      -- هنا نعمل بصلاحيات مالك القاعدة، وهو المسار الوحيد المسموح
      -- لصناعة أول مدير — وإلا لاستطاع أي مستخدم ترقية نفسه.
      update public.profiles set role = 'admin' where id = v_uid;
      raise notice 'رُقّي الحساب إلى مدير';
    end if;

    -- تحديث كلمة المرور — **بلا شرط**.
    --
    -- Supabase يخزّنها بـ bcrypt، و crypt(...) من pgcrypto تنتج نفس
    -- الصيغة التي يتوقعها. نصفّر أيضاً أي حظر أو انتظار تأكيد قد يمنع
    -- الدخول بصمت.
    update auth.users
    set encrypted_password  = crypt(v_password, gen_salt('bf')),
        email_confirmed_at  = coalesce(email_confirmed_at, now()),
        banned_until        = null,
        updated_at          = now()
    where id = v_uid;
    raise notice 'حُدّثت كلمة المرور';

  else
    -- ٢) لا يوجد حساب — ننشئه كاملاً
    v_uid := gen_random_uuid();

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data
    ) values (
      '00000000-0000-0000-0000-000000000000', v_uid,
      'authenticated', 'authenticated', v_email,
      crypt(v_password, gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      -- نمرّر rider لأن المُشغّل يرفض admin عمداً؛ نرقّيه بعد الإنشاء.
      jsonb_build_object(
        'role', 'rider',
        'full_name', 'مدير النظام زنبور',
        'phone', v_phone,
        'date_of_birth', '1990-01-01',
        'address', 'بغداد - الإدارة'
      )
    );

    update public.profiles set role = 'admin' where id = v_uid;
    raise notice 'أُنشئ حساب المدير';
  end if;

  perform set_config('app.bypass_guards', 'off', true);
end $$;

-- =============================================================================
-- تحقّق
-- =============================================================================
select
  p.full_name  as "الاسم",
  p.email      as "البريد",
  p.role       as "الدور",
  p.phone      as "الهاتف",
  case when u.email_confirmed_at is not null then 'نعم' else 'لا' end
               as "البريد مؤكَّد"
from public.profiles p
join auth.users u on u.id = p.id
where p.role = 'admin';
