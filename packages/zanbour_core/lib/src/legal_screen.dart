import 'package:flutter/material.dart';

import 'legal_text.dart';

/// شاشة عرض الاتفاقية.
///
/// **نصّ محلي لا صفحة ويب.** المستخدم يوافق وقت التسجيل وقد يكون بلا
/// إنترنت مستقر، وصفحةٌ لا تفتح تعني موافقةً على ما لم يُقرأ — وهي أول
/// ما يسقط في أي نزاع.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key, required this.title, required this.body});

  const LegalScreen.rider({super.key})
      : title = 'شروط الاستخدام',
        body = kRiderTerms;

  const LegalScreen.driver({super.key})
      : title = 'اتفاقية السائق',
        body = kDriverTerms;

  final String title;
  final String body;

  static Future<void> open(BuildContext context, {required bool driver}) {
    return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          driver ? const LegalScreen.driver() : const LegalScreen.rider(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            child: SelectableText(
              body.trim(),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.75),
            ),
          ),
        ),
      ),
    );
  }
}

/// سطر الموافقة في شاشة التسجيل، مع رابط يفتح النص.
///
/// **الكلمة قابلة للضغط لا الجملة كلها.** مربع الاختيار وفتح النص فعلان
/// مختلفان، وجعلُ السطر كله يفتح النص يمنع المستخدم من التأشير أصلاً.
class TermsCheckbox extends StatelessWidget {
  const TermsCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.driver,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool driver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Checkbox(
          value: value,
          onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
        ),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('أوافق على ', style: theme.textTheme.bodyMedium),
              InkWell(
                onTap: () => LegalScreen.open(context, driver: driver),
                child: Text(
                  driver ? 'اتفاقية السائق' : 'شروط الاستخدام',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
