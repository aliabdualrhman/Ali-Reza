import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';
import '../shared/ratings_section.dart';
import 'trips_page.dart';
import '../../core/perms.dart';

final tripDetailProvider =
    FutureProvider.family<Map<String, dynamic>?, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).tripDetail(id),
);
final tripStopsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).tripStops(id),
);
final tripChangesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).tripChanges(id),
);

/// كل ما نعرفه عن رحلة واحدة.
///
/// **تُعرض الحقول الفارغة أيضاً حين تكون ذات دلالة.** رحلةٌ بلا سائق
/// وبلا سبب إلغاء تقول شيئاً؛ وإخفاء الفراغ يجعل الصفحة تبدو كاملة وهي
/// ناقصة، فيُقفل التحقيق في العطل قبل أن يبدأ.
class TripDetailPage extends ConsumerWidget {
  const TripDetailPage({super.key, required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(tripDetailProvider(tripId));

    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل الرحلة')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e,
            onRetry: () => ref.invalidate(tripDetailProvider(tripId))),
        data: (t) {
          if (t == null) return const Center(child: Text('الرحلة غير موجودة'));

          final status = '${t['status']}';
          final live = const {
            'searching', 'accepted', 'driver_arrived', 'in_progress'
          }.contains(status);
          final driver = driverProfile(t);
          final rider = t['rider'] as Map<String, dynamic>?;
          final coupon = t['coupon'] as Map<String, dynamic>?;
          final stops = ref.watch(tripStopsProvider(tripId)).value ?? const [];
          final changes =
              ref.watch(tripChangesProvider(tripId)).value ?? const [];

          final discount = (t['discount_iqd'] as num?)?.round() ?? 0;
          final fare =
              ((t['fare_final_iqd'] ?? t['fare_estimated_iqd']) as num?)?.round();

          final shopping = t['kind'] == 'shopping';
          final delivery = t['kind'] == 'delivery';
          final items = (t['items'] as List?) ?? const [];

          return ListView(
            padding: EdgeInsets.all(Breaks.pad(context)),
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // الرمز أولاً وبخطّ ثابت العرض: هو ما يُملى على الدعم،
                  // وهو الرابط الوحيد بين ما يراه المدير وما يراه الراكب
                  // والسائق في سجلاتهم.
                  TripCodeBadge(number: t['trip_number']),
                  // **نوع الطلب أول ما يُقرأ.** المدير الذي يحكم في
                  // خلافٍ يجب أن يعرف قبل كل شيء أهذه رحلةُ راكب أم
                  // طلبُ تسوّقٍ دفع فيه السائق من جيبه — فالحكم يختلف.
                  if (shopping)
                    Chip(
                      avatar: const Icon(Icons.shopping_basket_outlined,
                          size: 18),
                      label: const Text('طلب تسوّق'),
                      backgroundColor:
                          AdminTheme.warning.withValues(alpha: 0.18),
                      side: BorderSide(
                          color: AdminTheme.warning.withValues(alpha: 0.5)),
                    ),
                  if (delivery)
                    Chip(
                      avatar: const Icon(Icons.local_shipping_outlined,
                          size: 18),
                      label: Text(switch (t['vehicle_kind']) {
                        'tuktuk' => 'طلب مندوب — تكتك',
                        'stoota' => 'طلب مندوب — ستوتة',
                        _ => 'طلب مندوب',
                      }),
                      backgroundColor:
                          AdminTheme.warning.withValues(alpha: 0.18),
                      side: BorderSide(
                          color: AdminTheme.warning.withValues(alpha: 0.5)),
                    ),
                  Chip(label: Text(statusLabel(status))),
                  if (live && can(ref, 'trips.cancel'))
                    FilledButton.icon(
                      onPressed: () => _cancel(context, ref, tripId),
                      icon: const Icon(Icons.cancel),
                      label: const Text('إلغاء الرحلة'),
                      style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error),
                    ),
                ],
              ),
              const SizedBox(height: 24),

