import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  return {
    for (final r in rows as List) '${r['key']}': '${r['value']}',
  };
});
