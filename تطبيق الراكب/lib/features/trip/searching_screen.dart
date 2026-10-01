import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'package:latlong2/latlong.dart';

import 'change_destination_screen.dart';
import 'tracking_map.dart';
import 'trip_repository.dart';

/// شاشة متابعة الرحلة — من لحظة الطلب حتى الوصول.
///
/// تعتمد كلياً على البثّ اللحظي: لا تسأل الخادم دورياً، بل تتلقى التغيير
/// فور حدوثه عبر WebSocket. حين يقبل السائق تتبدّل الشاشة خلال جزء من
/// الثانية بلا أي كود تنقّل يدوي.
class SearchingScreen extends ConsumerWidget {
  const SearchingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripAsync = ref.watch(activeTripProvider);

    return Scaffold(
      body: SafeArea(
        child: tripAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _CenteredMessage(
            icon: Icons.error_outline,
            title: 'تعذّر متابعة الرحلة',
            body: AppError.message(e),
            action: ('العودة', () => context.go('/home')),
          ),
          data: (trip) {
            // انتهت الرحلة أو أُلغيت — يخرجنا المزوّد بقيمة null
            if (trip == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) context.go('/home');
              });
              return const Center(child: CircularProgressIndicator());
            }

            return switch (trip.status) {
              TripStatus.searching => _Searching(trip: trip),
              TripStatus.noDrivers => _NoDrivers(trip: trip),
              _ => _DriverFound(trip: trip),
            };
          },
        ),
      ),
    );
  }
}

// =============================================================================
// جارٍ البحث
// =============================================================================
class _Searching extends ConsumerStatefulWidget {
  const _Searching({required this.trip});
  final Trip trip;

  @override
  ConsumerState<_Searching> createState() => _SearchingState();
}

class _SearchingState extends ConsumerState<_Searching> {
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() => _seconds++) : null,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offers = ref.watch(offerProgressProvider(widget.trip.id));
    // .value لا .valueOrNull — Riverpod 3 وحّد الاسم وترجع T? مباشرة
    final tried = offers.value ?? 0;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const SizedBox(
                  width: 120,
                  height: 120,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                Icon(Icons.two_wheeler,
                    size: 52, color: theme.colorScheme.primary),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Text('جارٍ البحث عن سائق',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),

          // نُظهر تقدّم البحث بدل دوّارة صامتة.
          // الانتظار المجهول يبدو أطول بكثير من الانتظار المُفسَّر.
          Text(
            tried == 0
                ? 'نبحث عن أقرب سائق إليك'
                : 'تواصلنا مع $tried ${tried == 1 ? "سائق" : "سائقين"} حتى الآن',
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(_fmt(_seconds), style: theme.textTheme.bodyMedium),

          const SizedBox(height: 36),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _AddressRow(
                    icon: Icons.trip_origin,
                    color: theme.colorScheme.primary,
                    text: widget.trip.pickupAddress,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1),
                  ),
                  _AddressRow(
                    icon: Icons.location_on,
                    color: theme.colorScheme.error,
                    text: widget.trip.dropoffAddress,
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('الأجرة المتوقعة',
                          style: theme.textTheme.bodyMedium),
                      Text('${widget.trip.fareEstimated.round()} دينار',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),

          // **زر الرفع فوق زر الإلغاء.** الراكب الذي طال انتظاره يمدّ
          // يده إلى الإلغاء؛ ووضعُ البديل في طريقه يمنحه خياراً ثالثاً
          // قبل أن يخسر الطرفان الرحلة.
          _BoostButton(trip: widget.trip),
          const SizedBox(height: 8),

          OutlinedButton.icon(
            onPressed: () => _confirmCancel(context, ref, widget.trip),
            icon: const Icon(Icons.close),
            label: const Text('إلغاء الطلب'),
          ),
        ],
      ),
    );
  }

  String _fmt(int s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final r = (s % 60).toString().padLeft(2, '0');
    return '$m:$r';
  }
}

