// =============================================================================
// reset-password — تغيير كلمة المرور برمز الواتساب
// =============================================================================
// **الموضع الوحيد الذي يجوز فيه `service_role`.** تغيير كلمة مرور مستخدمٍ
// بلا جلسته يحتاج صلاحية المشرف، وهي صلاحيةٌ تقرأ كل جدول وتكتب فيه.
// فتبقى في أسرار الدوال الطرفية: لا في التطبيق، ولا في لوحة الويب، ولا
// في المستودع.
//
// **والدالة لا تحكم بشيء.** لا تقرأ رمزاً ولا تقارنه: تنادي
// `consume_reset_code` في القاعدة، وهي التي تتحقّق وتعدّ المحاولات
// وتُبطل الرمز. فمنطق الأمان في مكانٍ واحد يُراجَع، لا مكرَّرٌ هنا وهناك.
//
// ولو سُرّب رمزٌ لم يُغنِ سارقه: يُستهلك مرة واحدة، وينتهي بعد دقائق.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const { identifier, code, password } = await req.json();

    if (!identifier || !code || !password) {
      return json({ error: 'بيانات ناقصة' }, 400);
    }

    // **الحدّ الأدنى يُفحص هنا أيضاً.** التطبيق يفحصه، لكن من ينادي
    // الدالة مباشرةً يتجاوز التطبيق — وكلمةٌ من ثلاثة أحرف تُبطل كل ما
    // بنيناه فوقها.
    if (typeof password !== 'string' || password.length < 8) {
      return json({ error: 'كلمة المرور ثمانية أحرف على الأقل' }, 400);
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } },
    );

    // ١) القاعدة تتحقّق وتُبطل الرمز، وتعيد صاحبه.
    const { data: userId, error: rpcError } = await admin.rpc(
      'consume_reset_code',
      { p_identifier: String(identifier), p_code: String(code) },
    );

    if (rpcError || !userId) {
      // **رسالة القاعدة كما هي.** «الرمز غير صحيح» و«انتهت صلاحيته»
      // خبران مختلفان، وتوحيدهما يجعل الرجل يعيد إدخال رمزٍ ميت.
      return json({ error: rpcError?.message ?? 'رمز غير صالح' }, 400);
    }

    // ٢) الكلمة الجديدة.
    const { error: updError } = await admin.auth.admin.updateUserById(
      userId as string,
      { password },
    );

    if (updError) return json({ error: updError.message }, 400);

    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
