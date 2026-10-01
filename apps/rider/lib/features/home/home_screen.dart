import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../../core/push_service.dart';
import '../auth/auth_repository.dart';
import '../delivery/delivery_repository.dart';
import '../trip/trip_repository.dart' show recentDestinationsProvider;
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

              // **زجاجٌ فوق خلفيةٍ دافئة.** البطاقة البيضاء الصمّاء على
              // خلفيةٍ فاتحة تختفي حدودها فتبدو الشاشة سطحاً واحداً بلا
              // ترتيب؛ والزجاج يفصلها بلا أن يقطع.
              ZGlassCard(
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
                      if (AuthFlags.emailEnabled) ...[
                        _Row(label: 'البريد', value: '${p['email']}', ltr: true),
                        const SizedBox(height: 10),
                      ],
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
                                ? context.z.ok
                                : context.z.warn,
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
              const SizedBox(height: 20),
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
/// «إلى أين؟» — شريط بحثٍ زجاجيّ، وتحته آخر وجهات الراكب.
///
/// **أغلب الناس يذهبون إلى الأماكن نفسها:** البيت والعمل والسوق. ضغطةٌ
/// على وجهةٍ سابقة تفتح الخريطة وهي واقفةٌ عليها، فيصير الطلب خطوتين بدل
/// بحثٍ وتحريك دبّوس. والوجهات من رحلاته هو، لا تُحفظ في مكانٍ جديد.
class _WhereTo extends ConsumerWidget {
  const _WhereTo({required this.guest});

  final bool guest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final z = context.z;
    final recent = guest
        ? const <({double lat, double lng, String address})>[]
        : (ref.watch(recentDestinationsProvider).value ?? const []);

    return ZGlass(
      radius: ZanbourTheme.rLg,
      opacity: 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(ZanbourTheme.rLg),
              onTap: () => context.push('/map'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Row(
                  children: [
                    const ZIconTile(Icons.search),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('إلى أين؟',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    Icon(Icons.chevron_left, color: z.inkDim),
                  ],
                ),
              ),
            ),
          ),
          for (final d in recent) ...[
            Divider(height: 1, indent: 14, endIndent: 14, color: z.line),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => context.push('/map', extra: d),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  child: Row(
                    children: [
                      Icon(Icons.history, size: 20, color: z.inkDim),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          d.address.isEmpty ? 'وجهةٌ سابقة' : d.address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ServiceCards extends ConsumerWidget {
  const _ServiceCards({required this.guest});

  final bool guest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(serviceStatusProvider).value ??
        const ServiceAvailability.open();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
              _WhereTo(guest: guest),
              const SizedBox(height: 14),

              // البطاقة قابلة للضغط لتفتح الخريطة.
              //
              // ستصير الخريطة هي الشاشة الرئيسية لاحقاً — هذا ما يتوقعه
              // مستخدم تطبيق تكسي. أبقيناها خطوة وسطى الآن لأن بطاقة
              // الحساب أعلاها مفيدة أثناء الاختبار.
              // **الفعل الأول يملأ العرض، والباقيان يتقاسمان سطراً.**
              // ثلاث بطاقاتٍ متشابهة فوق بعضها تسأل الراكب «أيّها تريد؟»
              // بدل أن تعرض عليه طريقاً — وأكثر من يفتح التطبيق يفتحه
              // ليطلب رحلة. والصفّ تحته يجعل الشاشة تُقرأ في نظرة.
              _PrimaryAction(
                onTap: () => context.push('/map'),
                icon: Icons.map_outlined,
                title: 'اطلب رحلة',
                subtitle: 'حدّد وجهتك واعرف الأجرة قبل الطلب',
              ),

              const SizedBox(height: 12),
              IntrinsicHeight(
                child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // **المغلقة تُخفى ومكانها رسالة الإدارة.** بطاقةٌ رمادية
                  // تُضغط فلا تفتح شيئاً تُقرأ عطلاً لا إغلاقاً.
                  if (!services.shopping)
                    _MiniAction(
                      onTap: null,
                      icon: Icons.shopping_basket_outlined,
                      title: 'اطلب تسوّق',
                      subtitle: services.shoppingMessage.isEmpty
                          ? 'خدمة التسوّق قريباً.'
                          : services.shoppingMessage,
                    )
                  else
                    _MiniAction(
                      onTap: () => context.push('/shopping'),
                      icon: Icons.shopping_basket_outlined,
                      title: 'اطلب تسوّق',
                      subtitle: 'يشتري لك السائق ويوصّل إلى بابك',
                    ),

                  const SizedBox(width: 12),

                  // **الضيف لا يرى مدخل المتاجر الحيّ.** يقرأ متجره
                  // وطلباته — بياناتٌ لا يملكها `anon` — فيُعرض له مدخلٌ
                  // يدعوه للتسجيل.
                  if (guest)
                    _MiniAction(
                      onTap: () => requireAccountHere(context, ref,
                          reason: 'سجّل متجرك لتطلب مندوباً يوصّل لزبائنك.'),
                      icon: Icons.storefront_outlined,
                      title: 'اطلب مندوب',
                      subtitle: 'لأصحاب المتاجر',
                    )
                  else
                    const _DeliveryEntry(),
                ],
                ),
              ),

              // **التنبيه الحيّ خبرٌ لا زرّ.** تاجرٌ ينتظر مندوبٌ تأكيده
              // يجب أن يقرأه لا أن يستنتجه من رقمٍ صغير. فالشارة تلفت،
              // والسطر يشرح.
              if (!guest) const _DeliveryNotices(),
      ],
    );
  }
}

