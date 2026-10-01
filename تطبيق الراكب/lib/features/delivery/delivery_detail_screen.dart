import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../trip/tracking_map.dart';
import 'deliveries_screen.dart';
import 'delivery_repository.dart';

/// طلب مندوبٍ واحد كما يتابعه التاجر — لحظياً.
class DeliveryDetailScreen extends ConsumerStatefulWidget {
  const DeliveryDetailScreen({super.key, required this.tripId});
  final String tripId;

  @override
  ConsumerState<DeliveryDetailScreen> createState() =>
      _DeliveryDetailScreenState();
}

class _DeliveryDetailScreenState extends ConsumerState<DeliveryDetailScreen> {
  bool _busy = false;
  String? _error;

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

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إلغاء الطلب'),
        content: const Text('هل تريد إلغاء طلب المندوب هذا؟'),
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
    if (ok == true) {
      await _run(() =>
          ref.read(deliveryRepositoryProvider).cancel(widget.tripId));
    }
  }

  /// «اطلب من جديد» — لطلبٍ لم يجد مندوباً أو أُلغي. البيانات نفسها بلا
  /// إعادة كتابة؛ والتاجر يستطيع أن يرفع السعر من طلبٍ جديد إن شاء.
  Future<void> _again(Map<String, dynamic> t) async {
    final pinned = t['dropoff_pinned'] != false;
    await _run(() => ref.read(deliveryRepositoryProvider).requestDelivery(
          recipientPhone: '${t['recipient_phone'] ?? ''}',
          recipientAddress: '${t['dropoff_address'] ?? ''}',
          landmark: t['recipient_landmark'] as String?,
          goodsPrice: (t['goods_actual_iqd'] as num?) ?? 0,
          fee: (t['fare_locked_iqd'] ?? t['fare_estimated_iqd'] ?? 0) as num,
          vehicle: '${t['vehicle_kind'] ?? 'bike'}',
          dropLat: pinned ? (t['dropoff_lat'] as num?)?.toDouble() : null,
          dropLng: pinned ? (t['dropoff_lng'] as num?)?.toDouble() : null,
          distanceM: (t['estimated_distance_m'] as num?)?.toInt(),
          durationS: (t['estimated_duration_s'] as num?)?.toInt(),
          note: t['rider_note'] as String?,
        ));
    if (mounted && _error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أُرسل طلبٌ جديد')),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = ref.watch(deliveryProvider(widget.tripId));

    if (t == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('طلب المندوب')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final status = '${t['status']}';
    final driverId = t['driver_id'] as String?;
    final failed = t['delivery_failed_at'] != null;
    final goods = ((t['goods_actual_iqd'] as num?) ?? 0).round();
    final fee = ((t['fare_final_iqd'] ?? t['fare_locked_iqd'] ??
            t['fare_estimated_iqd'] ?? 0) as num)
        .round();
    final canCancel =
        const {'searching', 'accepted', 'driver_arrived', 'no_drivers'}
            .contains(status);

    LatLng? point(String which) {
      final lat = t['${which}_lat'], lng = t['${which}_lng'];
      return lat is num && lng is num
          ? LatLng(lat.toDouble(), lng.toDouble())
          : null;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('طلب المندوب')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
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
          Text(deliveryStageLabel(t),
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          if (status == 'searching') ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],

          // ---- المندوب على الخريطة وهو قادم ----
          if (driverId != null &&
              (status == 'accepted' || status == 'in_progress') &&
              point('pickup') != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                height: 220,
                child: TrackingMap(
                  driverId: driverId,
                  pickup: point('pickup')!,
                  dropoff: t['dropoff_pinned'] == false ? null : point('dropoff'),
                  showDropoff: status == 'in_progress' && !failed,
                ),
              ),
            ),
          ],

          if (driverId != null) ...[
            const SizedBox(height: 12),
            _DriverCard(tripId: widget.tripId),
          ],

          if (status == 'driver_arrived') ...[
            const SizedBox(height: 16),
            PaymentAgreement(
              trip: t,
              mine: t['pay_choice_merchant'] as String?,
              theirs: t['pay_choice_driver'] as String?,
              theirsLabel: 'المندوب',
              busy: _busy,
              onChoose: (m) => _run(() => ref
                  .read(deliveryRepositoryProvider)
                  .choosePayment(widget.tripId, m)),
            ),
          ],

          if (failed) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'تعذّر التسليم: ${t['delivery_fail_reason'] ?? ''}\n'
                'المندوب يعيد الطرد إليك، وتدفع له '
                '${fee + (t['pay_mode'] == 'prepay' ? goods : 0)} دينار.',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],

          if (t['settle_status'] == 'claimed') ...[
            const SizedBox(height: 12),
            SettleConfirmCard(trip: t),
          ],

          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('المستلم',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('${t['dropoff_address'] ?? ''}'),
                  if ('${t['recipient_landmark'] ?? ''}'.trim().isNotEmpty)
                    Text('قرب ${t['recipient_landmark']}',
                        style: theme.textTheme.bodySmall),
                  Text('${t['recipient_phone'] ?? ''}',
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.end),
                  const Divider(height: 20),
                  _Line('ثمن السلعة', '$goods دينار'),
                  _Line('سعر التوصيل', '$fee دينار'),
                  _Line('يدفعه المستلم', '${goods + fee} دينار', bold: true),
                  if (t['pay_mode'] != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      t['pay_mode'] == 'prepay'
                          ? 'الاتفاق: دفع المندوب الثمن لك مقدّماً'
                          : 'الاتفاق: يعيد المندوب الثمن لك بعد التسليم',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ],
              ),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],

          if (status == 'no_drivers' || status == 'cancelled') ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : () => _again(t),
              icon: const Icon(Icons.refresh),
              label: const Text('اطلب من جديد بالبيانات نفسها'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
            ),
          ],

          // **لا إلغاء بعد أن يستلم المندوب الطرد** — القاعدة ترفضه أيضاً.
          if (canCancel && status != 'no_drivers') ...[
            const SizedBox(height: 12),
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
    );
  }
}

class _DriverCard extends ConsumerWidget {
  const _DriverCard({required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final d = ref.watch(deliveryDriverProvider(tripId)).value;
    if (d == null) return const SizedBox.shrink();
    final phone = d['phone'] as String?;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PartyAvatar(storagePath: d['avatar_url'] as String?, radius: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${d['full_name'] ?? 'المندوب'}',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text(
                        [
                          if (d['rating_avg'] != null)
                            '★ ${(d['rating_avg'] as num).toStringAsFixed(1)}',
                          if (d['vehicle_plate'] != null) '${d['vehicle_plate']}',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // الرقم يظهر ما دام الطلب نشطاً — العرض في القاعدة يُخفيه بعده.
            if (phone != null) ...[
              const SizedBox(height: 10),
              Text(phone,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.end),
              const SizedBox(height: 8),
              ContactButtons(
                phone: phone,
                message: 'مرحباً، أنا صاحب المتجر بخصوص طلب زنبور.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.a, this.b, {this.bold = false});
  final String a;
  final String b;
  final bool bold;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(a)),
            Text(b,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.bold : FontWeight.w500)),
          ],
        ),
      );
}
