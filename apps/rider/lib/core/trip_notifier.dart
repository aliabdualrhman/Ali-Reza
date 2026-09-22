import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/trip/trip_repository.dart';
import 'push_service.dart';

/// يُشعر الراكب بتقدّم رحلته **من داخل التطبيق**، بلا مرور بفايربيز.
///
/// **لماذا طبقة ثانية والخادم يرسل أصلاً؟** لأن الأولى تفشل كثيراً في
/// سوقنا. الإشعار البعيد يمرّ بخدمات Google، وهي غائبة أو معطوبة على
/// أجهزة كثيرة — نسخٌ بلا GMS، أو خدماتٌ قديمة، أو شبكةٌ تحجب خوادم
/// جوجل. يظهر العطل هكذا في السجلّ:
///
///     java.io.IOException: SERVICE_NOT_AVAILABLE
///
/// وحينها لا يملك الخادم رمزاً يرسل إليه، فيصمت التطبيق تماماً مهما
/// كانت أذوناته صحيحة. رصدناه على جهاز مختبِر، ثم على جهاز المطوّر.
///
/// **وهذه الطبقة لا تحتاج جوجل إطلاقاً.** تُصغي إلى نفس تدفّق الرحلة
/// الذي تقرأه الشاشة، وتعرض إشعاراً محلياً عند تبدّل الحالة.
///
/// **وحدّها الذي لا تتجاوزه:** تعمل ما دامت عملية التطبيق حيّة — على
/// الشاشة أو خلفها. فإن قتلها النظام لم يبقَ إلا FCM. فهي تكملة لا
/// بديل، وبها يعمل الراكب على جهاز بلا خدمات Google ما دام التطبيق
/// مفتوحاً.
class TripNotifier {
  TripNotifier(this._ref);

  final Ref _ref;

  /// آخر حالة أُشعر بها. **نبدأ من `null` لا من `searching`** كي لا
  /// نُشعر بحالةٍ قائمة عند إقلاع التطبيق: من يفتح التطبيق ورحلته
  /// مقبولة سلفاً لا يريد إشعاراً بأنها قُبلت قبل ربع ساعة.
  TripStatus? _last;
  String? _tripId;

  /// ثمن السلعة الحقيقي الذي أُشعرنا به. يُملأ مرّةً في عمر الطلب.
  double? _lastGoods;

  void listen() {
    // **`lastTripProvider` لا `activeTripProvider`.** الثاني يردّ
    // `null` للرحلة المنتهية — وهو صحيحٌ للشاشة، لكنه يُخرس هذا
    // المُشعِر عند الإلغاء والإكمال بالضبط: أهمّ خبرين ينتظرهما
    // الراكب.
    _ref.listen<AsyncValue<Trip?>>(lastTripProvider, (_, next) {
      final trip = next.value;

      if (trip == null) {
        _last = null;
        _tripId = null;
        _lastGoods = null;
        return;
      }

      // رحلة جديدة: نسجّل حالتها ولا نُشعر بها.
      if (trip.id != _tripId) {
        _tripId = trip.id;
        _last = trip.status;
        _lastGoods = trip.goodsActual;
        return;
      }

      // **ثمن السلعة يتبدّل والحالة ثابتة.** السائق في المتجر يكتب ما
      // دفعه فعلاً، فلا حالةَ تتغيّر ولا إشعارَ يخرج من الفرع أدناه —
      // والراكب يفاجأ بالمبلغ عند الباب. وهذا أخطر جدالٍ في التسوّق.
      if (trip.goodsActual != null && trip.goodsActual != _lastGoods) {
        _lastGoods = trip.goodsActual;
        PushService.showLocal(
          id: (trip.id.hashCode ^ 0x9E3779B9) & 0x7fffffff,
          title: 'تمّ إبلاغك بالأسعار الحقيقية',
          body: 'ثمن السلعة ${trip.goodsActual!.round()} دينار في السوق. '
              'المجموع ${trip.totalDue.round()} دينار مع أجرة التوصيل.',
          payload: {'type': 'goods_priced', 'trip_id': trip.id},
        );
      }

      if (trip.status == _last) return;
      _last = trip.status;

      final msg = _messageFor(
        trip.status,
        shopping: trip.isShopping,
        // **من ألغى؟ سؤالٌ يسأله الراكب أولاً.** إشعارٌ يقول «أُلغيت
        // الرحلة» وهو لم يُلغِ شيئاً يجعله يتّهم نفسه بأنه ضغط زرّاً
        // بالخطأ، أو يظنّ التطبيق معطوباً.
        byDriver: trip.driverId != null && trip.cancelledBy == trip.driverId,
      );
      if (msg == null) return;

      PushService.showLocal(
        // **معرّف مشتق من الرحلة.** إشعارات الرحلة الواحدة تتتابع —
        // قُبلت، وصل، انتهت — ومعرّفٌ ثابت يجعل كلاً يحلّ محلّ سابقه
        // بدل أن تتكدّس ثلاثة عن رحلةٍ واحدة.
        id: trip.id.hashCode & 0x7fffffff,
        title: msg.$1,
        body: msg.$2,
        payload: {'type': 'trip_status', 'trip_id': trip.id},
      );
    });
  }

