import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';
import 'offer_map.dart';

/// شاشة العروض الواردة — أهم شاشة في تطبيق السائق.
///
/// **قيدها الحاكم: الوقت.** للسائق مهلة قصيرة ليقرر (٤٥ ثانية افتراضياً،
/// تحدّدها المنطقة)، وهو غالباً على دراجة في الشارع. لذلك: أرقام كبيرة،
/// معلومتان فقط (الأجرة والمسافة)، وزرّان عريضان يُضغطان بإبهام واحد.
///
/// **ولماذا صارت عدة صفحات؟** بعد البثّ المتوازي قد تصل السائق عروض عدة
/// رحلات معاً. عرضُ الأحدث وحده يُخفي عنه رحلة أقرب أو أعلى أجراً،
/// ويجعل الطلب يقفز أمامه كلما وصل غيره فيضغط "قبول" على غير ما قصد.
/// التمرير يمنحه الاختيار، والمؤشّر تحت البطاقة يخبره كم طلباً ينتظره.
///
/// **لماذا تقرأ العروض من المزوّد لا من معامل؟** لأنها تُفتح من ثلاثة
/// طرق: بثّ لحظي والتطبيق مفتوح، وضغط إشعار والتطبيق في الخلفية، وإقلاع
/// بارد من إشعار والتطبيق مغلق. تمرير العرض كمعامل يعمل في الأولى فقط.
class OfferScreen extends ConsumerStatefulWidget {
  const OfferScreen({super.key});

  @override
  ConsumerState<OfferScreen> createState() => _OfferScreenState();
}

