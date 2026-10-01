import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

/// استعادة كلمة المرور — الشاشة في `zanbour_core`، وهنا وصلُها بالمسارات.
///
/// **لأن الخطوات نفسها في التطبيقين.** نسختان منها تعنيان أن إصلاح
/// عطلٍ في إحداهما يترك الأخرى معطوبة — وقد وقع ذلك الليلة في بوابة
/// الرمز حين أصلحتُ السائق وتركتُ الراكب.
class ForgotPasswordScreen extends ConsumerWidget {
  const ForgotPasswordScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ForgotPasswordFlow(
      onEmailChosen: (email) =>
          context.push('/reset-password', extra: email),
      onDone: () => context.go('/login'),
    );
  }
}