              _Section('الأطراف', [
                _F('الراكب', '${rider?['full_name'] ?? '—'}'),
                _F('هاتف الراكب', '${rider?['phone'] ?? '—'}', ltr: true),
                _F('السائق', '${driver?['full_name'] ?? 'لم يُسند بعد'}'),
                _F('هاتف السائق', '${driver?['phone'] ?? '—'}', ltr: true),
              ]),

              _Section(shopping ? 'المسار — المتجر ثم التسليم' : 'المسار', [
                _F(shopping ? 'المتجر' : 'الانطلاق',
                    '${t['pickup_address'] ?? '—'}'),
                for (final s in stops)
                  _F('المحطة ${s['seq']}',
                      '${s['address'] ?? '—'}'
                      '${s['arrived_at'] != null ? '  ✓ ${fmtDateTime(s['arrived_at'])}' : ''}'),
                if (stops.isEmpty)
                  _F(shopping ? 'نقطة التسليم' : 'الوجهة',
                      '${t['dropoff_address'] ?? '—'}'),
                _F('المسافة',
                    '${(((t['actual_distance_m'] ?? t['estimated_distance_m']) as num? ?? 0) / 1000).toStringAsFixed(1)} كم'),
              ]),

              // **قائمة الطلب كاملةً.** المدير الذي يحكم في خلافٍ على
              // السعر لا يستطيع أن يحكم بلا أن يرى ما طُلب فعلاً —
              // وهي مكتوبةٌ في القاعدة منذ الطلب بلا مكانٍ تُقرأ فيه.
              if (shopping) ...[
                _Section('الطلب', [
                  for (final i in items)
                    _F('${(i as Map)['name'] ?? '—'}',
                        '${i['qty'] ?? ''}'),
                  if (items.isEmpty) _F('', 'لا سلع مسجّلة'),
                ]),

                _Section('ثمن البضاعة', [
                  _F('قدّره الراكب',
                      '${(t['goods_estimate_iqd'] as num?)?.round() ?? 0} دينار'),
                  _F(
                    'دفعه السائق',
                    t['goods_actual_iqd'] == null
                        ? 'لم يُسجَّل بعد'
                        : '${(t['goods_actual_iqd'] as num).round()} دينار',
                  ),
                  // **الفرق محسوبٌ لا متروكٌ للحساب الذهني.** هو أول ما
                  // يُسأل عنه في خلافٍ على السعر.
                  if (t['goods_actual_iqd'] != null)
                    _F(
                      'الفرق',
                      () {
                        final d = ((t['goods_actual_iqd'] as num) -
                                ((t['goods_estimate_iqd'] as num?) ?? 0))
                            .round();
                        return d == 0
                            ? 'مطابق'
                            : (d > 0 ? 'زاد $d دينار' : 'نقص ${-d} دينار');
                      }(),
                    ),
                ]),
              ],

              // **كل ما يُحتاج في خلافٍ بين متجرٍ ومندوب.** من دفع
              // لمن، ومتى، وهل وصل الطرد — ولا أحد منهما يرى الآخر
              // إلا عبر هذه الصفحة.
              if (delivery) ..._deliverySections(context, ref, t),

              _Section(shopping ? 'تفاصيل الطلب' : 'نوع الرحلة', [
                _F('عدد المحطات', '${t['stop_count'] ?? 1}'),
                _F('توقف في الطريق', t['has_stopover'] == true ? 'نعم' : 'لا'),
                _F('تغيير وجهة',
                    changes.isEmpty ? 'لا' : '${changes.length} طلب'),
                _F('كوبون',
                    coupon == null
                        ? 'لا'
                        : '${coupon['code']} — خصم ${coupon['discount_pct']}٪'),
              ]),

              if (changes.isNotEmpty)
                _Section('طلبات تغيير الوجهة', [
                  for (final c in changes)
                    _F(
                      fmtDateTime(c['created_at']),
                      '${c['new_address'] ?? '—'}  ·  '
                      '${_changeLabel('${c['status']}')}  ·  '
                      '${(c['quoted_fare_iqd'] as num?)?.round() ?? 0} دينار',
                    ),
                ]),

