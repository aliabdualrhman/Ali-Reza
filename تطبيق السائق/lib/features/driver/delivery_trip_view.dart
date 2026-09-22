import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';

/// طلب المندوب الجاري — عرضٌ مستقلّ عن شاشة الرحلة.
///
/// **لماذا ملفٌّ منفصل لا فروعٌ في `ActiveTripScreen`؟** تلك الشاشة تحمل
/// الرحلة والتسوّق والمحطات والتوقّف وتغيير الوجهة؛ وكل فرعٍ جديد فيها
/// يمسّ الأربعة. والمندوب مساره غير مسارها: متجرٌ، ثم اتفاقٌ على المال،
/// ثم مستلمٌ قد لا يكون على الخريطة، ثم تسليمٌ أو إعادة.
///
/// المراحل:
///   accepted       ← إلى المتجر، «وصلت إلى المتجر»
///   driver_arrived ← اتفاق الدفع، ثم «تم استلام الطلب»
///   in_progress    ← إلى المستلم، «تم تسليم الطلب» أو «تعذّر التسليم»
///   in_progress + فشل ← عودة إلى المتجر، «أعدتُ الطرد إلى المتجر»
class DeliveryTripView extends ConsumerStatefulWidget {
  const DeliveryTripView({super.key, required this.trip});

  final Map<String, dynamic> trip;

  @override
  ConsumerState<DeliveryTripView> createState() => _DeliveryTripViewState();
}

class _DeliveryTripViewState extends ConsumerState<DeliveryTripView> {
  bool _busy = false;
  String? _error;

  Map<String, dynamic> get t => widget.trip;
  String get _id => t['id'] as String;
  String get _status => '${t['status']}';
  bool get _failed => t['delivery_failed_at'] != null;
  bool get _pinned => t['dropoff_pinned'] != false;
  num get _fee => (t['fare_locked_iqd'] ?? t['fare_estimated_iqd'] ?? 0) as num;
  num get _goods => (t['goods_actual_iqd'] ?? 0) as num;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  DriverRepository get _repo => ref.read(driverRepositoryProvider);

  // ---------------------------------------------------------------------------
  // الملاحة
  // ---------------------------------------------------------------------------

  Future<void> _navigateTo(double lat, double lng) async {
    final candidates = <Uri>[
      Uri.parse('waze://?ll=$lat,$lng&navigate=yes'),
      // آيفون لا يعرف `google.navigation:` ولا `geo:` — انظر
      // `ActiveTripScreen._navigate`.
      Uri.parse('comgooglemaps://?daddr=$lat,$lng&directionsmode=driving'),
      Uri.parse('google.navigation:q=$lat,$lng'),
      Uri.parse('geo:$lat,$lng?q=$lat,$lng'),
      if (defaultTargetPlatform == TargetPlatform.iOS)
        Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=d'),
      Uri.parse('https://www.google.com/maps/dir/?api=1'
          '&destination=$lat,$lng&travelmode=driving'),
    ];
    await _launchFirst(candidates);
  }

  /// **المستلم بلا دبوس: نبحث عن عنوانه المكتوب.** خرائط جوجل تجد
  /// الشارع والحيّ في أغلب الأحيان، وهو خيرٌ من لا شيء — ثم الاتصال.
  Future<void> _searchAddress() async {
    final q = [
      '${t['dropoff_address'] ?? ''}',
      if ('${t['recipient_landmark'] ?? ''}'.trim().isNotEmpty)
        '${t['recipient_landmark']}',
      'الناصرية',
    ].join('، ');
    await _launchFirst([
      Uri.parse('comgooglemaps://?q=${Uri.encodeComponent(q)}'),
      Uri.parse('geo:0,0?q=${Uri.encodeComponent(q)}'),
      if (defaultTargetPlatform == TargetPlatform.iOS)
        Uri.parse('https://maps.apple.com/?q=${Uri.encodeComponent(q)}'),
      Uri.parse('https://www.google.com/maps/search/?api=1'
          '&query=${Uri.encodeComponent(q)}'),
    ]);
  }

  Future<void> _launchFirst(List<Uri> uris) async {
    for (final uri in uris) {
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _error = 'لم نجد تطبيق ملاحة على جهازك');
  }

  (double, double)? _point(String which) {
    final lat = t['${which}_lat'];
    final lng = t['${which}_lng'];
    if (lat is num && lng is num) return (lat.toDouble(), lng.toDouble());
    return null;
  }

