import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'trip_repository.dart';

/// تقييم الراكب للسائق — شاشة كاملة يوجّه إليها الموجّه من الحالة.
///
/// **المبدأ نفسه الذي تعلّمناه في الإشعارات: التوجيه حسب الحالة لا بعد
/// الفعل.** ما دامت هناك رحلة مكتملة لم تُقيَّم، فهذه وجهة التطبيق —
/// تصمد أمام التصغير والتكبير، وإغلاق التطبيق وإعادة فتحه.
class RateDriverScreen extends ConsumerStatefulWidget {
  const RateDriverScreen({super.key});

  @override
  ConsumerState<RateDriverScreen> createState() => _RateDriverScreenState();
}

class _RateDriverScreenState extends ConsumerState<RateDriverScreen> {
  /// هل رأى الراكب شاشة الدفع؟
  ///
  /// **في الحالة لا في القاعدة.** ليست حقيقةً عن الرحلة بل عن هذه
  /// الجلسة؛ ومن أغلق التطبيق وعاد يستحق أن يرى المبلغ ثانيةً — فالنقد
  /// لم يُسلَّم بعدُ في الأغلب.
  bool _paid = false;

  @override
  Widget build(BuildContext context) {
    final trip = ref.watch(pendingRatingProvider);

    if (trip == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_paid) {
      return _PaymentDue(
        trip: trip,
        onDone: () => setState(() => _paid = true),
      );
    }

    final tripId = trip['id'] as String;
    final driverId = trip['driver_id'] as String;
    final fare = (trip['fare_final_iqd'] as num?)?.round();

    return RatingView(
      title: 'وصلت',
      subtitle: fare == null
          ? 'كيف كان سائقك؟'
          : 'أجرة $fare دينار · كيف كان سائقك؟',
      onSubmit: (stars, comment, tags, amount) async {
        await ref.read(tripRepositoryProvider).rateDriver(
              tripId: tripId,
              driverId: driverId,
              stars: stars,
              comment: comment,
              tags: tags,
              reportedAmount: amount,
            );
        // البثّ يُبلّغ بتبدّل الرحلة، لكن استعلام التقييمات مخزّن —
        // نُبطله ليعيد الفحص فوراً بدل انتظار حدث.
        ref.invalidate(unratedTripProvider);
      },
      onSkip: () => ref.read(skippedRatingsProvider.notifier).skip(tripId),
    );
  }
}

/// **المبلغ قبل النجوم.**
///
/// كانت شاشة التقييم تظهر لحظةَ يضغط السائق «وصلت»، والراكب لم يُخبَر
/// بعدُ كم يدفع — فيُسأل عن رأيه في خدمةٍ لم يدفع ثمنها. والأسوأ في
/// التسوّق: ثمن السلعة يتبدّل بين الطلب والتسليم، فينتهي كلُّ طلبٍ
/// بجدالٍ في الشارع.
///
/// **ولا تُتخطّى.** التقييم يُتخطّى — وهو رأيٌ لا دَين — أما المبلغ
/// فيُقرأ ويُقرَّ.
class _PaymentDue extends StatelessWidget {
  const _PaymentDue({required this.trip, required this.onDone});

  final Map<String, dynamic> trip;
  final VoidCallback onDone;

  double _n(String k) => (trip[k] as num?)?.toDouble() ?? 0;
  double? _o(String k) => (trip[k] as num?)?.toDouble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shopping = trip['kind'] == 'shopping';

    final fare = _o('fare_final_iqd') ?? _n('fare_estimated_iqd');
    final goodsActual = _o('goods_actual_iqd');
    final goods = goodsActual ?? _o('goods_estimate_iqd');
    final discount = _n('discount_iqd');
    final credit = _n('credit_used_iqd');

    // **`cash_due_iqd` أولاً دائماً.** تحسبه القاعدة في
    // `settle_rider_credit`، وهي وحدها تعرف ما استُهلك من الرصيد.
    // والحساب اليدوي هنا احتياطٌ لصفٍّ قديم لا أكثر — واختلافُ الرقمين
    // في وجه الراكب أسوأ من غيابهما.
    final total =
        _o('cash_due_iqd') ?? (fare - discount + (shopping ? goods ?? 0 : 0));

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(Icons.payments_outlined,
                  size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 14),
              Text(
                shopping ? 'وصل طلبك' : 'وصلت',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'ادفع هذا المبلغ للكابتن نقداً',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),

              FareBreakdown(
                fare: fare,
                total: total,
                discount: discount,
                creditUsed: credit,
                goods: shopping ? goods : null,
                // عند الإكمال يكون السائق قد اشترى — والسعر فعليّ.
                goodsIsFinal: goodsActual != null,
                shopping: shopping,
                title: 'تفاصيل المبلغ',
              ),

              if (credit > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'خُصم ${credit.round()} دينار من رصيدك — لا تدفعها نقداً.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.green.shade700),
                ),
              ],

              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: onDone,
                icon: const Icon(Icons.check),
                label: const Text('دفعت — التالي'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
