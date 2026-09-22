import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

/// `requireAccount` موصولةً بموجّه هذا التطبيق.
///
/// **الموجّه يُلتقط قبل الانتظار.** الورقة تُغلق بعد ثوانٍ، وقد تكون
/// الشاشة التي فتحتها ذهبت — واستعمال `context` بعدها خطأٌ صامت.
Future<bool> requireAccountHere(
  BuildContext context,
  WidgetRef ref, {
  String? reason,
}) {
  final router = GoRouter.of(context);
  return requireAccount(context, ref, go: router.go, reason: reason);
}
