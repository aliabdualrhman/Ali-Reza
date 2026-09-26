import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'settings.dart';

/// زرّ «شرح استخدام التطبيق» — يفتح صفحة الشروحات في المتصفّح.
///
/// **الوجهة من اللوحة لا من الكود** (0121). صفحةُ اليوم قد تصير نطاقاً
/// خاصاً غداً أو قناةَ فيديو؛ وعنوانٌ مكتوبٌ هنا يعني بناءً ونشراً
/// ومراجعةَ متجرٍ لتبديل رابط.
///
/// **ويختفي حين لا يُضبط الرابط** — كزرّ الدعم تماماً. من يضغط زرّاً
/// فلا يُفتح شيء يظنّ التطبيق معطوباً، وغيابُ الزرّ أهون من ذلك.
///
/// **وخارج التطبيق لا داخله.** الشروحات فيديوهات على يوتيوب، وعرضُها
/// في `WebView` يعني شاشةً تُحمّل ببطء ولا تعرف ملء الشاشة ولا الصوت
/// في الخلفية — والمتصفّح يفعل ذلك كلّه ومعه تطبيق يوتيوب إن كان
/// مثبَّتاً.
class GuideButton extends ConsumerWidget {
  const GuideButton({
    super.key,
    this.label = 'شرح استخدام التطبيق',
    this.filled = false,
  });

  final String label;

  /// بارزٌ حيث يحتاجه المستخدم فعلاً (شاشة الانتظار، شاشة الضيف)،
  /// وهادئٌ في «حسابي» حيث يتصفّح لا يستنجد.
  final bool filled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = (ref.watch(publicSettingsProvider).value?['guides_url'] ?? '')
        .trim();
    if (url.isEmpty) return const SizedBox.shrink();

    final icon = const Icon(Icons.play_circle_outline);
    final text = Text(label);

    return filled
        ? FilledButton.tonalIcon(
            onPressed: () => _open(context, url),
            icon: icon,
            label: text,
          )
        : OutlinedButton.icon(
            onPressed: () => _open(context, url),
            icon: icon,
            label: text,
          );
  }

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    // **رابطٌ فاسد لا يمرّ صامتاً.** المدير قد يلصق نصّاً ناقصاً،
    // و`launchUrl` يردّ `false` بلا كلمة — فيضغط المستخدم ولا يحدث شيء.
    final ok = uri == null
        ? false
        : await launchUrl(uri, mode: LaunchMode.externalApplication)
            .catchError((_) => false);

    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر فتح صفحة الشروحات')),
      );
    }
  }
}
