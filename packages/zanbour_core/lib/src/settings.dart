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
        .inFilter('key', ['geoapify_key', 'tile_style']).timeout(timeout);

    final map = {
      for (final r in rows as List) '${r['key']}': '${r['value']}',
    };
    MapEndpoints.adopt(key: map['geoapify_key'], style: map['tile_style']);
  } catch (_) {
    // شبكةٌ أو سياسةٌ — يبقى مفتاح البناء عاملاً.
  }
}