              _Section('المال', [
                _F('الأجرة', fare == null ? '—' : '$fare دينار'),
                if (discount > 0) ...[
                  _F('الخصم', '$discount دينار'),
                  _F('المدفوع نقداً',
                      fare == null ? '—' : '${fare - discount} دينار'),
                ],
                _F('العمولة',
                    '${(t['commission_iqd'] as num?)?.round() ?? 0} دينار'),
                _F('للسائق',
                    '${(t['driver_earning_iqd'] as num?)?.round() ?? 0} دينار'),
                if ((t['cancellation_fee_iqd'] as num? ?? 0) > 0)
                  _F('رسوم الإلغاء',
                      '${(t['cancellation_fee_iqd'] as num).round()} دينار'),

                // **ما سلّمه الراكب وما أُعيد إليه.** هما ما يُقارَن
                // بشكوى «لم يُعِد الباقي» — وبدونهما لا يُحسم خلاف.
                if (t['cash_received_iqd'] != null)
                  _F('سلّم الراكب',
                      '${(t['cash_received_iqd'] as num).round()} دينار'),
                if ((t['change_returned_iqd'] as num? ?? 0) > 0)
                  _F('أُعيد إلى محفظته',
                      '${(t['change_returned_iqd'] as num).round()} دينار'),
              ]),

              _Section('الأوقات', [
                _F('الطلب', fmtDateTime(t['requested_at'])),
                _F('القبول', fmtDateTime(t['accepted_at'])),
                _F('البدء', fmtDateTime(t['started_at'])),
                _F('الإنهاء', fmtDateTime(t['completed_at'])),
                if (t['cancelled_at'] != null) ...[
                  _F('الإلغاء', fmtDateTime(t['cancelled_at'])),
                  _F('سبب الإلغاء', '${t['cancellation_reason'] ?? '—'}'),
                ],
              ]),

              if ((t['rider_note'] as String?)?.isNotEmpty ?? false)
                _Section('ملاحظة الراكب', [_F('', '${t['rider_note']}')]),

              // **التقييمان متقابلان في آخر الصفحة.** بعد أن يقرأ المدير
              // المسار والمال والأوقات، يقرأ ما قاله الطرفان — فيحكم
              // على خلافٍ يعرف وقائعه، لا على شكوى وحدها.
              TripRatingsSection(tripId: t['id'] as String),
            ],
          );
        },
      ),
    );
  }
}

String _changeLabel(String s) => switch (s) {
      'pending' => 'بانتظار السائق',
      'approved' => 'وافق السائق',
      'rejected' => 'اعتذر السائق',
      _ => s,
    };

Future<void> _cancel(BuildContext context, WidgetRef ref, String id) async {
  final reason = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('إلغاء الرحلة'),
      content: SizedBox(
        width: Breaks.dialogWidth(ctx, 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('إلغاء إداري بلا رسوم على الراكب ولا عقوبة على السائق.'),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'السبب',
                hintText: 'يظهر في سجل الرحلة وسجل التدقيق',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إلغاء الرحلة')),
      ],
    ),
  );

  if (ok == true) {
    try {
      await ref.read(adminRepositoryProvider).cancelTrip(id, reason.text.trim());
      ref.invalidate(tripDetailProvider(id));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
  reason.dispose();
}

// =============================================================================
class _Section extends StatelessWidget {
  const _Section(this.title, this.fields);
  final String title;
  final List<Widget> fields;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ...fields,
            ],
          ),
        ),
      );
}

