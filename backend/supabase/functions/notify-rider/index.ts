// =============================================================================
// notify-rider — إشعار الراكب بتقدّم رحلته
// =============================================================================
// تُستدعى من مُشغّل يراقب تغيّر `trips.status`.
//
// **لماذا احتجناها؟** كان الراكب بلا إشعارات إطلاقاً. يطلب رحلة، ثم
// يقفل الشاشة لحظةً — وهو ما يفعله كل إنسان — فلا يعلم أن سائقاً قبِل،
// ولا أنه وصل ويقف بالباب، ولا أن الطلب أُلغي. يبقى محدّقاً في الشاشة
// أو يفوته السائق. وهذا وحده يكفي لتقييمات سيئة في المتجر.
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
// نصّ الإشعار حسب الحالة
// -----------------------------------------------------------------------------
// **لا نُشعر بكل تغيّر.** `in_progress` يحدث والراكب على الدراجة ينظر
// إلى السائق؛ إشعارٌ حينها ضجيج. نُشعر بما يحتاج فعلاً منه.
function messageFor(
  status: string,
  driverName: string | null,
  plate: string | null,
  byDriver: boolean,
  shopping: boolean,
): { title: string; body: string } | null {
  const who = driverName ?? 'السائق';
  const car = plate ? ` · ${plate}` : '';

  switch (status) {
    // **مراحل التسوّق ليست مراحل الرحلة.** السائق يقصد المحل أولاً،
    // فـ«في الطريق إليك» عند القبول كذبةٌ تجعل الراكب ينزل إلى الباب
    // ويقف ربع ساعة. والمراحل هنا ثلاث: إلى المحل، ثم إليك، ثم وصل.
    case 'accepted':
      return shopping
        ? {
            title: 'قُبل طلبك',
            body: `${who} في طريقه إلى المتجر${car}`,
          }
        : {
            title: 'قُبل طلبك',
            body: `${who} في الطريق إليك${car}`,
          };
    case 'driver_arrived':
      return shopping
        ? {
            title: 'وصل السائق إلى المتجر',
            body: `${who} يشتري طلبك الآن.`,
          }
        : {
            title: 'السائق وصل',
            body: `${who} بانتظارك في نقطة الانطلاق${car}`,
          };
    // **المرحلة الوسطى — للتسوّق وحده.** بها يعرف الراكب أن الشراء تمّ
    // وأنّ عليه أن يجهّز نقده. والرحلة العادية تبدأ والراكب على الدراجة
    // ينظر إلى السائق، فإشعارٌ حينها ضجيج.
    case 'in_progress':
      return shopping
        ? {
            title: 'تمّ التسوّق',
            body: `${who} في طريقه إليك${car}`,
          }
        : null;
    case 'completed':
      return shopping
        ? {
            title: 'وصل طلبك',
            body: `وصل ${who} إلى نقطة التسليم.`,
          }
        : {
            title: 'انتهت رحلتك',
            body: 'قيّم سائقك — تقييمك يساعد غيرك.',
          };
    case 'cancelled':
      // **من ألغى؟ سؤالٌ يسأله الراكب أولاً.** إشعارٌ يقول «أُلغيت
      // الرحلة» وهو لم يُلغِ شيئاً يجعله يظنّ التطبيق معطوباً، أو
      // يتّهم نفسه بأنه ضغط زرّاً بالخطأ. ومن يعرف أن السائق اعتذر
      // يطلب غيره في الحال بدل أن يتصل بالدعم.
      return byDriver
        ? {
            title: 'أُلغيت الرحلة من قبل السائق',
            body: 'اعتذر السائق. اطلب رحلة أخرى ويصلك سائقٌ آخر.',
          }
        : {
            title: 'أُلغيت الرحلة',
            body: 'يمكنك طلب رحلة أخرى الآن.',
          };
    case 'no_drivers':
      return {
        title: 'لا يوجد سائق متاح',
        body: 'لم نجد سائقاً قريباً. جرّب بعد قليل أو ارفع الأجرة.',
      };
    default:
      // searching و in_progress وغيرهما: لا إشعار.
      return null;
  }
}