class _OfferScreenState extends ConsumerState<OfferScreen> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offersAsync = ref.watch(pendingOffersProvider);
    final offers = ref.watch(sortedOffersProvider);

    // لا عروض بين أيدينا. حالتان لا واحدة:
    //   - ما زالت تُجلب (استيقاظ من إشعار، إقلاع بارد) ← ننتظر
    //   - جُلبت ولا شيء فيها ← اختفت العروض، والموجّه يخرجنا
    if (offers.isEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text(
                offersAsync.isLoading
                    ? 'جارٍ تحميل الطلب…'
                    : 'انتهت مهلة هذا الطلب',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    // اختفى العرض الذي كنا نقف عليه (قبله سائق آخر) والقائمة قصرت.
    final page = _page.clamp(0, offers.length - 1);

    return PopScope(
      // نمنع الرجوع بزر النظام: القرار يُتخذ بأحد الزرين أو بانتهاء المهلة.
      // الخروج الصامت يترك العرض معلّقاً ويؤخّر الراكب.
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: SafeArea(
          child: Column(
            children: [
              if (offers.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'لديك ${offers.length} طلبات — مرّر للتنقّل بينها',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: offers.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (_, i) => _OfferCard(
                    // المفتاح بمعرّف العرض: بدونه تُعيد فلاتر استعمال حالة
                    // البطاقة السابقة، فيظهر عدّاد رحلة على أخرى.
                    key: ValueKey(offers[i]['id']),
                    offer: offers[i],
                  ),
                ),
              ),
              if (offers.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      offers.length,
                      (i) => Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == page
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// بطاقة عرض واحد
// =============================================================================
class _OfferCard extends ConsumerStatefulWidget {
  const _OfferCard({super.key, required this.offer});

  final Map<String, dynamic> offer;

  @override
  ConsumerState<_OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends ConsumerState<_OfferCard> {
  Timer? _ticker;
  int _remaining = 0;

  /// طول نافذة العرض كاملةً — مقام دائرة العدّاد.
  ///
  /// نحسبه من العرض نفسه (`expires_at - sent_at`) لا من ثابت في الكود:
  /// المهلة عمود في `pricing_zones` يختلف بين المناطق وقد يتغيّر بلا
  /// إعادة بناء التطبيق. دائرة تُقسَم على رقم ثابت تبدأ ممتلئة جزئياً
  /// أو تكتمل قبل أوانها.
  int _window = 45;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    // نحسب المتبقي من `expires_at` لا من طول النافذة: لو وصل العرض متأخراً
    // (شبكة بطيئة، أو استيقاظ من إشعار) فالمهلة الحقيقية أقل، وعدّاد يبدأ
    // من الأعلى كاذبٌ يجعل السائق يقبل عرضاً منتهياً فيُرفض بلا سبب مفهوم.
    final expires = DateTime.tryParse('${widget.offer['expires_at']}');
    final sent = DateTime.tryParse('${widget.offer['sent_at']}');
    if (expires != null) {
      _remaining = expires.difference(DateTime.now().toUtc()).inSeconds;
      if (_remaining < 0) _remaining = 0;
      if (sent != null) {
        final w = expires.difference(sent).inSeconds;
        if (w > 0) _window = w;
      }
    }

    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _remaining--);
      if (_remaining <= 0) t.cancel();
      // لا ننقل عند الصفر: المزوّد يُسقط العرض المنتهي من القائمة،
      // والموجّه يخرجنا حين تفرغ. التنقّل من هنا يتصادم معه.
    });
  }

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(driverRepositoryProvider)
          .acceptOffer(widget.offer['id'] as String);
      // شاشة الرحلة يفتحها الموجّه حين تتبدّل الرحلة النشطة —
      // لا ننقل يدوياً من هنا.
    } catch (e) {
      if (mounted) {
        setState(() {
          // أشيع خطأ هنا: "سبقك سائق آخر لهذه الرحلة" — نتيجة طبيعية
          // للبثّ المتوازي لا عطل، فنعرضها كما تأتي بالعربية.
          _error = AppError.message(e);
          _busy = false;
        });
      }
    }
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(driverRepositoryProvider)
          .rejectOffer(widget.offer['id'] as String);
    } catch (_) {
      // الرفض الفاشل لا يستحق إزعاجاً — المهلة ستنهيه على أي حال
    }
    // القائمة تقصر تلقائياً عبر البثّ اللحظي.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offer = widget.offer;

    final tripId = offer['trip_id'] as String;
    final tripAsync = ref.watch(offeredTripProvider(tripId));
    final stops = ref.watch(offeredStopsProvider(tripId)).value ?? const [];

    final distanceToRider = (offer['distance_m'] as num?)?.toInt() ?? 0;
    final etaSeconds = (offer['eta_s'] as num?)?.toInt() ?? 0;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // العدّاد — أبرز عنصر في الشاشة
          Center(
            child: SizedBox(
              width: 96,
              height: 96,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: CircularProgressIndicator(
                      value: (_remaining / _window).clamp(0.0, 1.0),
                      strokeWidth: 6,
                      color: _remaining <= 10
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                  ),
                  Text('$_remaining',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('طلب رحلة جديد',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),

          // **نوع الرحلة قبل أجرتها.** السائق الذي يقبل في خمس ثوانٍ يقرأ
          // الرقم الكبير وحده؛ ورحلةٌ بمحطتين أو فيها انتظار تغيّر قراره،
          // فيجب أن تصرخ لا أن تُذكر بخط صغير في آخر البطاقة.
          if (_kinds(tripAsync.value).isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                for (final k in _kinds(tripAsync.value))
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(k.$1,
                            size: 18,
                            color: theme.colorScheme.onTertiaryContainer),
                        const SizedBox(width: 6),
                        Text(k.$2,
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onTertiaryContainer)),
                      ],
                    ),
                  ),
              ],
            ),
          ],

          const SizedBox(height: 28),
          Expanded(
            child: SingleChildScrollView(
              child: tripAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => const SizedBox.shrink(),
                data: (t) {
                  if (t == null) return const SizedBox.shrink();
                  final fare = (t['fare_estimated_iqd'] as num?)?.round() ?? 0;
                  final tripKm =
                      ((t['estimated_distance_m'] as num?)?.toDouble() ?? 0) /
                          1000;

                  return Column(
                    children: [
                      // **الخريطة قبل الأرقام.** السائق يقرّر في ثوانٍ،
                      // وأول ما يحتاجه أن يرى إن كانت الرحلة في اتجاهه
                      // أم عكسه — والعنوان النصّي لا يرسم خطاً في الذهن.
                      OfferMap(
                        pickup: _point(t, 'pickup'),
                        // طلب مندوب بلا دبوس: الوجهة المحفوظة هي المتجر
                        // نفسه (0091) — رسمُها يضع المستلم عند الباب.
                        dropoff: _unpinned(t) ? null : _point(t, 'dropoff'),
                        stops: _stopPoints(stops),
                      ),
                      const SizedBox(height: 20),

                      // **طلب التسوّق يُعلَن قبل الأجرة.** السائق يدفع
                      // من جيبه، فأخطر ما يحتاج معرفته ليس ما سيكسب
                      // بل **ما سيُخرج الآن** — ومن قبِل بلا نقدٍ كافٍ
                      // يعتذر في المحل ويخسر الطرفان.
                      if (t['kind'] == 'shopping') ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.shopping_basket_outlined,
                                      size: 20),
                                  const SizedBox(width: 8),
                                  Text('طلب تسوّق',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.bold)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'تدفع تقريباً '
                                '${(t['goods_estimate_iqd'] as num?)?.round() ?? 0}'
                                ' دينار وتستردّها عند التسليم',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${((t['items'] as List?)?.length ?? 0)} سلعة',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],

                      // **طلب المندوب يُعلَن قبل الأجرة، كالتسوّق.** قد
                      // يُطلب منه دفع الثمن للمتجر مقدّماً، فما في جيبه
                      // جزءٌ من قراره.
                      if (t['kind'] == 'delivery') ...[
                        _DeliveryBanner(trip: t),
                        const SizedBox(height: 20),
                      ],

                      if (t['kind'] == 'delivery')
                        Text('سعر التوصيل — حدّده المتجر',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),

                      // الأجرة بأكبر خط في الشاشة — هي أساس القرار
                      Text('$fare دينار',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          )),
                      const SizedBox(height: 20),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              _Line(
                                icon: Icons.near_me,
                                label: 'المسافة إليك',
                                value: _fmtDistance(distanceToRider),
                                hint: etaSeconds > 0
                                    ? '~${(etaSeconds / 60).ceil()} دقيقة'
                                    : null,
                              ),
                              if (!_unpinned(t) && tripKm > 0) ...[
                                const Divider(height: 24),
                                _Line(
                                  icon: Icons.route,
                                  label: t['kind'] == 'delivery'
                                      ? 'من المتجر إلى المستلم'
                                      : 'طول الرحلة',
                                  value: '${tripKm.toStringAsFixed(1)} كم',
                                ),
                              ],
                              const Divider(height: 24),
                              _Line(
                                icon: Icons.trip_origin,
                                label: switch (t['kind']) {
                                  'shopping' => 'المحل',
                                  'delivery' => 'المتجر',
                                  _ => 'من',
                                },
                                // اسم المحل أولاً إن كتبه الراكب — هو ما
                                // يُعرف به المكان في السوق، لا العنوان.
                                value: [
                                  if (t['kind'] != 'ride' &&
                                      '${t['shop_name'] ?? ''}'.trim().isNotEmpty)
                                    '${t['shop_name']}'.trim(),
                                  '${t['pickup_address'] ?? ''}',
                                ].join(' — '),
                                small: true,
                              ),
                              const SizedBox(height: 12),
                              // **كل المحطات لا الأخيرة وحدها.**
                              // `dropoff_address` يحمل آخر وجهة، فرحلةٌ
                              // بمحطتين تبدو رحلةً عادية إلى مكان بعيد.
                              if (stops.length > 1)
                                for (final st in stops) ...[
                                  _Line(
                                    icon: st['seq'] == stops.length
                                        ? Icons.location_on
                                        : Icons.pin_drop_outlined,
                                    label: 'المحطة ${st['seq']}',
                                    value: '${st['address'] ?? ''}',
                                    small: true,
                                  ),
                                  const SizedBox(height: 12),
                                ]
                              else
                                _Line(
                                  icon: Icons.location_on,
                                  label: t['kind'] == 'delivery'
                                      ? (_unpinned(t)
                                          ? 'المستلم — عنوان مكتوب'
                                          : 'المستلم')
                                      : 'إلى',
                                  value: [
                                    '${t['dropoff_address'] ?? ''}',
                                    if ('${t['recipient_landmark'] ?? ''}'
                                        .trim()
                                        .isNotEmpty)
                                      'قرب ${t['recipient_landmark']}',
                                  ].join(' — '),
                                  small: true,
                                ),

                              if (t['has_stopover'] == true) ...[
                                const Divider(height: 24),
                                _Line(
                                  icon: Icons.pause_circle_outline,
                                  label: 'توقف في الطريق',
                                  value: 'الراكب سيتوقف — الأجرة تشمل '
                                      'انتظارك حتى عشر دقائق',
                                  small: true,
                                ),
                              ],
                              if ((t['rider_note'] as String?)?.isNotEmpty ??
                                  false) ...[
                                const Divider(height: 24),
                                _Line(
                                  icon: Icons.sticky_note_2_outlined,
                                  label: t['kind'] == 'delivery'
                                      ? 'ملاحظة المتجر'
                                      : 'ملاحظة الراكب',
                                  value: '${t['rider_note']}',
                                  small: true,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            ),
          ],

          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _reject,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(64),
                  ),
                  child: const Text('رفض'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _busy ? null : _accept,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(64),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.6))
                      : const Text('قبول', style: TextStyle(fontSize: 20)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmtDistance(int meters) =>
      meters < 1000 ? '$meters متر' : '${(meters / 1000).toStringAsFixed(1)} كم';
}

/// إحداثيات نقطةٍ من صفّ الرحلة. فارغة إن غابت — والخريطة تتصرّف.
(double, double)? _point(Map<String, dynamic> trip, String which) {
  final lat = trip['${which}_lat'];
  final lng = trip['${which}_lng'];
  if (lat is num && lng is num) return (lat.toDouble(), lng.toDouble());
  return null;
}

/// المحطات الوسيطة وحدها — الأخيرة هي الوجهة وتُرسم بعلامتها.
///
/// **ولماذا نستبعدها؟** لأن رسمها مرتين يضع علامتين فوق بعضهما، فيظنّ
/// السائق أن هناك محطة إضافية لا وجود لها.
///
/// ⚠️ **وتعود فارغةً اليوم.** `trip_stops` يخزّن الموقع في عمود
/// `geography`، ويعيده PostgREST بصيغة WKB سداسية لا تُقرأ هنا — ولا
/// أعمدة `lat/lng` مسطّحة له كما لـ`trips` (0014).
///
/// والأثر محدود: الخريطة ترسم الانطلاق والوجهة، وتفقد نقاطاً وسيطة في
/// رحلةٍ بمحطتين — وهي أقلّية. وإصلاحه يحتاج ترحيلاً يسطّح الإحداثيات
/// كما فُعل بـ`trips`، ولا يستحق تأخير هذه الشاشة.
List<(double, double)> _stopPoints(List<Map<String, dynamic>> stops) {
  if (stops.length < 2) return const [];
  final out = <(double, double)>[];
  for (final s in stops.take(stops.length - 1)) {
    final lat = s['lat'];
    final lng = s['lng'];
    if (lat is num && lng is num) out.add((lat.toDouble(), lng.toDouble()));
  }
  return out;
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.label,
    required this.value,
    this.hint,
    this.small = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? hint;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: small
                    ? theme.textTheme.bodyMedium
                    : theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        if (hint != null)
          Text(hint!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// شارات نوع الرحلة: ما يغيّر قرار السائق قبل أن يضغط قبول.
List<(IconData, String)> _kinds(Map<String, dynamic>? trip) {
  if (trip == null) return const [];
  final stops = (trip['stop_count'] as num?)?.toInt() ?? 1;
  return [
    // النوع أولاً: سائق التكتك الذي فتح طلبات الدراجات يحتاج أن يعرف
    // أيّهما بين يديه قبل أن ينظر إلى الأجرة.
    if (trip['vehicle_kind'] == 'tuktuk')
      (Icons.electric_rickshaw, 'طلب تكتك'),
    if (trip['vehicle_kind'] == 'stoota')
      (Icons.fire_truck_outlined, 'طلب ستوتة'),
    // الراكب رفع أجرته ليصل أسرع — وهذا ما يجعل الطلب يستحق الالتفات.
    if (((trip['fare_boost_pct'] as num?) ?? 0) > 0)
      (Icons.trending_up, 'سعر مرفوع +${(trip['fare_boost_pct'] as num).round()}٪'),
    if (stops > 1) (Icons.pin_drop, 'رحلة بـ$stops محطات'),
    if (trip['has_stopover'] == true) (Icons.pause_circle, 'توقف في الطريق'),
  ];
}

/// طلب مندوب بلا دبوس للمستلم — عنوانه مكتوبٌ فقط.
bool _unpinned(Map<String, dynamic> t) =>
    t['kind'] == 'delivery' && t['dropoff_pinned'] == false;

/// ما يميّز طلب المندوب: المركبة، وما قد يدفعه مقدّماً.
class _DeliveryBanner extends StatelessWidget {
  const _DeliveryBanner({required this.trip});
  final Map<String, dynamic> trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goods = (trip['goods_actual_iqd'] as num?)?.round() ?? 0;
    final vehicle = switch (trip['vehicle_kind']) {
      'tuktuk' => ' — تكتك',
      'stoota' => ' — ستوتة',
      _ => '',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.local_shipping_outlined, size: 20),
              const SizedBox(width: 8),
              Text('طلب مندوب$vehicle',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            goods > 0
                ? 'ثمن السلعة $goods دينار — تأخذه من المستلم مع أجرتك، '
                    'وقد يطلب المتجر أن تدفعه له مقدّماً'
                : 'بلا ثمن سلعة — تأخذ من المستلم أجرة التوصيل وحدها',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
