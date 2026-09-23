import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../../core/push_service.dart';
import '../auth/auth_repository.dart';
import '../delivery/delivery_repository.dart';
import '../../core/guest_gate.dart';

/// الشاشة الرئيسية بعد الدخول.
///
/// مؤقتة: تعرض بيانات الحساب لتأكيد أن التسجيل والدخول والتحقق تعمل.
/// ستُستبدل بالخريطة وطلب الرحلة في المرحلة التالية.
final riderPushServiceProvider = Provider<PushService>(
  (ref) => PushService(ref.watch(supabaseProvider)),
);

/// حالة إشعارات الراكب.
///
/// **الراكب يحتاج التنبيه كما يحتاجه السائق.** من لا تصله إشعارات لا
/// يعرف أن سائقه قَبِل ولا أنه وصل — فيقف في الشارع ينظر إلى شاشةٍ
/// صامتة. **ولا يحتاج عملاً في الخلفية:** إشعاراته تصل عبر فايربيز
/// حتى والتطبيق مغلق، بخلاف السائق الذي يجب أن يبقى حيّاً ليستقبل
/// عرضاً يعيش خمساً وأربعين ثانية.
final riderPushProvider = FutureProvider<RiderPushStatus>(
  (ref) => ref.watch(riderPushServiceProvider).diagnose(),
);

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final push = ref.watch(riderPushProvider).value;
    final profile = ref.watch(myProfileProvider);
    // **الجلسة تغلب العلامة.** انظر `isGuestNow`.
    final guest =
        ref.watch(guestModeProvider) && ref.watch(sessionProvider) == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('زنبور'),
        // **الضيف لا يرى أيقونات الحساب.** كل واحدةٍ منها تفتح دعوة
        // التسجيل نفسها، فخمسُ أيقوناتٍ لفعلٍ واحد تشويش — يكفيه زرّ.
        actions: guest
            ? [
                TextButton(
                  onPressed: () {
                    ref.read(guestModeProvider.notifier).exit();
                    context.go('/login');
                  },
                  child: const Text('تسجيل الدخول'),
                ),
              ]
            : [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'حسابي',
            onPressed: () => context.push('/account'),
          ),
          IconButton(
            icon: const Icon(Icons.route),
            tooltip: 'رحلاتي',
            onPressed: () => context.push('/my-trips'),
          ),
          // **جرسٌ يقرأ من القاعدة لا من فايربيز.** الدفع يسقط عن جزءٍ
          // من جمهورنا — أجهزةٌ بلا خدمات Google — فالقائمة هي ما يصل
          // الجميع فعلاً.
          const NotificationsBell(),
          // **الورقة نفسها التي يفتحها التنبيه الأحمر.** كانت تفتح
          // شاشةً تقنية تعرض «الرمز المخزّن في الخادم» و«تطابق الرمزين»
          // — كلامٌ لا يعني راكباً شيئاً، فيغلقها ويبقى بلا إشعارات.
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'إعدادات الإشعارات',
            onPressed: () {
              final s = ref.read(riderPushProvider).value;
              if (s != null) _openPushSetup(context, ref, s);
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'تسجيل الخروج',
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('تسجيل الخروج'),
                  content: const Text('هل تريد الخروج من حسابك؟'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('إلغاء'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('خروج'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(authRepositoryProvider).signOut();
              }
            },
          ),
        ],
      ),
      body: guest
          ? ListView(
              padding: const EdgeInsets.all(24),
              children: [
                GuestBanner(onSignIn: () => requireAccountHere(context, ref)),
                const SizedBox(height: 24),
                const _ServiceCards(guest: true),
              ],
            )
          : profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('تعذّر تحميل بياناتك\n$e',
                textAlign: TextAlign.center),
          ),
        ),
        data: (p) {
          if (p == null) {
            return const Center(child: Text('لا توجد بيانات'));
          }
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // **التنبيه أول ما يُرى.** من لا تصله إشعارات لا يعرف
              // أن سائقه قَبِل ولا أنه وصل، فيقف في الشارع ينظر إلى
              // شاشةٍ صامتة.
              if (push != null && !push.healthy) ...[
                PushAlertCard(
                  notificationsOk: push.permissionGranted == true,
                  message: 'الإشعارات معطّلة — لن تعرف متى يصل سائقك.',
                  onFix: () => _openPushSetup(context, ref, push),
                ),
                const SizedBox(height: 16),
              ],

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 26,
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Icon(Icons.person,
                                color: theme.colorScheme.onPrimaryContainer),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${p['full_name']}',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.bold)),
                                const SizedBox(height: 2),
                                Text('${p['phone']}',
                                    textDirection: TextDirection.ltr,
                                    style: theme.textTheme.bodySmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 28),
                      _Row(label: 'البريد', value: '${p['email']}', ltr: true),
                      const SizedBox(height: 10),
                      _Row(label: 'العنوان', value: '${p['address']}'),
                      const SizedBox(height: 10),
                      // الراكب يُعتمد تلقائياً فور رفع صورته — لا مراجعة
                      // يدوية عليه إطلاقاً. النص السابق كان يقول "قيد
                      // المراجعة" فيوحي بانتظار لا وجود له.
                      Row(
                        children: [
                          SizedBox(
                            width: 120,
                            child: Text('الحساب',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    color:
                                        theme.colorScheme.onSurfaceVariant)),
                          ),
                          Icon(
                            p['identity_verified'] == true
                                ? Icons.verified_rounded
                                : Icons.info_outline,
                            size: 18,
                            color: p['identity_verified'] == true
                                ? Colors.green
                                : Colors.orange,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            p['identity_verified'] == true
                                ? 'حساب نشط'
                                : 'الحساب قيد التفعيل',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const _ServiceCards(guest: false),
            ],
          );
        },
      ),
    );
  }
}

