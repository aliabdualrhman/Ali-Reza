import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';

/// تتبّع موقع السائق — **على مستوى التطبيق لا على مستوى شاشة**.
///
/// **العطل الذي وُلد من هذا:** كان التتبّع يعيش داخل `DriverHomeScreen`،
/// فيموت بموتها. وهي تموت في حالتين شائعتين جداً:
///
///   ١) الشاشة تُقفل أو التطبيق يُصغَّر — أندرويد يعلّق المؤقّتات وتدفّق
///      الموقع، فيتوقف الإرسال ويستبعد الخادم السائق بعد دقيقتين.
///   ٢) السائق ينتقل إلى شاشة العرض أو الرحلة — الشاشة الرئيسية تُتلَف
///      ومعها التتبّع، فيصير السائق "غير متصل" **وهو داخل رحلة**،
///      وخريطة الراكب تتجمّد عند آخر نقطة.
///
/// الحالة الثانية أخطر ولم تظهر لأن اختباراتنا كانت رحلات قصيرة أمام
/// الشاشة. والأولى نقضت الغرض من الإشعارات كلها: بنيناها ليعمل المنتج
/// والهاتف في الجيب، ثم كان الهاتف في الجيب يعني الانقطاع.
///
/// الحل: خدمة أمامية (foreground service) في أندرويد — إشعار دائم يبقى
/// معه التطبيق حيّاً والموقع يُرسل مهما كانت الشاشة المعروضة أو مطفأة.
/// الإشعار الدائم ليس إزعاجاً بل شرط النظام: أندرويد لا يسمح بتتبّع
/// خفيّ في الخلفية، وهو محقّ.
class LocationTracker extends Notifier<Position?> {
  StreamSubscription<Position>? _sub;
  Timer? _timer;
  DateTime? _lastPushAt;

  /// كل كم ثانية نرسل الموقع للخادم.
  ///
  /// موازنة: أقصر يعني تتبعاً أنعم للراكب واستهلاك بطارية وشبكة أعلى.
  /// خمس ثوانٍ تكفي لدراجة في المدينة، وتبقينا بعيداً عن حدّ الـ٩٠ ثانية
  /// الذي يستبعد بعده الخادمُ السائقَ.
  static const _pushInterval = Duration(seconds: 5);

  @override
  Position? build() {
    ref.onDispose(_teardown);
    return null;
  }

  bool get isRunning => _sub != null;