// -----------------------------------------------------------------------------
// طلب المندوب — «الراكب» هنا تاجرٌ، والطرد يمرّ بمراحل غير مراحل الرحلة
// -----------------------------------------------------------------------------
// **رقم الطلب في كل رسالة.** التاجر قد يكون له خمسة مناديب في الطريق؛
// «وصل المندوب» بلا رقم لا تقول له أيّ طرد.
// deno-lint-ignore no-explicit-any
function deliveryMessage(status: string, who: string, byDriver: boolean, t: any):
  { title: string; body: string } | null {
  const n = t.trip_number ?? '';
  const fee = Math.round(Number(t.fare_final_iqd ?? t.fare_locked_iqd ?? t.fare_estimated_iqd ?? 0));
  const goods = Math.round(Number(t.goods_actual_iqd ?? 0));

  switch (status) {
    case 'accepted':
      return { title: 'قُبل طلب المندوب', body: `${who} في طريقه إلى متجرك — الطلب رقم ${n}.` };
    case 'driver_arrived':
      return {
        title: 'المندوب وصل',
        body: `${who} عند متجرك الآن — الطلب رقم ${n}. اتفقا على طريقة الدفع من التطبيق.`,
      };
    case 'in_progress':
      return { title: 'استلم المندوب الطلب', body: `${who} في طريقه إلى المستلم — الطلب رقم ${n}.` };
    case 'completed':
      if (t.delivery_outcome === 'returned') {
        // المندوب لم يقبض من المستلم؛ التاجر يدفع أجرته، ويردّ الثمن إن
        // كان المندوب دفعه مقدّماً.
        const due = fee + (t.pay_mode === 'prepay' ? goods : 0);
        return {
          title: 'أُعيد الطرد إلى متجرك',
          body: `أعاد ${who} الطلب رقم ${n}. تدفع له ${due} دينار.`,
        };
      }
      return {
        title: 'تم توصيل الطلب',
        body: `سلّم ${who} الطلب رقم ${n} إلى المستلم.` +
          (t.pay_mode === 'after' && goods > 0 ? ` بذمّته لك ${goods} دينار.` : ''),
      };
    case 'cancelled':
      return byDriver
        ? { title: 'اعتذر المندوب', body: `أُلغي الطلب رقم ${n} من المندوب. اطلب مندوباً آخر.` }
        : { title: 'أُلغي طلب المندوب', body: `الطلب رقم ${n}.` };
    case 'no_drivers':
      return {
        title: 'لم نجد مندوباً',
        body: `الطلب رقم ${n} — لا مندوب متاح الآن. أعد الطلب بعد قليل أو ارفع سعر التوصيل.`,
      };
    default:
      return null;
  }
}