  // ---------------------------------------------------------------------------
  // الإجراءات
  // ---------------------------------------------------------------------------

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إلغاء الطلب'),
        content: const Text(
            'المتجر ينتظرك. هل تريد إلغاء الطلب؟\n\n'
            'تنطبق قواعد الإلغاء المعتادة — بعد إلغاءاتك المجانية اليوم '
            'يُخصم مبلغ من رصيدك.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('إلغاء الطلب'),
          ),
        ],
      ),
    );
    if (ok == true) await _run(() => _repo.cancel(_id));
  }

  Future<void> _reportFailed() async {
    final ctl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعذّر التسليم'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('تعيد الطرد إلى المتجر، ويدفع لك المتجر أجرة التوصيل.'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in const [
                  'المستلم لا يجيب',
                  'المستلم رفض الاستلام',
                  'العنوان غير صحيح',
                ])
                  ActionChip(
                    label: Text(r),
                    onPressed: () => ctl.text = r,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'السبب'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('تراجع')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (reason == null || reason.isEmpty) return;
    await _run(() => _repo.reportDeliveryFailed(_id, reason));
  }

  Future<void> _complete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_failed ? 'أعدتَ الطرد؟' : 'سلّمتَ الطلب؟'),
        content: Text(_failed
            ? 'تؤكّد أنك أعدت الطرد إلى المتجر، وأخذت ${_returnDue.round()} دينار.'
            : 'تؤكّد أنك سلّمت الطلب وأخذت من المستلم '
                '${(_goods + _fee).round()} دينار.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('نعم'),
          ),
        ],
      ),
    );
    if (ok == true) await _run(() => _repo.completeDelivery(_id));
  }

  /// ما يأخذه المندوب من المتجر حين يُعيد الطرد: أجرته، وثمن السلعة إن
  /// كان دفعه مقدّماً.
  num get _returnDue => _fee + (t['pay_mode'] == 'prepay' ? _goods : 0);

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                TripCodeBadge(number: t['trip_number']),
                const Spacer(),
                if (t['vehicle_kind'] == 'tuktuk')
                  const Chip(label: Text('تكتك'))
                else if (t['vehicle_kind'] == 'stoota')
                  const Chip(label: Text('ستوتة')),
              ],
            ),
            const SizedBox(height: 12),
            _Steps(status: _status, failed: _failed),
            const SizedBox(height: 16),

            _StoreCard(trip: t, active: _status != 'in_progress' || _failed),
            const SizedBox(height: 10),
            _RecipientCard(
              trip: t,
              active: _status == 'in_progress' && !_failed,
            ),
            const SizedBox(height: 10),

            _MoneyCard(trip: t, failed: _failed, returnDue: _returnDue),

            if (_status == 'driver_arrived') ...[
              const SizedBox(height: 16),
              PaymentAgreement(
                trip: t,
                mine: t['pay_choice_driver'] as String?,
                theirs: t['pay_choice_merchant'] as String?,
                theirsLabel: 'المتجر',
                busy: _busy,
                onChoose: (m) =>
                    _run(() => _repo.chooseDeliveryPayment(_id, m)),
              ),
            ],

            if (_failed && _status == 'in_progress') ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'تعذّر التسليم: ${t['delivery_fail_reason'] ?? ''}\n'
                  'أعد الطرد إلى المتجر.',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_error!,
                    style:
                        TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ],

            const SizedBox(height: 20),
            _navButton(),
            const SizedBox(height: 10),
            _mainButton(),

            if (_status == 'in_progress' && !_failed) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : _reportFailed,
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('تعذّر التسليم'),
              ),
            ],

            // **لا إلغاء بعد الاستلام** — الطرد في يده. القاعدة ترفضه أيضاً.
            if (_status != 'in_progress') ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _cancel,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('إلغاء الطلب'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _navButton() {
    final toRecipient = _status == 'in_progress' && !_failed;

    if (toRecipient && !_pinned) {
      return OutlinedButton.icon(
        onPressed: _searchAddress,
        icon: const Icon(Icons.search),
        label: const Text('ابحث عن عنوان المستلم في الخرائط'),
      );
    }

    return OutlinedButton.icon(
      onPressed: () {
        final p = _point(toRecipient ? 'dropoff' : 'pickup');
        if (p != null) {
          _navigateTo(p.$1, p.$2);
        } else {
          setState(() => _error = 'تعذّر تحديد إحداثيات الوجهة');
        }
      },
      icon: const Icon(Icons.navigation),
      label: Text(toRecipient
          ? 'الملاحة إلى المستلم'
          : (_failed ? 'الملاحة إلى المتجر — إعادة الطرد' : 'الملاحة إلى المتجر')),
    );
  }

  Widget _mainButton() {
    final agreed = t['pay_mode'] != null;

    final (String label, Future<void> Function()? action) = switch (_status) {
      'accepted' => (
          'وصلت إلى المتجر',
          () => _run(() => _repo.advance(_id, 'driver_arrived')),
        ),
      // **الزرّ معطّلٌ حتى الاتفاق.** والقاعدة ترفضه أيضاً لو وصل.
      'driver_arrived' => (
          agreed ? 'تم استلام الطلب' : 'اتفقا على طريقة الدفع أولاً',
          agreed ? () => _run(() => _repo.advance(_id, 'in_progress')) : null,
        ),
      _ => (
          _failed ? 'أعدتُ الطرد إلى المتجر' : 'تم تسليم الطلب',
          _complete,
        ),
    };

    return FilledButton(
      onPressed: _busy || action == null ? null : action,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(60)),
      child: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.6))
          : Text(label, style: const TextStyle(fontSize: 18)),
    );
  }
}

