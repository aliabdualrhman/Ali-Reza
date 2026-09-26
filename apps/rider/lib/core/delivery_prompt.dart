import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_router.dart';
import '../features/auth/auth_repository.dart';
import '../features/delivery/delivery_repository.dart';

/// يفتح صفحة الطلب للراكب لحظةَ وصول المندوب، بلا أن يضغط شيئاً.
///
/// **لماذا لا ننتظر ضغطةً منه؟** لأن المندوب واقفٌ أمامه الآن ينتظر أن
/// يتّفقا على طريقة الدفع، والاتفاق يُثبَّت حين يختار كلاهما الخيار
/// نفسه (0091). فما دام الراكب لم يفتح الطلب، يقف الرجلان ينظران إلى
/// هاتفين — أحدهما يعرض «بانتظار اختيار المتجر» والآخر لا يعرض شيئاً.
///
/// **ولا نصنع شاشةً ثانية للدفع.** صفحة الطلب تحمل `PaymentAgreement`
/// أصلاً، ومعها المبلغ وبطاقة المندوب والخريطة — وهي السياق الذي يحتاجه
/// من يقرّر. شاشةٌ منفصلة تعرض زرّين بلا سياق تُربك لا تُسرّع.
///
/// **ويُفتح مرّةً واحدة لكل طلب.** بلا ذلك يعيده كلّ تحديثٍ يصل من
/// التدفّق إلى الشاشة نفسها، فلا يستطيع الخروج منها ليقرأ شيئاً آخر.
class DeliveryPaymentPrompt {
  DeliveryPaymentPrompt(this._ref);

  final Ref _ref;

  /// الطلبات التي فُتحت صفحتها في هذه الجلسة.
  final Set<String> _opened = {};

  void listen() {
    _ref.listen<AsyncValue<List<Map<String, dynamic>>>>(
      myDeliveriesProvider,
      (_, next) {
        final rows = next.value;
        if (rows == null) return;

        // بلا جلسة لا وجهة: الموجّه سيردّه إلى الدخول، ودفعةُ مسارٍ
        // تُلغى فوراً تترك أثراً في سجلّ التنقّل بلا فائدة.
        if (_ref.read(sessionProvider) == null) return;

        final router = _ref.read(routerProvider);
        final here = router.routerDelegate.currentConfiguration.uri.path;

        for (final t in rows) {
          final id = '${t['id']}';

          // **غادر الحالة فيُنسى.** لو عاد الطلب إلى `driver_arrived`
          // بعد أن تجاوزها — تعذّر تسليم ثم عودة — يستحقّ فتحاً جديداً.
          if ('${t['status']}' != 'driver_arrived') {
            _opened.remove(id);
            continue;
          }

          // اختار فعلاً: لا شيء ينتظره على تلك الصفحة.
          if (t['pay_choice_merchant'] != null) continue;

          if (!_opened.add(id)) continue;
          if (here == '/delivery/$id') continue;

          router.push('/delivery/$id');
        }
      },
      fireImmediately: true,
    );
  }
}

final deliveryPaymentPromptProvider = Provider<DeliveryPaymentPrompt>(
  DeliveryPaymentPrompt.new,
);