// -----------------------------------------------------------------------------
Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const trip = payload.record ?? payload;
    const old = payload.old_record ?? null;

    const riderId: string | undefined = trip.rider_id;
    const status: string | undefined = trip.status;

    if (!riderId || !status) {
      return new Response('حمولة ناقصة', { status: 400 });
    }

    // **لا نُكرّر على نفس الحالة.** المُشغّل يُطلق على أي تحديث للصف —
    // ورفعُ الأجرة أو تغيير الوجهة تحديثان لا يغيّران الحالة. بلا هذا
    // الحارس يرنّ هاتف الراكب مرتين لقبولٍ واحد.
    // **ولا يُطبَّق على حدث `goods_priced`.** ذاك يقع والحالة ثابتة
    // بطبيعته — السائق في المتجر يكتب ثمناً — فالحارس كان يبتلعه.
    if (payload.event !== 'goods_priced' && old && old.status === status) {
      return new Response('لا تغيّر في الحالة', { status: 200 });
    }

    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    let driverName: string | null = null;
    let plate: string | null = null;

    if (trip.driver_id) {
      const { data: d } = await sb
        .from('profiles')
        .select('full_name')
        .eq('id', trip.driver_id)
        .maybeSingle();
      // **الاسم الأول وحده.** الاسم الثلاثي في عنوان إشعار يُقتطع، ولا
      // يضيف شيئاً — الراكب يعرف سائقه باللوحة لا بالنسب.
      driverName = (d?.full_name as string | null)?.split(' ')[0] ?? null;

      const { data: v } = await sb
        .from('drivers')
        .select('vehicle_plate')
        .eq('id', trip.driver_id)
        .maybeSingle();
      plate = (v?.vehicle_plate as string | null) ?? null;
    }

    // **من ألغى؟** `cancelled_by` يُملأ في `cancel_trip` بمن ضغط
    // الزرّ. ومقارنته بـ`driver_id` تكفي: ليس في الرحلة إلا طرفان.
    const byDriver = trip.driver_id != null &&
      trip.cancelled_by === trip.driver_id;

    const shopping = trip.kind === 'shopping';

    // **حدثٌ لا حالة.** مُشغّل 0087 يستدعينا حين يكتب السائق ثمن السلعة
    // الحقيقي — والحالة لم تتبدّل، فلا يصلح لها `messageFor`.
    //
    // ويحمل الرقمين معاً: الفرق هو الخبر، لا الرقم الجديد وحده. راكبٌ
    // قدّر ٥٠٠٠ فصارت ٨٠٠٠ يستحق أن يعرف ذلك قبل أن يقف السائق ببابه.
    let msg: { title: string; body: string } | null;

    if (payload.event === 'goods_priced') {
      const goods = Number(trip.goods_actual_iqd ?? 0);
      const fare = Number(trip.fare_final_iqd ?? trip.fare_estimated_iqd ?? 0);
      const discount = Number(trip.discount_iqd ?? 0);
      const total = Math.round(fare - discount + goods);

      msg = {
        title: 'تمّ إبلاغك بالأسعار الحقيقية',
        body: `ثمن السلعة ${Math.round(goods)} دينار في السوق. ` +
          `المجموع ${total} دينار مع أجرة التوصيل.`,
      };
    } else if (trip.kind === 'delivery') {
      msg = deliveryMessage(status, driverName ?? 'المندوب', byDriver, trip);
    } else {
      msg = messageFor(status, driverName, plate, byDriver, shopping);
    }

    if (!msg) return new Response('حالة لا تستحق إشعاراً', { status: 200 });

    const { data: devices } = await sb
      .from('user_devices')
      .select('token')
      .eq('user_id', riderId);

    // **نجمع المصدرين لا نختار بينهما.** الترحيل 0048 نسخ الرموز
    // القائمة إلى الجدول، والنسخ المنشورة على هواتف المختبِرين ما زالت
    // تكتب في العمود وحده. فلو قرأنا الجدول ووجدناه غير فارغ لأرسلنا
    // إلى رمزٍ قديم وتجاهلنا الرمز الحيّ في العمود — وهو ما يجعل
    // الإشعارات تتوقف عند أول إعادة تثبيت حتى يُحدِّث صاحبه التطبيق.
    const tokenSet = new Set((devices ?? []).map((d) => d.token as string));

    const { data: profile } = await sb
      .from('profiles')
      .select('fcm_token')
      .eq('id', riderId)
      .maybeSingle();

    if (profile?.fcm_token) tokenSet.add(profile.fcm_token as string);

    const tokens = [...tokenSet];

    if (tokens.length === 0) {
      return new Response('لا يوجد رمز إشعارات', { status: 200 });
    }

    const sa = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT')!);
    const accessToken = await getAccessToken(sa);

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
            notification: { title: msg.title, body: msg.body },
            data: {
              type: payload.event === 'goods_priced'
                ? 'goods_priced'
                : 'trip_status',
              trip_id: String(trip.id ?? ''),
              status,
            },
            android: {
              // **وصول السائق وحده عاجل.** الراكب قد يكون داخل البيت
              // والسائق ينتظر في الشارع؛ دقيقة تأخير هنا تُلغي رحلة.
              // وبقية الحالات لا تستحق إيقاظ الجهاز من خموله.
              priority: status === 'driver_arrived' ? 'high' : 'normal',
              ttl: '600s',
              notification: {
                channel_id: 'trip_status_v2',
                sound: 'notice',
              },
            },
            // **آبل لا تقرأ قسم `android` إطلاقاً.** بلا هذا يصل
            // الإشعار على iOS بالصوت الافتراضي وبأولوية مؤجَّلة.
            apns: {
              headers: {
                'apns-priority': status === 'driver_arrived' ? '10' : '5',
                'apns-expiration': String(Math.floor(Date.now() / 1000) + 600),
              },
              payload: {
                aps: {
                  sound: 'notice.wav',
                  // **وصول السائق وحده يخترق «عدم الإزعاج».** الراكب
                  // في البيت والسائق ينتظر في الشارع؛ دقيقة تأخير
                  // تُلغي رحلة. وبقية الحالات لا تستحق المقاطعة.
                  'interruption-level':
                    status === 'driver_arrived' ? 'time-sensitive' : 'active',
                },
              },
            },
          },
        }),
      },
    );

    const results = await Promise.all(tokens.map(send));

    const dead: string[] = [];
    let ok = 0;

    for (let i = 0; i < results.length; i++) {
      const res = results[i];
      if (res.ok) { ok++; continue; }
      const err = await res.text();
      if (res.status === 404 || err.includes('UNREGISTERED')) {
        dead.push(tokens[i]);
      } else {
        console.error('فشل إرسال إشعار الراكب:', err);
      }
    }

    if (dead.length > 0) {
      await sb.from('user_devices').delete().in('token', dead);
    }

    return new Response(`أُرسل إلى ${ok} من ${tokens.length}`, { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