/// بطاقات الخدمات — للمسجّل والضيف معاً.
///
/// **فُصلت لأن الضيف يحتاجها بلا بطاقة الحساب فوقها.** والمسجّل يراها
/// كما كان يراها تماماً.
class _ServiceCards extends ConsumerWidget {
  const _ServiceCards({required this.guest});

  final bool guest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final services = ref.watch(serviceStatusProvider).value ??
        const ServiceAvailability.open();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
              // البطاقة قابلة للضغط لتفتح الخريطة.
              //
              // ستصير الخريطة هي الشاشة الرئيسية لاحقاً — هذا ما يتوقعه
              // مستخدم تطبيق تكسي. أبقيناها خطوة وسطى الآن لأن بطاقة
              // الحساب أعلاها مفيدة أثناء الاختبار.
              Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => context.push('/map'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(Icons.map_outlined,
                            size: 56, color: theme.colorScheme.primary),
                        const SizedBox(height: 12),
                        Text('اطلب رحلة',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Text(
                          'حدّد وجهتك واعرف الأجرة قبل الطلب',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // **تحت «اطلب رحلة» لا بجانبها.** الرحلة هي الخدمة
              // الأولى، والتسوّق ثانيةٌ تُكتشف — وتساويهما في الحجم
              // يجعل الشاشة تسأل سؤالاً بدل أن تعرض طريقاً.
              const SizedBox(height: 14),
              // **المغلقة تُخفى ومكانها رسالة الإدارة.** بطاقةٌ رمادية
              // تُضغط فلا تفتح شيئاً تُقرأ عطلاً لا إغلاقاً.
              if (!services.shopping)
                Card(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Icon(Icons.shopping_basket_outlined,
                            size: 28, color: theme.colorScheme.outline),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            services.shoppingMessage.isEmpty
                                ? 'خدمة التسوّق قريباً.'
                                : services.shoppingMessage,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
              Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => context.push('/shopping'),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Icon(Icons.shopping_basket_outlined,
                            size: 32, color: theme.colorScheme.primary),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('اطلب تسوّق',
                                  style: theme.textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text(
                                'يشتري لك السائق ويوصّل إلى بابك',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_left),
                      ],
                    ),
                  ),
                ),
              ),

              // ---- طلب المندوب — لأصحاب المتاجر ----
              const SizedBox(height: 12),
              // **الضيف لا يرى مدخل المتاجر الحيّ.** يقرأ متجره وطلباته
              // — بياناتٌ لا يملكها `anon` — فيُعرض له مدخلٌ يدعوه للتسجيل.
              if (guest)
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: Icon(Icons.storefront_outlined,
                        color: theme.colorScheme.primary),
                    title: const Text('اطلب مندوب'),
                    subtitle: const Text('لأصحاب المتاجر'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => requireAccountHere(context, ref,
                        reason: 'سجّل متجرك لتطلب مندوباً يوصّل لزبائنك.'),
                  ),
                )
              else
                const _DeliveryEntry(),
      ],
    );
  }
}