class _F extends StatelessWidget {
  const _F(this.label, this.value, {this.ltr = false});
  final String label;
  final String value;
  final bool ltr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: Breaks.isCompact(context) ? 110 : 150,
            child: Text(label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(value,
                textDirection: ltr ? TextDirection.ltr : null),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// طلب المندوب
// =============================================================================

String _payLabel(Object? m) => switch (m) {
      'prepay' => 'المندوب يدفع الثمن مقدّماً',
      'after' => 'المندوب يعيد الثمن بعد التسليم',
      _ => 'لم يختر',
    };

String _settleLabel(Object? s) => switch (s) {
      'open' => 'مفتوحة — لم يُعِد المندوب الثمن',
      'claimed' => 'المندوب يقول أعاده — بانتظار المتجر',
      'disputed' => 'نزاع — المتجر يقول لم يصله',
      'closed' => 'مغلقة',
      _ => 'لا مستحقات',
    };

List<Widget> _deliverySections(
    BuildContext context, WidgetRef ref, Map<String, dynamic> t) {
  final goods = (t['goods_actual_iqd'] as num?)?.round() ?? 0;
  final fee =
      ((t['fare_final_iqd'] ?? t['fare_locked_iqd'] ?? 0) as num).round();
  final settle = t['settle_status'] as String?;

  return [
    _Section('المتجر والمستلم', [
      _F('المتجر', '${t['shop_name'] ?? '—'}'),
      _F('هاتف المتجر', '${t['store_phone'] ?? '—'}', ltr: true),
      _F('هاتف المستلم', '${t['recipient_phone'] ?? '—'}', ltr: true),
      _F('عنوان المستلم', '${t['dropoff_address'] ?? '—'}'),
      _F('أقرب نقطة دالة', '${t['recipient_landmark'] ?? '—'}'),
      _F('دبوس على الخريطة', t['dropoff_pinned'] == false ? 'لا' : 'نعم'),
    ]),
    _Section('مبالغ طلب المندوب', [
      _F('ثمن السلعة', '$goods دينار'),
      _F('سعر التوصيل (حدّده المتجر)', '$fee دينار'),
      _F('يدفعه المستلم', '${goods + fee} دينار'),
    ]),
    _Section('اتفاق الدفع عند المتجر', [
      _F('اختيار المتجر', _payLabel(t['pay_choice_merchant'])),
      _F('اختيار المندوب', _payLabel(t['pay_choice_driver'])),
      _F('المتفق عليه',
          t['pay_mode'] == null
              ? 'لم يتفقا بعد'
              : '${_payLabel(t['pay_mode'])} · ${fmtDateTime(t['pay_agreed_at'])}'),
    ]),
    _Section('النتيجة والمستحقات', [
      _F('النتيجة', switch (t['delivery_outcome']) {
        'delivered' => 'سُلّم للمستلم',
        'returned' => 'أُعيد إلى المتجر',
        _ => t['delivery_failed_at'] != null ? 'تعذّر التسليم — في طريق العودة' : '—',
      }),
      if (t['delivery_fail_reason'] != null)
        _F('سبب التعذّر', '${t['delivery_fail_reason']}'),
      _F('المستحقات', _settleLabel(settle)),
      if (t['settle_claimed_at'] != null)
        _F('أعلن المندوب', fmtDateTime(t['settle_claimed_at'])),
      if (t['settle_closed_at'] != null)
        _F('أُغلقت', fmtDateTime(t['settle_closed_at'])),
    ]),
    if (settle != null && settle != 'closed' && can(ref, 'deliveries.settle'))
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            onPressed: () => closeSettlementDialog(context, ref, t),
            icon: const Icon(Icons.task_alt),
            label: const Text('إغلاق المستحقات من الإدارة'),
          ),
        ),
      ),
  ];
}

/// الإدارة تُغلق المستحقات — بعد أن تتصل بالطرفين. يُسجَّل في التدقيق.
Future<void> closeSettlementDialog(
    BuildContext context, WidgetRef ref, Map<String, dynamic> t) async {
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('إغلاق مستحقات الطلب ${t['trip_number']}'),
      content: TextField(
        controller: note,
        decoration: const InputDecoration(
            labelText: 'ملاحظة (اختيارية) — تُحفظ في سجلّ التدقيق'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إغلاق')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref
        .read(adminRepositoryProvider)
        .closeSettlement(t['id'] as String, note.text.trim());
    ref.invalidate(tripDetailProvider(t['id'] as String));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('أُغلقت المستحقات')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(adminError(e))));
    }
  }
}
