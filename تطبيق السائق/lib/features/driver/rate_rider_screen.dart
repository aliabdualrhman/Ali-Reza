import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';

/// تقييم السائق للراكب — شاشة كاملة يوجّه إليها الموجّه من الحالة.
///
/// **لماذا شاشة لا نافذة منبثقة؟** لأن النافذة تموت مع الشاشة التي
/// فتحتها. فتحناها من شاشة الرحلة، والموجّه ينقل السائق إلى الخريطة فور
/// اكتمال الرحلة — فظهرت واختفت في اللحظة نفسها.
///
/// وهذا هو المبدأ نفسه الذي تعلّمناه في الإشعارات: **التوجيه حسب الحالة
/// لا بعد الفعل.** ما دامت هناك رحلة مكتملة لم تُقيَّم، فهذه وجهة
/// التطبيق — تصمد أمام التصغير والتكبير، وإغلاق التطبيق وإعادة فتحه.
class RateRiderScreen extends ConsumerWidget {
  const RateRiderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(pendingRatingProvider);

    // اختفت الرحلة بينما نحن هنا (قُيّمت من جهاز آخر، أو أُجّلت).
    // الموجّه يخرجنا؛ هذه شاشة انتقالية لا أكثر.
    if (trip == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final tripId = trip['id'] as String;
    final riderId = trip['rider_id'] as String;
    final fare = (trip['fare_final_iqd'] as num?)?.round();
    final discount = (trip['discount_iqd'] as num?)?.round() ?? 0;

    // **ما يقبضه نقداً غير ما يستحقه.** حين يستعمل الراكب كوبوناً يدفع
    // أقل، ويدخل الفرق محفظة السائق تعويضاً. عرضُ الأجرة وحدها هنا يجعله
    // يطلب من الراكب مبلغاً لا يدين به — أسوأ خطأ ممكن في لحظة التسليم.
    final cash = fare == null ? null : fare - discount;

    return RatingView(
      title: 'انتهت الرحلة',
      subtitle: fare == null
          ? 'كيف كان الراكب؟'
          : discount > 0
              ? 'استلم نقداً $cash دينار — الراكب استعمل كوبوناً.\n'
                  'وأُضيف $discount دينار إلى رصيدك.'
              : 'أجرة $fare دينار · كيف كان الراكب؟',
      onSubmit: (stars, comment, tags, amount) async {
        await ref.read(driverRepositoryProvider).rateRider(
              tripId: tripId,
              riderId: riderId,
              stars: stars,
              comment: comment,
              tags: tags,
              reportedAmount: amount,
            );
        // البثّ يُسقط الرحلة من المزوّد بعد الإدراج، لكن استعلام
        // التقييمات مخزّن — نُبطله ليعيد الفحص فوراً بدل انتظار حدث.
        ref.invalidate(unratedTripProvider);
      },
      onSkip: () => ref.read(skippedRatingsProvider.notifier).skip(tripId),
    );
  }
}
