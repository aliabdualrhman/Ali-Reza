import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'map_endpoints.dart';

/// إعدادات عامة يديرها المدير من اللوحة.
///
/// **بيانات لا ثوابت.** رقم شراء الرصيد يتغيّر، والرصيد الترحيبي يتغيّر —
/// وكتابتهما في الكود تعني بناءً ونشراً لكل تعديل. الجدول `public_settings`
/// مقروء لكل مستخدم مسجّل، ولا يحمل سرّاً واحداً بحكم التصميم.
/// **`autoDispose` مقصود.** بدونه تُجلب الإعدادات مرة واحدة وتبقى في
/// الذاكرة حتى يُغلق التطبيق: من فتحه قبل أن يضبط المدير رقم الدعم يبقى
/// لا يرى الزر حتى يعيد التشغيل، ولا شيء يخبره بذلك. مع `autoDispose`
/// تُجلب من جديد كلما فُتحت شاشة تحتاجها.
final publicSettingsProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final rows = await Supabase.instance.client
      .from('public_settings')
      .select('key, value');

  final map = {
    for (final r in rows as List) '${r['key']}': '${r['value']}',
  };

  // كلّ جلبٍ للإعدادات يحدّث مفتاح الخرائط أيضاً — بلا نداءٍ ثانٍ.
  MapEndpoints.adopt(key: map['geoapify_key'], style: map['tile_style']);
  AuthFlags.adopt(map['email_enabled']);
  NavLinks.adopt(map['nav_waze_url']);
  return map;
});

/// يجلب مفاتيح الخرائط عند الإقلاع ويسلّمها إلى [MapEndpoints].
///
/// **يُنادى ولا يُنتظَر طويلاً.** الإقلاع لا يقف على شبكة: لو تأخّرت،
/// يعمل التطبيق بمفتاح البناء وتصل القيمة الجديدة عند أول شاشةٍ تقرأ
/// الإعدادات. ولهذا يبتلع خطأه صامتاً — فشلُ الجلب ليس فشلَ إقلاع.
///
/// **وسياسة `anon` تكفيه.** الضيف يرى خريطةً قبل الدخول، وسياسة 0119
/// ترشّح الصفوف فتمرّر مفتاحَي الإقلاع وحدهما.
Future<void> loadMapConfig(
  SupabaseClient sb, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  try {
    final rows = await sb
        .from('public_settings')
        .select('key, value')
        .inFilter('key', ['geoapify_key', 'tile_style', 'email_enabled', 'nav_waze_url'])
        .timeout(timeout);

    final map = {
      for (final r in rows as List) '${r['key']}': '${r['value']}',
    };
    MapEndpoints.adopt(key: map['geoapify_key'], style: map['tile_style']);
    AuthFlags.adopt(map['email_enabled']);
    NavLinks.adopt(map['nav_waze_url']);
  } catch (_) {
    // شبكةٌ أو سياسةٌ — يبقى مفتاح البناء عاملاً.
  }
}


/// هل البريد مفعّل في التسجيل والدخول؟ — مفتاحٌ في لوحة المدير (0139).
///
/// **يُقرأ عند الإقلاع مع مفتاح الخرائط** (`loadMapConfig`)، ومع كلّ جلبٍ
/// للإعدادات. فيُطفئه المدير ويختفي البريد عند الفتحة التالية — بلا تحديث.
///
/// **والافتراضي مفعّل.** شبكةٌ لم تصل عند الإقلاع يجب ألّا تُخفي حقلاً
/// يحتاجه المستخدم: أسوأ ما يقع حينها أن يرى حقل بريدٍ اختياري، لا أن
/// يُحرم من الدخول. والدخول بالرقم يعمل في الحالتين.
class AuthFlags {
  const AuthFlags._();

  static bool _emailEnabled = true;

  static bool get emailEnabled => _emailEnabled;

  /// يتبنّى القيمة النصّية من `public_settings` — والغائب لا يغيّر شيئاً.
  static void adopt(String? raw) {
    if (raw == null) return;
    final v = raw.trim().toLowerCase();
    if (v.isEmpty) return;
    _emailEnabled = const {'1', 'true', 'yes', 'on'}.contains(v);
  }
}


/// روابط تطبيقات الملاحة — من لوحة المدير (0141) لا من داخل التطبيق.
///
/// **لماذا في اللوحة؟** في 2026-10-01 صار Waze يفتح ولا يرسم مساراً، لأن
/// رابطه القديم (`waze://`) لم يعد يُدعم كاملاً — وكان مكتوباً في التطبيق،
/// فلزم تحديثٌ للمتجرين. قال علي: «كلّ مرّةٍ يحدّث Waze أحدّث تطبيقي؟
/// غير منطقي». فصار الرابط قالباً في الإعدادات: إن غيّرت Waze رابطها يوماً
/// يُبدَّل من اللوحة ويصل السائقين عند الفتحة التالية.
///
/// **القالب يحمل `{lat}` و`{lng}`** — وما لا يحملهما يُتجاهَل، فلا يكسر
/// خطأٌ مطبعيّ في اللوحة الملاحةَ عند كلّ السائقين.
class NavLinks {
  const NavLinks._();

  static const _wazeDefault =
      'https://waze.com/ul?ll={lat}%2C{lng}&navigate=yes';
  static String? _waze;

  static void adopt(String? waze) {
    final v = waze?.trim() ?? '';
    if (v.contains('{lat}') && v.contains('{lng}')) _waze = v;
  }

  /// رابط Waze إلى الوجهة، يبدأ الملاحة.
  static Uri waze(double lat, double lng) => Uri.parse((_waze ?? _wazeDefault)
      .replaceAll('{lat}', '$lat')
      .replaceAll('{lng}', '$lng'));
}
