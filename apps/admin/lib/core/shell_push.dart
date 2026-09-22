import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;

/// إشعارات المدير على هاتفه — حين تُفتح اللوحة داخل تطبيق المدير.
///
/// **التطبيق يملك الرمز، واللوحة تعرف صاحبه.** تطبيق المدير (`admin_shell`)
/// نافذةٌ على هذه اللوحة: يحصل على رمز Firebase ولا يعرف من دخل، واللوحة
/// تعرف من دخل ولا تستطيع أن تحصل على رمز هاتف. فيضع التطبيق الرمز في
/// `window.zanbourPushToken` ويُطلق الحدث `zanbour-push-token`، واللوحة
/// تسجّله باسم المدير في `user_devices` كأيّ هاتف.
///
/// وفي متصفحٍ عادي لا رمز ولا حدث — فلا يحدث شيء.
class ShellPush {
  ShellPush._();

  static String? _token() {
    final v = globalContext.getProperty<JSAny?>('zanbourPushToken'.toJS);
    if (v == null || !v.isA<JSString>()) return null;
    final t = (v as JSString).toDart.trim();
    return t.isEmpty ? null : t;
  }

  static void start(SupabaseClient sb) {
    Future<void> register() async {
      final t = _token();
      if (t == null || sb.auth.currentUser == null) return;
      try {
        await sb.rpc('register_device',
            params: {'p_token': t, 'p_platform': 'android'});
      } catch (_) {
        // الإشعار ميزةٌ لا شرطٌ لعمل اللوحة
      }
    }

    // **جسمٌ لا سهم:** السهم يُرجع Future، والدالة المحوَّلة للمتصفح لا
    // تقبل إلا void — والمحلّل لا يرى ذلك، البناء وحده يرفضه.
    web.window.addEventListener('zanbour-push-token', ((web.Event _) {
      register();
    }).toJS);
    sb.auth.onAuthStateChange.listen((s) {
      if (s.session != null) register();
    });
    register();
  }

  /// **قبل الخروج لا بعده** — بعد الخروج لا جلسة تأذن بالحذف. وبدونه
  /// يبقى الهاتف يستقبل إشعارات المدير وقد خرج منه.
  static Future<void> unregister(SupabaseClient sb) async {
    final t = _token();
    if (t == null || sb.auth.currentUser == null) return;
    try {
      await sb.rpc('unregister_device', params: {'p_token': t});
    } catch (_) {}
  }
}