  /// إعدادات التدفّق. الخدمة الأمامية تُفعّل بمجرد تمرير إعداد الإشعار.
  LocationSettings _settings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        // لا نُخطر إلا بعد تحرّك ١٠ أمتار: السائق الواقف عند إشارة لا
        // يولّد عشرات التحديثات المتطابقة.
        distanceFilter: 10,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'زنبور — أنت متصل',
          notificationText: 'موقعك يُحدَّث لتصلك الطلبات',
          notificationChannelName: 'الاتصال أثناء العمل',
          // بدون قفل الاستيقاظ ينام النظام وتصل أحداث الموقع مجمّعة
          // بعد استيقاظه — أي أن السائق يبقى مستبعَداً طوال نومه.
          enableWakeLock: true,
          // دائم لا يُمسح: مسحه يوقف الخدمة ويقطع السائق بلا أن يدري.
          setOngoing: true,
        ),
      );
    }
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,

        // **بدونه يتوقف التتبّع لحظة خروج التطبيق من الشاشة.**
        // وهو الفرق بين سائق يعمل وسائق يظنّ أنه متصل: تُقفل الشاشة،
        // فيتجمّد موقعه، فيستبعده الخادم بعد تسعين ثانية، ويبقى
        // المفتاح أخضر ساعتين بلا طلب واحد.
        //
        // ولا يعمل إلا مع `UIBackgroundModes: location` في Info.plist
        // وإذن `Always` — وكلاهما مضبوط.
        allowBackgroundLocationUpdates: true,

        // **iOS يوقف التحديثات من تلقائه** حين يستنتج أن المستخدم
        // توقّف — وهو سلوك مصمَّم لتطبيقات الملاحة: وصلتَ فلا حاجة
        // للتتبّع. لكنّ سائقنا الواقف في الموقف **هو بالضبط من يجب
        // أن يبقى ظاهراً**، فتوقّفه يعني حرمانه من كل طلب.
        pauseLocationUpdatesAutomatically: false,

        // الشريط الأزرق أعلى الشاشة. **نُظهره عمداً** — آبل تتشدّد في
        // مراجعة التتبّع الخفي، وإظهاره يجعل السائق يرى متى يُجمع
        // موقعه ومتى يتوقف.
        showBackgroundLocationIndicator: true,

        // يمنع iOS من تقليل الدقة حين يظن أن التطبيق لا يحتاجها.
        activityType: ActivityType.automotiveNavigation,
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );
  }

  /// يبدأ التتبّع. يُستدعى عند الاتصال، وعند إقلاع التطبيق على سائق
  /// حالته `online` أصلاً (أُغلق التطبيق ولم يُقطع اتصاله).
  Future<void> start() {
    if (isRunning) return Future.value();
    // **طلبان متزامنان يبدآن تتبّعاً واحداً.** الإقلاع وإعادة الاتصال
    // والمفتاح قد يطلبون البدء في اللحظة نفسها؛ و`isRunning` لا يصير
    // صحيحاً إلا بعد القراءة الأولى — ثوانٍ يمرّ فيها الثاني فيفتح
    // تدفّقاً ثانياً يرسل الموقع مرتين إلى الأبد.
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void>? _starting;

  Future<void> _start() async {

    // نطلب الإذن عبر الخدمة المشتركة — نفس الرسائل العربية في التطبيقين.
    //
    // **ونحتفظ بالقراءة الأولى.** كانت تُرمى، فتبقى `state` فارغة حتى
    // ينطق التدفّق. والتدفّق مقيّد بـ `distanceFilter: 10` فلا يُصدر
    // شيئاً قبل أن يتحرّك السائق عشرة أمتار — وسائق واقف في بيته لا
    // يتحرّك. فينتج عن ذلك عطلان في آن:
    //
    //   ١) الخريطة تسقط إلى مركزها الاحتياطي (بغداد) والسائق في الناصرية.
    //   ٢) `_push` يعود فارغاً لأن `state == null`، فلا يصل الخادمَ أيّ
    //      موقع. والسائق يعلن اتصاله فيراه الخادم `online` بلا موقع
    //      محدَّث، فيستبعده من البحث — متصلٌ ولا تصله طلبات.
    //
    // إسناد القراءة الأولى يغلق البابين معاً قبل أن يبدأ التدفّق.
    state = await ref.read(geoServiceProvider).currentPosition();

    _sub = Geolocator.getPositionStream(locationSettings: _settings())
        .listen((p) {
      state = p;
      // نرسل من هنا أيضاً لا من المؤقّت وحده: أندرويد يخنق المؤقّتات في
      // وضع الخمول، وأحداث الموقع تصل رغم ذلك عبر الخدمة الأمامية.
      _pushIfDue();
    });

    // ونرسل بمؤقّت منتظم كذلك: السائق المتوقف عند إشارة لا يولّد أحداث
    // موقع إطلاقاً، وصمته دقيقتين يجعله "غير متصل" وهو واقف ينتظر طلباً.
    _timer?.cancel();
    _timer = Timer.periodic(_pushInterval, (_) => _push());
    await _push();
  }

  Future<void> stop() async {
    await _teardown();
    state = null;
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _lastPushAt = null;
  }

  void _pushIfDue() {
    final since = _lastPushAt;
    if (since != null && DateTime.now().difference(since) < _pushInterval) {
      return;
    }
    _push();
  }

  Future<void> _push() async {
    final p = state;
    if (p == null) return;
    _lastPushAt = DateTime.now();
    try {
      await ref.read(driverRepositoryProvider).pushLocation(
            lat: p.latitude,
            lng: p.longitude,
            heading: p.heading.isFinite ? p.heading.round() : null,
            speedKmh: p.speed.isFinite ? (p.speed * 3.6).round() : null,
          );
    } catch (e) {
      // فشل إرسال واحد لا يستحق إزعاج السائق — المحاولة التالية بعد ٥ ثوانٍ.
      // لو انقطع الاتصال طويلاً استبعده الخادم تلقائياً، وهو السلوك الصحيح.
      debugPrint('تعذّر إرسال الموقع: $e');
    }
  }
}

final locationTrackerProvider =
    NotifierProvider<LocationTracker, Position?>(LocationTracker.new);