/// تنبيهات المندوب الحيّة — تحت صفّ الخدمات.
class _DeliveryNotices extends ConsumerWidget {
  const _DeliveryNotices();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final confirms = ref.watch(pendingSettleConfirmsProvider);
    if (confirms.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        color: context.z.warn.withValues(alpha: 0.12),
        child: ListTile(
          leading:
              Icon(Icons.payments_outlined, color: context.z.warn),
          title: Text(confirms.length == 1
              ? 'مندوبٌ ينتظر تأكيدك'
              : '${confirms.length} مناديب ينتظرون تأكيدك'),
          subtitle: const Text('هل وصلك ثمن الطلب؟'),
          trailing: const Icon(Icons.chevron_left),
          onTap: () => context.push('/deliveries'),
        ),
      ),
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

    // **مربّعٌ نصفيّ كأخيه، وعدد ما في الطريق شارةٌ فوق الأيقونة.**
    // والتنبيهُ الحيّ — مندوبٌ ينتظر تأكيداً — خبرٌ لا زرّ، فيبقى سطراً
    // كاملاً تحت الصفّ حيث يُقرأ.
    return _MiniAction(
      onTap: () => context.push(store == null ? '/store' : '/deliveries'),
      icon: Icons.local_shipping_outlined,
      title: 'اطلب مندوب',
      subtitle: !services.delivery
          ? (services.deliveryMessage.isEmpty
              ? 'الخدمة متوقّفة مؤقّتاً'
              : services.deliveryMessage)
          : store == null
              ? 'لأصحاب المتاجر — سجّل متجرك أولاً'
              : live > 0
                  ? '$live في الطريق الآن'
                  : 'مندوبٌ يوصّل طلبات متجرك لزبائنك',
      badge: confirms.isNotEmpty ? '${confirms.length}' : null,
      badgeTooltip: confirms.isEmpty
          ? null
          : (confirms.length == 1
              ? 'مندوبٌ ينتظر تأكيدك'
              : '${confirms.length} مناديب ينتظرون تأكيدك'),
      badgeHint: 'هل وصلك ثمن الطلب؟',
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

// -----------------------------------------------------------------------------
/// الفعل الأول — لوحةٌ كهرمانية تملأ العرض.
///
/// **لأن الخدمات ليست متساوية.** ثلاث بطاقاتٍ بيضاء متشابهة فوق بعضها
/// تجعل الشاشة تسأل الراكب «أيّها تريد؟» بدل أن تعرض عليه طريقاً؛ وأكثر
/// من يفتح التطبيق يفتحه ليطلب رحلة.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.onTap,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final VoidCallback onTap;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = theme.colorScheme.onPrimary;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: ZanbourTheme.amber.withValues(alpha: 0.34),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: ZanbourTheme.amber,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              // وهجٌ خفيف في الزاوية — يمنع اللون المسطّح أن يبدو ورقة.
              Positioned(
                top: -40,
                right: -20,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on.withValues(alpha: 0.10),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(22),
                child: Row(
                  children: [
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: on.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(icon, size: 30, color: on),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                  color: on, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(subtitle,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: on.withValues(alpha: 0.9))),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_left, color: on.withValues(alpha: 0.9)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// خدمةٌ ثانوية — مربّعٌ نصفيّ زجاجيّ.
///
/// **نصفُ العرض لا كلّه.** الخدمتان الثانيتان تُكتشفان ولا تُقصدان في
/// أكثر الفتحات، فتأخذان سطراً واحداً بينهما بدل سطرين كاملين يزاحمان
/// الفعل الأول.
class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.onTap,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.badge,
    this.badgeTooltip,
    this.badgeHint,
  });

  final VoidCallback? onTap;
  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  final String? badgeTooltip;
  final String? badgeHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final closed = onTap == null;

    return Expanded(
      child: Tooltip(
        message: badgeTooltip == null
            ? subtitle
            : '$badgeTooltip — ${badgeHint ?? ''}',
        child: ZGlass(
          radius: 22,
          opacity: 0.62,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(22),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: (closed ? scheme.outline : scheme.primary)
                                .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(icon,
                              size: 24,
                              color: closed ? scheme.outline : scheme.primary),
                        ),
                        if (badge != null)
                          Positioned(
                            top: -5,
                            left: -5,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: context.z.warn,
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(
                                    color: scheme.surface, width: 1.5),
                              ),
                              child: Text(badge!,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: closed ? scheme.outline : scheme.onSurface,
                        )),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        height: 1.35,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