/// مدخل «اطلب مندوب» في الرئيسية.
///
/// **يعرف أين يأخذ صاحبه.** بلا متجر ← «متجري» ليسجّله أولاً؛ وبمتجر
/// ← «طلبات المندوب» (وفيها حالة الاعتماد إن لم يُعتمد بعد). والتاجر
/// الذي ينتظر مندوبٌ تأكيده يرى ذلك هنا قبل أن يبحث عنه.
class _DeliveryEntry extends ConsumerWidget {
  const _DeliveryEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final services = ref.watch(serviceStatusProvider).value ??
        const ServiceAvailability.open();
    final store = ref.watch(myStoreProvider).value;
    final confirms = ref.watch(pendingSettleConfirmsProvider);
    final live = (ref.watch(myDeliveriesProvider).value ?? const [])
        .where((r) => kLiveDeliveryStatuses.contains(r['status']))
        .length;

    // الخدمة مغلقة ولا متجر: لا نعرض شيئاً — هي خدمة للتجار وحدهم،
    // وإعلانٌ عن خدمةٍ مغلقة لمن لا يحتاجها ضجيج.
    if (!services.delivery && store == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (confirms.isNotEmpty)
          Card(
            color: ZanbourTheme.warning.withValues(alpha: 0.12),
            child: ListTile(
              leading: const Icon(Icons.payments_outlined,
                  color: ZanbourTheme.warning),
              title: Text(confirms.length == 1
                  ? 'مندوبٌ ينتظر تأكيدك'
                  : '${confirms.length} مناديب ينتظرون تأكيدك'),
              subtitle: const Text('هل وصلك ثمن الطلب؟'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => context.push('/deliveries'),
            ),
          ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () =>
                context.push(store == null ? '/store' : '/deliveries'),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(Icons.local_shipping_outlined,
                      size: 32, color: theme.colorScheme.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('اطلب مندوب',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text(
                          !services.delivery
                              ? (services.deliveryMessage.isEmpty
                                  ? 'الخدمة متوقّفة مؤقّتاً'
                                  : services.deliveryMessage)
                              : store == null
                                  ? 'لأصحاب المتاجر — سجّل متجرك أولاً'
                                  : live > 0
                                      ? '$live في الطريق الآن'
                                      : 'مندوبٌ يوصّل طلبات متجرك لزبائنك',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_left),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// سطرٌ واحد يُلخّص الحالة الفعلية — لنا لا للمستخدم.
String _diagnosticOf(RiderPushStatus s) {
  final parts = <String>[
    'permission=${s.permissionGranted}',
    'token=${s.hasToken}',
    'registered=${s.registered}',
  ];
  if (s.error != null) parts.add('error=${s.error}');
  return parts.join('\n');
}

/// ما يقال للمستخدم بعد «تطبيق» — بحسب ما وُجد فعلاً.
String _resultOf(RiderPushStatus s) {
  if (s.healthy) return 'تمّ — جهازك جاهز الآن';
  if (s.permissionGranted != true) {
    return 'الإشعارات ما زالت مطفأة — اضغط «فتح» وفعّلها من إعدادات الهاتف';
  }
  if (!s.hasToken) {
    return defaultTargetPlatform == TargetPlatform.iOS
        ? 'رمز الجهاز لم يُولَّد بعد — أعد المحاولة بعد لحظة أو أعد تثبيت TestFlight'
        : 'خدمات Google لا تستجيب — تحقّق من الإنترنت وأعد المحاولة';
  }
  return 'تعذّر تسجيل جهازك — أعد المحاولة بعد لحظة';
}

/// خطوتان لا ثلاث — الراكب لا يحتاج العمل في الخلفية.
Future<void> _openPushSetup(
  BuildContext context,
  WidgetRef ref,
  RiderPushStatus s,
) {
  return showPushSetupSheet(
    context,
    title: 'حتى تصلك الإشعارات',
    diagnostic: s.healthy ? null : _diagnosticOf(s),
    steps: [
      PushStep(
        title: 'فعّل الإشعارات',
        detail: 'حتى يرنّ هاتفك حين يَقبل سائقٌ طلبك',
        done: s.permissionGranted == true,
        action: 'فتح',
        onTap: () async {
          await requestNotificationPermission();
          ref.invalidate(riderPushProvider);
        },
      ),
      PushStep(
        title: 'اضغط هنا للتطبيق',
        detail: 'الخطوة الأخيرة — بعدها تصلك الإشعارات',
        done: s.healthy,
        action: 'تطبيق',
        onTap: () async {
          await ref.read(riderPushServiceProvider).resync();
          // **نفحص قبل أن نقول «تمّ».** كانت الرسالة تظهر أيّاً كانت
          // النتيجة، فيطمئن المستخدم وجهازه ما زال أصمّ.
          final now = await ref.refresh(riderPushProvider.future);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_resultOf(now))),
            );
          }
        },
      ),
    ],
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.ltr = false});

  final String label;
  final String value;
  final bool ltr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(
            value,
            textDirection: ltr ? TextDirection.ltr : null,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