// =============================================================================
// لا يوجد سائقون
// =============================================================================
class _NoDrivers extends ConsumerWidget {
  const _NoDrivers({required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CenteredMessage(
      icon: Icons.search_off,
      title: 'لم نجد سائقاً متاحاً',
      body: 'لا يوجد سائقون قريبون منك الآن. جرّب بعد قليل.',
      action: (
        'حسناً',
        () async {
          // ننهي الرحلة المعلّقة قبل العودة: الفهرس الفريد يمنع الراكب
          // من رحلتين نشطتين، فلو تركناها لفشل طلبه التالي برسالة
          // "لديك رحلة نشطة" وهو لا يرى أي رحلة.
          try {
            await ref
                .read(tripRepositoryProvider)
                .cancel(trip.id, reason: 'no_drivers_found');
          } catch (_) {
            // الفشل هنا لا يمنع العودة — الرحلة ستنتهي بمهلة الخادم
          }
          if (context.mounted) context.go('/home');
        }
      ),
    );
  }
}

// =============================================================================
// وُجد سائق — متابعة الرحلة
// =============================================================================
class _DriverFound extends ConsumerWidget {
  const _DriverFound({required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final driver = ref.watch(tripDriverProvider(trip.id));

    // الخريطة تحتاج إحداثيات — تأتي من الأعمدة المحسوبة في 0014
    final pickup = (trip.pickupLat != null && trip.pickupLng != null)
        ? LatLng(trip.pickupLat!, trip.pickupLng!)
        : null;
    final dropoff = (trip.dropoffLat != null && trip.dropoffLng != null)
        ? LatLng(trip.dropoffLat!, trip.dropoffLng!)
        : null;

    // أثناء الرحلة نُظهر الوجهة؛ قبلها نُظهر نقطة الالتقاء.
    final showDropoff = trip.status == TripStatus.inProgress;

    return Column(
      children: [
        // ---- الخريطة: نصف الشاشة العلوي ----
        //
        // **العيب الذي أصلحناه:** كان الراكب يرى نصاً "السائق في طريقه
        // إليك" ولا يعرف أين هو ولا متى يصل، فيتصل به كل دقيقتين.
        // رؤية الدراجة تتحرك تغني عن الاتصال كله.
        if (trip.driverId != null && pickup != null)
          Expanded(
            flex: 3,
            child: TrackingMap(
              driverId: trip.driverId!,
              pickup: pickup,
              dropoff: dropoff,
              showDropoff: showDropoff,
            ),
          ),

        Expanded(
          flex: 2,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(trip.status.label,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              // الرمز أثناء الرحلة لا بعدها فقط: الراكب الذي يتصل بالدعم
              // وهو على الطريق يحتاجه الآن، لا حين تُغلق الرحلة.
              TripCodeBadge(number: trip.number, compact: true),
            ],
          ),
          const SizedBox(height: 16),

          driver.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
            data: (d) {
              if (d == null) return const SizedBox.shrink();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          PartyAvatar(
                            storagePath: d['avatar_url'] as String?,
                            radius: 30,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${d['full_name'] ?? ''}',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.star,
                                        size: 16, color: Colors.amber),
                                    const SizedBox(width: 4),
                                    Text('${d['rating_avg'] ?? '5.0'}'),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                // الدراجة كما يراها الراكب في الشارع:
                                // اللون والنوع أولاً لأنهما يُرَيان من
                                // بعيد، واللوحة للتأكّد عن قرب.
                                Text(
                                  _vehicleLine(d),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (d['phone'] != null) ...[
                        const Divider(height: 28),
                        // الهاتف يُكشف أثناء الرحلة النشطة وحدها — العرض
                        // trip_party_info يعيده null بعد انتهائها.
                        Row(
                          children: [
                            const Icon(Icons.phone, size: 18),
                            const SizedBox(width: 8),
                            Text('${d['phone']}',
                                textDirection: TextDirection.ltr,
                                style: theme.textTheme.titleMedium),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // أزرار لا نصاً: الراكب الواقف على الرصيف لا
                        // يحفظ رقماً ولا ينسخه — يضغط ويتواصل.
                        ContactButtons(
                          phone: '${d['phone']}',
                          message: 'مرحباً، أنا راكب رحلة زنبور.',
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 12),

          // **تفصيلٌ لا رقمٌ واحد.** انظر `FareBreakdown`: راكبُ التسوّق
          // يرى «٤٠٠٠ دينار» فلا يدري أثمنُ السلعة غالٍ أم أجرتنا.
          FareBreakdown(
            fare: trip.fare,
            total: trip.totalDue,
            discount: trip.discount,
            creditUsed: trip.creditUsed,
            goods: trip.isShopping ? trip.goods : null,
            goodsIsFinal: trip.goodsPriced,
            shopping: trip.isShopping,
            emphasise: false,
          ),

          // **إشعارٌ في الشاشة نفسها لا في شريط الإشعارات وحده.** من كان
          // ينظر إلى الشاشة لحظةَ إدخال السائق السعرَ الحقيقي لا يصله
          // إشعار النظام أصلاً — يراه رقماً تبدّل أمامه بلا تفسير.
          if (trip.isShopping && trip.goodsPriced) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.shade600),
              ),
              child: Row(
                children: [
                  Icon(Icons.verified_outlined,
                      color: Colors.green.shade700, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'تمّ إبلاغك بالأسعار الحقيقية في السوق من قبل السائق.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),

          // **تغيير الوجهة متاح أثناء الرحلة وحدها.** قبل ركوب الراكب لا
          // معنى له — يلغي ويطلب من جديد بلا عواقب. وبعد الوصول انتهى كل
          // شيء.
          if (trip.status == TripStatus.inProgress)
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChangeDestinationScreen(trip: trip),
                ),
              ),
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: const Text('تغيير الوجهة'),
            ),

          if (trip.status != TripStatus.inProgress)
            OutlinedButton(
              onPressed: () => _confirmCancel(context, ref, trip),
              child: const Text('إلغاء الرحلة'),
            ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// أدوات مشتركة
// =============================================================================
Future<void> _confirmCancel(
    BuildContext context, WidgetRef ref, Trip trip) async {
  final repo = ref.read(tripRepositoryProvider);
  final reasons = await repo.cancellationReasons();
  if (!context.mounted) return;

  final chosen = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('سبب الإلغاء',
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          // نطلب السبب لا لتعقيد الأمر، بل لأن أسباب الإلغاء تكشف مشاكل
          // حقيقية: "وقت الانتظار طويل" المتكرر يعني نقص سائقين في الحي.
          ...reasons.map((r) => ListTile(
                title: Text('${r['label_ar']}'),
                onTap: () => Navigator.pop(ctx, r['code'] as String),
              )),
          const Divider(height: 1),
          ListTile(
            title: const Text('تراجع'),
            leading: const Icon(Icons.arrow_back),
            onTap: () => Navigator.pop(ctx),
          ),
        ],
      ),
    ),
  );

  if (chosen == null || !context.mounted) return;

  try {
    await repo.cancel(trip.id, reason: chosen);
    if (context.mounted) context.go('/home');
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppError.message(e))));
    }
  }
}

class _AddressRow extends StatelessWidget {
  const _AddressRow(
      {required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text.isEmpty ? 'موقع محدد على الخريطة' : text,
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback) action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 72, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 20),
            Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 28),
            FilledButton(onPressed: action.$2, child: Text(action.$1)),
          ],
        ),
      ),
    );
  }
}


