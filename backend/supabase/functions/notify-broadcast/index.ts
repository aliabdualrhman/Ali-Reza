// =============================================================================
// notify-broadcast — إشعارات المدير: بثٌّ لجمهور أو رسالةٌ لشخص
// =============================================================================
// تُستدعى من مُشغّل على `notifications` فور كتابة الصفّ.
//
// **والصفّ مكتوبٌ قبلنا لا بنا.** الجرس داخل التطبيق يقرؤه فوراً، وهذه
// الدالة تُوقظ الهواتف فحسب. فلو سقطت كلها بقيت الرسالة تُقرأ — وهو
// المطلوب في سوقٍ ثلثُ أجهزته بلا خدمات Google.
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
// **الدفع بالدفعات.** واجهة FCM تقبل رمزاً واحداً في الطلب، وخمسمئة
// طلبٍ متوازٍ تخنق الدالة وتُرفض من جوجل. فندفع خمسين معاً وننتظر.
const BATCH = 50;

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const n = payload.record ?? payload;

    const title: string = n.title ?? '';
    const body: string = n.body ?? '';
    if (!title || !body) {
      return new Response('حمولة ناقصة', { status: 400 });
    }

    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // ---- من يستقبل؟ ----
    let userIds: string[] = [];

    if (n.user_id) {
      userIds = [n.user_id as string];
    } else {
      // **نستبعد المحظور والمحذوف هنا أيضاً.** العدّ في القاعدة
      // يستبعدهما، لكنّ الدفع مسارٌ آخر — ومن يُحظر بين الكتابة والدفع
      // لا يجوز أن تصله رسالتنا.
      const roles = n.audience === 'both'
        ? ['rider', 'driver']
        : [n.audience as string];

      const { data: people } = await sb
        .from('profiles')
        .select('id')
        .in('role', roles)
        .eq('is_blocked', false)
        .is('deleted_at', null);

      userIds = (people ?? []).map((p) => p.id as string);
    }

    if (userIds.length === 0) {
      return new Response('لا مستقبِلين', { status: 200 });
    }

    // ---- أجهزتهم ----
    const tokenSet = new Set<string>();

    // `in` يقبل قائمةً محدودة الطول؛ نقسّمها.
    for (let i = 0; i < userIds.length; i += 200) {
      const slice = userIds.slice(i, i + 200);

      const { data: devices } = await sb
        .from('user_devices')
        .select('token')
        .in('user_id', slice);
      for (const d of devices ?? []) tokenSet.add(d.token as string);

      // الرجوع إلى العمود القديم لمن لم يُحدّث تطبيقه بعد.
      const { data: profs } = await sb
        .from('profiles')
        .select('fcm_token')
        .in('id', slice)
        .not('fcm_token', 'is', null);
      for (const p of profs ?? []) tokenSet.add(p.fcm_token as string);
    }

    const tokens = [...tokenSet];
    if (tokens.length === 0) {
      return new Response('لا أجهزة مسجَّلة', { status: 200 });
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
            notification: { title, body },
            data: {
              type: 'admin_notice',
              notification_id: String(n.id ?? ''),
            },
            android: {
              // **عاديةٌ لا عاجلة.** إعلانٌ من الإدارة لا يستحق إيقاظ
              // هاتفٍ من خموله؛ والعاجل محفوظ لعرض رحلةٍ يموت بعد ثوانٍ.
              priority: 'normal',
              ttl: '86400s',
              notification: { channel_id: 'admin_notices', sound: 'notice' },
            },
            apns: {
              headers: { 'apns-priority': '5' },
              // **نغمتنا لا نغمة النظام.** كانت `default`، فيصل إشعار
              // زنبور على iOS بصوتٍ يشبه كل تطبيقٍ آخر — والنغمة
              // المميّزة نصفُ التعرّف على المرسِل.
              payload: { aps: { sound: 'notice.wav' } },
            },
          },
        }),
      },
    );

    let ok = 0;
    const dead: string[] = [];

    for (let i = 0; i < tokens.length; i += BATCH) {
      const chunk = tokens.slice(i, i + BATCH);
      const results = await Promise.all(chunk.map(send));

      for (let j = 0; j < results.length; j++) {
        const res = results[j];
        if (res.ok) { ok++; continue; }
        const err = await res.text();
        if (res.status === 404 || err.includes('UNREGISTERED')) {
          dead.push(chunk[j]);
        }
      }
    }

    // رمزٌ ميت يُحذف: إبقاؤه محاولةٌ فاشلة في كل بثٍّ إلى الأبد.
    for (let i = 0; i < dead.length; i += 200) {
      await sb.from('user_devices').delete().in('token', dead.slice(i, i + 200));
    }

    // **نكتب ما وصل فعلاً.** المدير يرى «٤١٢ من ٥٠٠» فيعرف حجم من لا
    // تصله الإشعارات — وهي معلومةٌ تُغيّر قراراته لا تجمّل تقريره.
    if (n.id) {
      await sb.from('notifications')
        .update({ delivered: ok })
        .eq('id', n.id);
    }

    return new Response(`أُرسل إلى ${ok} من ${tokens.length}`, { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
