// =============================================================================
// send-otp — إرسال رمز التحقق عبر واتساب (OTPIQ)
// =============================================================================
// تُستدعى من مُشغّل على `phone_verifications` فور كتابة الصفّ.
//
// **لماذا دالة حافة لا نداءٌ من التطبيق؟** لأن مفتاح OTPIQ سرّي
// (`sk_live_…`) ومن يملكه يرسل رسائل على حسابنا حتى ينفد الرصيد. ومفتاحٌ
// في تطبيقٍ منشور مقروءٌ لمن يفكّ الحزمة — وهو ما ينطبق على
// `service_role` أيضاً، ولنفس السبب لم نضعه في لوحة المدير.
//
// **والرمز يمرّ ولا يُخزَّن.** القاعدة تحفظ مُجزَّأه فقط، وتمرّر النصّ في
// حمولة هذا النداء وحدها.
//
// **النشر:** Supabase ← Edge Functions ← Deploy a new function ← send-otp
// ثم أضف السرّ:
//   Settings → Edge Functions → Secrets
//   OTPIQ_KEY = sk_live_...
// =============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';

const OTPIQ_URL = 'https://api.otpiq.com/api/sms';

Deno.serve(async (req) => {
  try {
    const { id, phone, code } = await req.json();

    if (!id || !phone || !code) {
      return new Response('حمولة ناقصة', { status: 400 });
    }

    const key = Deno.env.get('OTPIQ_KEY');
    if (!key) {
      console.error('OTPIQ_KEY غير مضبوط');
      return new Response('المزوّد غير مضبوط', { status: 500 });
    }

    // **الصيغة الدولية بلا علامة زائد.** المزوّد يطلب ١٠–١٥ رقماً:
    // `+9647701234567` تصير `9647701234567`. ونحذف الفراغات والشُّرَط
    // احتياطاً — رقمٌ يُنسخ من مكانٍ آخر قد يحملها.
    const to = String(phone).replace(/[^0-9]/g, '');

    const res = await fetch(OTPIQ_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        phoneNumber: to,
        smsType: 'verification',
        verificationCode: String(code),

        // **واتساب ثم رسالة نصّية.** واتساب أرخص وأوثق وصولاً في العراق،
        // ومن لا يملكه تصله رسالة عادية. والمزوّد يتولّى الارتداد بنفسه
        // فلا نبني منطقاً ثانياً نصونه.
        provider: 'whatsapp-sms',
      }),
    });

    const body = await res.json().catch(() => ({}));

    if (!res.ok) {
      // **نسجّل ولا نكشف.** رسالة المزوّد قد تحمل تفاصيل حساب، والمستخدم
      // يرى «تعذّر الإرسال» فحسب.
      console.error('فشل إرسال الرمز:', res.status, JSON.stringify(body));
      return new Response('تعذّر إرسال الرمز', { status: 502 });
    }

    // **نحفظ معرّف المزوّد.** حين يشكو مستخدم أن الرمز لم يصل، هذا
    // المعرّف هو ما يُسأل به المزوّد — وبدونه لا سبيل لتتبّع رسالةٍ بعينها.
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    await sb
      .from('phone_verifications')
      .update({ provider_id: body.smsId ?? null })
      .eq('id', id);

    // **الرصيد في السجلّ لا في تنبيه.** رصيدٌ ينفد ليلاً يوقف كل تسجيل،
    // وسطرٌ في السجلّ يجعل السبب ظاهراً في ثانية بدل ساعة تخمين.
    if (typeof body.remainingCredit === 'number') {
      console.log(`رصيد OTPIQ المتبقّي: ${body.remainingCredit} دينار`);
      if (body.remainingCredit < 5000) {
        console.warn('⚠️ رصيد OTPIQ منخفض — اشحن قبل أن يتوقف التوثيق');
      }
    }

    return new Response('أُرسل', { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