/// سطر الدراجة: "أحمر · هوندا CG 150 · لوحة 12345".
///
/// نتجاوز الحقول الفارغة بدل طباعة فواصل فارغة — بيانات الدراجة
/// اختيارية في المخطط، وسائق قديم قد لا يملك منها شيئاً.
String _vehicleLine(Map<String, dynamic> d) {
  final make = [d['vehicle_make'], d['vehicle_model']]
      .where((v) => v != null && '$v'.trim().isNotEmpty)
      .join(' ');

  final parts = <String>[
    if ('${d['vehicle_color'] ?? ''}'.trim().isNotEmpty) '${d['vehicle_color']}',
    if (make.isNotEmpty) make
    else if ('${d['vehicle_type'] ?? ''}'.trim().isNotEmpty)
      '${d['vehicle_type']}',
    if ('${d['vehicle_plate'] ?? ''}'.trim().isNotEmpty)
      'لوحة ${d['vehicle_plate']}',
  ];

  return parts.isEmpty ? 'دراجة نارية' : parts.join(' · ');
}

// =============================================================================
// رفع السعر لتسريع البحث
// =============================================================================
/// **مرة واحدة لكل رحلة.** الراكب المتوتّر يضغط ثلاثاً فيصير السعر ضعفاً،
/// ثم يندم عند الوصول ويرفض الدفع — والدفع نقدي فلا ضمان لنا.
class _BoostButton extends ConsumerStatefulWidget {
  const _BoostButton({required this.trip});
  final Trip trip;

  @override
  ConsumerState<_BoostButton> createState() => _BoostButtonState();
}

class _BoostButtonState extends ConsumerState<_BoostButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final used = widget.trip.fareBoostPct > 0;

    if (used) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.trending_up, color: theme.colorScheme.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'رفعت الأجرة ${widget.trip.fareBoostPct}٪ — '
                'طلبك الآن في مقدمة ما يراه السائقون',
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
          ],
        ),
      );
    }

    return FilledButton.tonalIcon(
      onPressed: _busy ? null : _boost,
      icon: _busy
          ? const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2))
          : const Icon(Icons.trending_up),
      label: const Text('ارفع الأجرة ٢٠٪ لتسريع البحث'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
    );
  }

  Future<void> _boost() async {
    // نؤكّد قبل الرفع: زرٌّ يزيد ما يدفعه المستخدم لا يُضغط بلا سؤال،
    // ولو ضُغط سهواً لما أمكن التراجع — الرفع مرة واحدة بلا رجعة.
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('رفع الأجرة'),
        content: Text(
          'ستصير الأجرة نحو '
          '${(widget.trip.fareEstimated * 1.2 / 250).round() * 250} دينار '
          'بدل ${widget.trip.fareEstimated.round()}.\n\n'
          'يُرسل طلبك من جديد إلى كل السائقين القريبين بالسعر الجديد. '
          'هذا الخيار متاح مرة واحدة ولا يمكن التراجع عنه.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ارفعها')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await ref.read(tripRepositoryProvider).boostFare(widget.trip.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppError.message(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