// =============================================================================

class _Steps extends StatelessWidget {
  const _Steps({required this.status, required this.failed});
  final String status;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = failed
        ? const ['إلى المتجر', 'عند المتجر', 'إلى المستلم', 'إعادة إلى المتجر']
        : const ['إلى المتجر', 'عند المتجر', 'إلى المستلم'];
    final current = switch (status) {
      'accepted' => 0,
      'driver_arrived' => 1,
      _ => failed ? 3 : 2,
    };

    return Row(
      children: [
        for (var i = 0; i < steps.length; i++)
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: i <= current
                        ? (failed && i == 3
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 6),
                Text(steps[i],
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight:
                          i == current ? FontWeight.bold : FontWeight.normal,
                    )),
              ],
            ),
          ),
      ],
    );
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({required this.trip, required this.active});
  final Map<String, dynamic> trip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = trip['store_phone'] as String?;

    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.storefront, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('${trip['shop_name'] ?? 'المتجر'}',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('${trip['pickup_address'] ?? ''}',
                  style: theme.textTheme.bodyMedium),
              if (phone != null && active) ...[
                const SizedBox(height: 10),
                ContactButtons(
                  phone: phone,
                  message: 'مرحباً، أنا مندوب زنبور للطلب رقم '
                      '${trip['trip_number']}.',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RecipientCard extends StatelessWidget {
  const _RecipientCard({required this.trip, required this.active});
  final Map<String, dynamic> trip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = trip['recipient_phone'] as String?;
    final landmark = '${trip['recipient_landmark'] ?? ''}'.trim();

    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.person_pin_circle_outlined,
                      color: theme.colorScheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('المستلم',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                  if (trip['dropoff_pinned'] == false)
                    Text('بلا موقع على الخريطة',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 4),
              Text('${trip['dropoff_address'] ?? ''}',
                  style: theme.textTheme.bodyLarge),
              if (landmark.isNotEmpty)
                Text('أقرب نقطة دالة: $landmark',
                    style: theme.textTheme.bodyMedium),
              if (phone != null) ...[
                const SizedBox(height: 6),
                Text(phone,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodyMedium),
                const SizedBox(height: 8),
                ContactButtons(
                  phone: phone,
                  message: 'مرحباً، أنا مندوب زنبور ومعي طلبك من '
                      '${trip['shop_name'] ?? 'المتجر'}.',
                ),
              ],
              if ('${trip['rider_note'] ?? ''}'.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('ملاحظة المتجر: ${trip['rider_note']}',
                    style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MoneyCard extends StatelessWidget {
  const _MoneyCard({
    required this.trip,
    required this.failed,
    required this.returnDue,
  });
  final Map<String, dynamic> trip;
  final bool failed;
  final num returnDue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fee = ((trip['fare_locked_iqd'] ?? trip['fare_estimated_iqd'] ?? 0)
            as num)
        .round();
    final goods = ((trip['goods_actual_iqd'] ?? 0) as num).round();
    final mode = trip['pay_mode'] as String?;

    Widget line(String a, String b, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(child: Text(a)),
              Text(b,
                  style: TextStyle(
                      fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                      fontSize: bold ? 18 : null)),
            ],
          ),
        );

    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: failed
              ? [
                  line('تأخذ من المتجر', '${returnDue.round()} دينار',
                      bold: true),
                  Text(
                    mode == 'prepay'
                        ? 'أجرتك $fee + ثمن السلعة $goods الذي دفعته مقدّماً'
                        : 'أجرة التوصيل',
                    style: theme.textTheme.bodySmall,
                  ),
                ]
              : [
                  line('ثمن السلعة', '$goods دينار'),
                  line('سعر التوصيل', '$fee دينار'),
                  const Divider(),
                  line('تأخذ من المستلم', '${goods + fee} دينار', bold: true),
                  if (mode != null && goods > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      mode == 'prepay'
                          ? 'دفعتَ الثمن للمتجر — المبلغ كله لك.'
                          : 'ثمن السلعة ($goods) تعيده للمتجر بعد التسليم.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ],
        ),
      ),
    );
  }
}
