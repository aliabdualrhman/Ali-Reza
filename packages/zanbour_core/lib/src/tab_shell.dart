
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'guest_mode.dart';
import 'theme.dart';
import 'glass.dart';

/// تبويبٌ في شريط التنقّل السفلي.
class ZTab {
  const ZTab({
    required this.path,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.push = false,
    this.requiresAccount = false,
  });

  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// **تبويبٌ يفتح شاشةً كاملة لا يصير «محدَّداً».** «اطلب» عند الراكب
  /// يفتح خريطة الحجز فوق الشريط كما كان يُفتح من الرئيسية — الحجز
  /// يحتاج الشاشة كلّها، ولوحته السفلية لا تتّسع لشريطٍ تحتها.
  final bool push;

  /// **تبويبٌ لا يفتحه الضيف يسأله أن يسجّل — لا يصمت.** الموجّه يعيد
  /// الضيف إلى الرئيسية من أيّ شاشةٍ غير مسموحة، وهذا صوابٌ لرابطٍ ضُغط
  /// خطأً؛ أمّا على تبويبٍ فمعناه زرٌّ لا يفعل شيئاً. فيظهر له عرضُ
  /// الحساب نفسه الذي يظهر حين يحاول الطلب.
  final bool requiresAccount;
}

/// إطار الشاشات الرئيسية: الشاشة، وتحتها شريطٌ زجاجيّ — `.nav` في المحاكي.
///
/// **إطارٌ لا إعادة بناءٍ للتنقّل.** المسارات نفسها (`/home`، `/my-trips`…)
/// تبقى كما هي، فكلّ `go` و`push` في الشيفرة، وكلّ إشعارٍ يفتح شاشة،
/// وكلّ تحويلٍ في `redirect`، يعمل كما كان. والأزرار القديمة المؤدّية إلى
/// هذه الشاشات باقية — الشريط طريقٌ إضافيّ لا بديل.
///
/// **وما هو خارج الإطار يغطّيه.** الرحلة النشطة والعرض والتقييم وخريطة
/// الحجز مساراتٌ في الملّاح الجذر، فتُفتح فوق الشريط بلا أن يظهر تحتها.
class ZTabShell extends ConsumerWidget {
  const ZTabShell({
    super.key,
    required this.tabs,
    required this.location,
    required this.child,
    this.home = '/home',
  });

  final List<ZTab> tabs;
  final String location;
  final Widget child;
  final String home;

  int get _index {
    final i = tabs.indexWhere(
        (t) => location == t.path || location.startsWith('${t.path}/'));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final selected = _index;

    // **الرجوع من تبويبٍ يعود إلى الرئيسية لا يُغلق التطبيق.** التبويب
    // يُفتح بـ`go` فلا شيء تحته؛ وبلا هذا يضغط السائق «رجوع» من «رحلاتي»
    // فيخرج من التطبيق كلّه وهو يظنّ أنه عائدٌ خطوة.
    return PopScope(
      canPop: location == home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(home);
      },
      child: Scaffold(
        body: child,
        bottomNavigationBar: ClipRect(
          // الشدّة من `zGlassSigma` — كألواح الخريطة (انظر glass.dart).
          child: zGlassBlur(
            context,
            20,
            DecoratedBox(
              decoration: BoxDecoration(
                color: z.surface.withValues(alpha: 0.86),
                border: Border(top: BorderSide(color: z.line)),
              ),
              child: NavigationBar(
                selectedIndex: selected,
                animationDuration: const Duration(milliseconds: 340),
                labelBehavior:
                    NavigationDestinationLabelBehavior.alwaysShow,
                onDestinationSelected: (i) async {
                  HapticFeedback.selectionClick();
                  final t = tabs[i];
                  if (i == selected && !t.push) return;
                  if (t.requiresAccount) {
                    final router = GoRouter.of(context);
                    final ok = await requireAccount(context, ref,
                        go: router.go,
                        reason: 'أنشئ حساباً مجانياً لترى ${t.label}.');
                    if (!ok) return;
                    // الموجّه مُلتقَطٌ قبل الانتظار: الورقة أُغلقت، وقد
                    // لا يكون `context` صالحاً بعدها.
                    t.push ? router.push(t.path) : router.go(t.path);
                    return;
                  }
                  if (!context.mounted) return;
                  if (t.push) {
                    context.push(t.path);
                  } else if (i != selected) {
                    context.go(t.path);
                  }
                },
                destinations: [
                  for (final t in tabs)
                    NavigationDestination(
                      icon: Icon(t.icon),
                      selectedIcon: Icon(t.selectedIcon),
                      label: t.label,
                      tooltip: t.label,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