  /// **لا نُشعر بكل تبدّل.** `inProgress` يحدث والراكب على الدراجة ينظر
  /// إلى السائق؛ وإشعارٌ حينها ضجيج. وأول ما يفعله المستخدم بالضجيج أن
  /// يُسكت القناة كلها، فيفقد إشعار الوصول معها.
  ///
  /// والنصوص هي نصوص `notify-rider` نفسها — فمن تصله الطبقتان معاً لا
  /// يرى رسالتين مختلفتين عن حدثٍ واحد.
  (String, String)? _messageFor(
    TripStatus s, {
    bool byDriver = false,
    bool shopping = false,
  }) =>
      switch (s) {
        // **مراحل التسوّق ثلاث لا مراحل رحلة.** «في الطريق إليك» عند
        // القبول كذبةٌ تُنزل الراكب إلى الباب ليقف ربع ساعة — والسائق
        // في المتجر.
        TripStatus.accepted => shopping
            ? ('قُبل طلبك', 'السائق في طريقه إلى المتجر')
            : ('قُبل طلبك', 'السائق في الطريق إليك'),
        TripStatus.driverArrived => shopping
            ? ('وصل السائق إلى المتجر', 'السائق يشتري طلبك الآن.')
            : ('السائق وصل', 'السائق بانتظارك في نقطة الانطلاق'),

        // **المرحلة الوسطى — للتسوّق وحده.** بها يعرف الراكب أن الشراء
        // تمّ وأنّ عليه أن يجهّز نقده. والرحلة العادية تبدأ والراكب على
        // الدراجة ينظر إلى السائق، فإشعارٌ حينها ضجيج.
        TripStatus.inProgress => shopping
            ? ('تمّ التسوّق', 'السائق في طريقه إليك')
            : null,
        TripStatus.completed => shopping
            ? ('وصل طلبك', 'وصل السائق إلى نقطة التسليم.')
            : ('انتهت رحلتك', 'قيّم سائقك — تقييمك يساعد غيرك.'),
        TripStatus.cancelled => byDriver
            ? (
                'أُلغيت الرحلة من قبل السائق',
                'اعتذر السائق. اطلب رحلة أخرى ويصلك سائقٌ آخر.',
              )
            : (
                'أُلغيت الرحلة',
                'يمكنك طلب رحلة أخرى الآن.',
              ),
        TripStatus.noDrivers => (
            'لا يوجد سائق متاح',
            'لم نجد سائقاً قريباً. جرّب بعد قليل أو ارفع الأجرة.',
          ),
        _ => null,
      };
}

final tripNotifierProvider = Provider<TripNotifier>(TripNotifier.new);
