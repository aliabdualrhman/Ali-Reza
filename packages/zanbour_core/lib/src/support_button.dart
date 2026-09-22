import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'settings.dart';

/// زر الدعم — يفتح واتساب المدير برسالة تعريف جاهزة.
///
/// **يختفي حين لا يكون الرقم مضبوطاً.** زرُّ دعم يفتح رقماً فارغاً أو
/// خاطئاً أسوأ من غياب الزر: المستخدم يظن أنه راسل الدعم ويبقى ينتظر
/// رداً لا يأتي، ثم يحكم على الخدمة كلها بأنها تتجاهله.
///
/// **وليس في الواجهة الرئيسية بقرار صريح.** موضعه في الشاشات التي يصل
/// إليها من عنده مشكلة فعلاً — الرصيد والرحلات — لا في أول ما يراه.
/// زرُّ دعم بارز يوحي بأن المنتج يتعطّل كثيراً.
class SupportButton extends ConsumerWidget {
  const SupportButton({
    super.key,
    required this.settingKey,
    required this.message,
    this.label = 'الدعم',
  });

  /// مفتاح الرقم في `public_settings`: للسائقين أو للركّاب.
  final String settingKey;

  /// رسالة التعريف التي تُملأ في خانة الكتابة.
  final String message;

  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phone = ref.watch(publicSettingsProvider).value?[settingKey] ?? '';
    if (phone.trim().isEmpty) return const SizedBox.shrink();

    return OutlinedButton.icon(
      onPressed: () => _open(phone),
      icon: const Icon(Icons.support_agent),
      label: Text(label),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
    );
  }

  Future<void> _open(String phone) async {
    // واتساب يقبل الرقم بأرقامه فقط: بلا + ولا مسافات ولا شَرَطات.
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    final uri = Uri.parse(
        'https://wa.me/$digits?text=${Uri.encodeComponent(message)}');
    // externalApplication يفتح التطبيق نفسه لا متصفحاً داخلياً يطلب
    // ضغطة زائدة على شاشة "افتح في التطبيق".
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
