// =============================================================================
// notify-driver — إرسال إشعار للسائق عند وصول عرض رحلة
// =============================================================================
// تُستدعى من مُشغّل في قاعدة البيانات فور إنشاء صف في trip_offers.
//
// **لماذا دالة Edge لا مُشغّل يرسل مباشرة؟** لأن واجهة FCM الحديثة تتطلب
// رمز OAuth مُوقَّعاً بمفتاح خاص (RS256). بوستغرس لا يستطيع توليده،
// والواجهة القديمة التي كانت تقبل مفتاحاً بسيطاً أُلغيت.
//
// **النشر:** من لوحة Supabase ← Edge Functions ← Deploy a new function
// الصق هذا الملف. ثم أضف السرّ:
//   Settings → Edge Functions → Secrets
//   FIREBASE_SERVICE_ACCOUNT = محتوى ملف مفتاح الخدمة (JSON كاملاً)
// =============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

// -----------------------------------------------------------------------------
// توليد رمز OAuth من مفتاح الخدمة
// -----------------------------------------------------------------------------
// نوقّع JWT بمفتاح الخدمة الخاص ونبادله برمز وصول. الرمز صالح ساعة،
// ونحن نطلبه في كل استدعاء — الدالة قصيرة العمر ولا تحتفظ بحالة.
async function getAccessToken(sa: Record<string, string>): Promise<string> {
  const now = Math.floor(Date.now() / 1000);

  const header = { alg: 'RS256', typ: 'JWT' };
  const claim = {
    iss: sa.client_email,
    scope: FCM_SCOPE,
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now,
  };

  const b64 = (o: unknown) =>
    btoa(JSON.stringify(o)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const unsigned = `${b64(header)}.${b64(claim)}`;

  // المفتاح يأتي بصيغة PEM؛ نجرّده من الترويسة والأسطر لنحوّله إلى بايتات
  const pem = sa.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(unsigned),
  );

  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${sigB64}`,
    }),
  });

  if (!res.ok) throw new Error(`فشل توليد رمز الوصول: ${await res.text()}`);
  return (await res.json()).access_token;
}

// -----------------------------------------------------------------------------
Deno.serve(async (req) => {
  try {
    const payload = await req.json();

    // المُشغّل يرسل الصف الجديد في record (صيغة Database Webhooks)
    const offer = payload.record ?? payload;
    const driverId: string | undefined = offer.driver_id;
    const tripId: string | undefined = offer.trip_id;

    if (!driverId || !tripId) {
      return new Response('حمولة ناقصة', { status: 400 });
    }

    // service_role هنا مقصود: الدالة تعمل على الخادم لا في التطبيق،
    // وتحتاج قراءة رمز إشعارات سائق ليس هو المستدعي.
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // **كل أجهزة السائق لا جهازاً واحداً.** كان الرمز عموداً في
    // `profiles`، فالحساب الواحد لا يحمل إلا رمز آخر جهاز دخل — ومن
    // دخل قبله يصير أعمى بلا أن يعلم. انظر 0048.
    const { data: devices } = await sb
      .from('user_devices')
      .select('token')
      .eq('user_id', driverId);

    // **نجمع المصدرين لا نختار بينهما.** الترحيل 0048 نسخ الرموز
    // القائمة إلى الجدول، والنسخ المنشورة على هواتف المختبِرين ما زالت
    // تكتب في العمود وحده. فلو قرأنا الجدول ووجدناه غير فارغ لأرسلنا
    // إلى رمزٍ قديم وتجاهلنا الرمز الحيّ في العمود — وهو ما يجعل
    // الإشعارات تتوقف عند أول إعادة تثبيت حتى يُحدِّث صاحبه التطبيق.
    const tokenSet = new Set((devices ?? []).map((d) => d.token as string));

    const { data: profile } = await sb
      .from('profiles')
      .select('fcm_token')
      .eq('id', driverId)
      .maybeSingle();

    if (profile?.fcm_token) tokenSet.add(profile.fcm_token as string);

    const tokens = [...tokenSet];

    if (tokens.length === 0) {
      // السائق لم يفتح التطبيق بعد أو خرج منه — ليس خطأً.
      // سيرى العرض إن كان التطبيق مفتوحاً عبر البثّ اللحظي.
      return new Response('لا يوجد رمز إشعارات', { status: 200 });
    }

    const { data: trip } = await sb
      .from('trips')
      // **الأعمدة تُذكر صراحةً، فما لم يُذكر لا يصل.** أضفنا شرط
      // `kind` أعلاه وكان يبقى `undefined` أبداً لولا هذا السطر —
      // فيصل طلب التسوّق باسم «طلب رحلة» ولا يشكو أحد.
      .select('fare_estimated_iqd, pickup_address, estimated_distance_m, '
        + 'stop_count, has_stopover, kind, goods_estimate_iqd, '
        // طلب المندوب: المتجر والمستلم والمركبة في نصّ الإشعار نفسه
        + 'shop_name, dropoff_address, vehicle_kind')
      .eq('id', tripId)
      .maybeSingle();

    const fare = Math.round(Number(trip?.fare_estimated_iqd ?? 0));
    const km = ((trip?.estimated_distance_m ?? 0) / 1000).toFixed(1);

    const sa = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT')!);
    const accessToken = await getAccessToken(sa);

    // **نوع الرحلة في نص الإشعار نفسه.** السائق يقرر من الإشعار وهو
    // يقود أحياناً، ولا يفتح التطبيق إلا وقد قرّر. رحلةٌ بمحطتين أو فيها
    // انتظار تغيّر ذلك القرار، فذكرُها هنا لا في الشاشة وحدها.
    const stops = Number(trip?.stop_count ?? 1);
    const kindSuffix =
      (stops > 1 ? ` · ${stops} محطات` : '') +
      (trip?.has_stopover ? ' · مع توقف' : '');

    // **طلب التسوّق يُعلَن في العنوان.** السائق يقرّر من الإشعار وهو
    // يقود، و«طلب رحلة» تُخفي أنه سيدفع من جيبه — فيقبل ثم يعتذر في
    // المتجر. وقيمة البضاعة أهمّ ما يحتاجه قبل القبول، فتسبق الأجرة.
    const shopping = trip?.kind === 'shopping';
    const goods = Math.round(Number(trip?.goods_estimate_iqd ?? 0));

    // **طلب المندوب: الأجرة أولاً، ثم ما قد يدفعه.** سعر التوصيل يحدده
    // التاجر فيتفاوت بين طلبٍ وآخر، وهو ما يقرّر به السائق؛ وثمن السلعة
    // يليه لأنه قد يُطلب منه مقدّماً عند المتجر.
    const delivery = trip?.kind === 'delivery';
    const tuktuk = trip?.vehicle_kind === 'tuktuk';

    const title = delivery
      ? `طلب مندوب${tuktuk ? ' (تكتك)' : ''} — توصيل ${fare} دينار`
      : shopping
      ? `طلب تسوّق — بضاعة ${goods} دينار`
      : `طلب رحلة — ${fare} دينار`;

    const body = delivery
      ? `من ${trip?.shop_name ?? 'متجر'} · ثمن السلعة ${goods} دينار · إلى ${trip?.dropoff_address ?? 'المستلم'}`
      : shopping
      ? `توصيل ${fare} دينار · ${km} كم · ${trip?.pickup_address ?? 'المتجر'}`
      : `${km} كم${kindSuffix} · ${trip?.pickup_address ?? 'موقع على الخريطة'}`;

    // ما تبقّى من عمر العرض، وهو أقصى ما يفيد إبقاء الرسالة حيّة.
    // نضيف خمس ثوانٍ هامشاً لفارق الساعات بين الخادم وفايربيز.
    const expiresAt = offer.expires_at ? Date.parse(offer.expires_at) : NaN;
    const ttlSeconds = Number.isNaN(expiresAt)
      ? 60
      : Math.max(15, Math.round((expiresAt - Date.now()) / 1000) + 5);

    const send = (token: string) => fetch(
      `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token,
            notification: {
              title,
              body,
            },
            data: {
              type: 'trip_offer',
              trip_id: tripId,
              offer_id: String(offer.id ?? ''),
              // يقرؤه التطبيق ليضبط عمر الإشعار على عمر العرض بالضبط،
              // بدل رقم ثابت ينفصل عنه كلما غيّرنا المهلة.
              expires_at: String(offer.expires_at ?? ''),
            },
            android: {
              // إشعار عادي الأولوية قد يتأخر دقائق في وضع توفير البطارية
              // ويصل بعد فوات الأوان.
              priority: 'high',
              // **كان ttl ثابتاً على ٢٠ ثانية.** وهو ليس مدة عرضٍ بل مدة
              // **محاولة التسليم**: إن كان الهاتف في وضع الخمول أو انقطعت
              // شبكته لحظةً، تُسقِط فايربيز الرسالة نهائياً بعد ٢٠ ثانية
              // ولا تصل أبداً. ثم صارت المهلة ٤٥ في 0018 وبقي هو ٢٠.
              //
              // هذا هو السبب الأول لـ"أحياناً لا يظهر الإشعار": لم يكن
              // عطلاً في الهاتف ولا في القناة — كانت الرسالة تُلقى.
              ttl: `${ttlSeconds}s`,
              notification: {
                channel_id: 'trip_offers_v2',
                sound: 'offer',
              },
            },
            // **بلا هذا القسم يصل الإشعار على iOS بلا صوتٍ ولا أولوية.**
            // القسم `android` لا تقرؤه آبل إطلاقاً — والصمت هنا يعني
            // سائقاً لا يسمع عرضاً يعيش ٤٥ ثانية.
            apns: {
              headers: {
                // ١٠ = فوريّ. الافتراضي ٥ فتؤجّله آبل لتوفير البطارية.
                'apns-priority': '10',
                'apns-expiration': String(
                  Math.floor(Date.now() / 1000) + ttlSeconds,
                ),
              },
              payload: {
                aps: {
                  // الاسم بامتداده، والملف في حزمة التطبيق لا في
                  // أصول فلاتر — آبل تبحث عنه في جذر الحزمة وحده.
                  sound: 'offer.wav',
                  // **يخترق وضع «عدم الإزعاج».** عرضٌ يعيش ٤٥ ثانية
                  // ليس إشعاراً عادياً، ومن كتم هاتفه ليلاً ما زال
                  // يريد رزقه.
                  'interruption-level': 'time-sensitive',
                },
              },
            },
          },
        }),
      },
    );

    // **بالتوازي لا بالتتابع.** العرض يعيش ٤٥ ثانية، وسائقٌ بثلاثة
    // أجهزة لا يحتمل ثلاث رحلات ذهاب وإياب متسلسلة إلى فايربيز.
    const results = await Promise.all(tokens.map(send));

    // **رمزٌ ميت يُحذف لا يُعاد إليه.** فايربيز تردّ 404 على رمز تثبيتٍ
    // مُزال؛ إبقاؤه يعني محاولة فاشلة في كل عرض إلى الأبد.
    const dead: string[] = [];
    let ok = 0;

    for (let i = 0; i < results.length; i++) {
      const res = results[i];
      if (res.ok) { ok++; continue; }
      const err = await res.text();
      if (res.status === 404 || err.includes('UNREGISTERED')) {
        dead.push(tokens[i]);
      } else {
        console.error('فشل إرسال الإشعار:', err);
      }
    }

    if (dead.length > 0) {
      await sb.from('user_devices').delete().in('token', dead);
    }

    // **لا نُفشل الطلب ما دام جهازٌ واحد وصله.** وحتى لو لم يصل أحد،
    // فالعرض قائم في القاعدة والتطبيق يستطلعه — والفشل هنا ليس فشل
    // الإرسال بل فشل التنبيه وحده.
    if (ok === 0 && tokens.length > 0) {
      console.error(`لم يصل الإشعار إلى أيٍّ من ${tokens.length} جهاز`);
    }

    return new Response(`أُرسل إلى ${ok} من ${tokens.length}`, { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
