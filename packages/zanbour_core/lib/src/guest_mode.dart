import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// الدخول كضيف — يتصفّح التطبيق ولا يفعل فيه شيئاً.
///
/// **لماذا؟** آبل ترفض التطبيق الذي يُجبر زائره على التسجيل قبل أن يرى
/// ما يقدّمه (القاعدة 5.1.1). ومن يريد أن يعرف كم تكلّفه رحلةٌ إلى
/// السوق لا يُنشئ حساباً ليعرف — يحذف التطبيق.
///
/// **ولماذا علامةٌ محلية لا دخولٌ مجهول من Supabase؟** الدخول المجهول
/// يُنشئ مستخدماً حقيقياً في القاعدة لكل من ضغط «ضيف»، ويحمل دور
/// `authenticated` — وصلاحياتنا (RLS) مبنيّة على أن ذلك الدور يعني حساباً
/// حقيقياً له ملف. فالضيف هنا **بلا جلسة إطلاقاً**: يرى ما يراه `anon`،
/// وكل ما سواه يُغلق في القاعدة قبل التطبيق.
///
/// **وفي الذاكرة لا على القرص.** من أغلق التطبيق وعاد يبدأ من شاشة
/// الدخول — وهي دعوةٌ ثانية للتسجيل لا عقوبة.
class GuestMode extends Notifier<bool> {
  @override
  bool build() => false;

  void enter() => state = true;
  void exit() => state = false;
}

final guestModeProvider = NotifierProvider<GuestMode, bool>(GuestMode.new);

/// هل المستخدم ضيفٌ الآن؟ **الجلسة تغلب العلامة** — من سجّل دخوله لم
/// يعد ضيفاً ولو بقيت العلامة مرفوعة.
bool isGuestNow(WidgetRef ref) =>
    ref.read(guestModeProvider) &&
    Supabase.instance.client.auth.currentSession == null;

/// يسمح بالفعل إن كان للمستخدم حساب، وإلا يعرض دعوة التسجيل.
///
/// يعيد `true` إن كان مسجّلاً — فيُكمل المستدعي فعله. و`false` للضيف،
/// وحينها تكون الورقة قد عُرضت ولا شيء على المستدعي أن يفعله.
///
/// `go` يُمرَّر من التطبيق لأن الحزمة المشتركة لا تعرف الموجّه.
Future<bool> requireAccount(
  BuildContext context,
  WidgetRef ref, {
  required void Function(String path) go,
  String? reason,
}) async {
  if (Supabase.instance.client.auth.currentSession != null) return true;

  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => _SignInSheet(reason: reason),
  );
  if (choice == null) return false;

  // **العلامة تُنزل قبل الانتقال.** لو بقيت لأعاد الموجّه الضيفَ إلى
  // الرئيسية قبل أن تُرسم شاشة الدخول.
  ref.read(guestModeProvider.notifier).exit();
  go(choice);
  return false;
}

class _SignInSheet extends StatelessWidget {
  const _SignInSheet({this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.lock_outline,
                size: 44, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              'سجّل الدخول للمتابعة',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              reason ?? 'أنت تتصفّح كضيف. أنشئ حساباً مجانياً لتكمل.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(context, '/signup'),
              child: const Text('إنشاء حساب'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, '/login'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50)),
              child: const Text('لديّ حساب — تسجيل الدخول'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('متابعة التصفّح'),
            ),
          ],
        ),
      ),
    );
  }
}

/// زرّ «الدخول كضيف» أسفل شاشة الدخول.
class GuestEntryButton extends ConsumerWidget {
  const GuestEntryButton({super.key, required this.onEntered});

  /// يُستدعى بعد رفع العلامة — والتطبيق ينقل إلى رئيسيته.
  final VoidCallback onEntered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      onPressed: () {
        ref.read(guestModeProvider.notifier).enter();
        onEntered();
      },
      icon: const Icon(Icons.explore_outlined),
      label: const Text('تصفّح كضيف'),
    );
  }
}

/// شريطٌ أعلى الرئيسية يذكّر الضيف بحاله — ويُضغط فيفتح الدعوة.
class GuestBanner extends StatelessWidget {
  const GuestBanner({super.key, required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onSignIn,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Icon(Icons.person_outline,
                  color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'أنت تتصفّح كضيف',
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                'سجّل الدخول',
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
