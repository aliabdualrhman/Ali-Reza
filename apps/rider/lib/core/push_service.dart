import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// معالج الرسائل حين يكون التطبيق **مغلقاً تماماً**.
///
/// **يجب أن يكون دالة عليا (top-level) موسومة بـ pragma:** أندرويد يشغّلها
/// في عزلة Dart منفصلة لا ترى حالة التطبيق ولا متغيراته. أي دالة داخل صنف
/// أو مغلقة (closure) تفشل صامتة — وهي أشيع خطأ في إعداد الإشعارات.
@pragma('vm:entry-point')
Future<void> _backgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

/// إشعارات الراكب.
///
/// **لماذا احتجناها؟** لم تكن موجودة إطلاقاً. الراكب يطلب رحلةً ثم يقفل
/// الشاشة لحظةً — وهو ما يفعله كل إنسان — فلا يعلم أن سائقاً قبِل، ولا
/// أنه وصل ويقف بالباب، ولا أن الطلب أُلغي.
///
/// **وأثقلها لحظة الوصول.** السائق واقفٌ في الشارع والراكب داخل البيت
/// ينتظر ولا يعلم؛ دقيقتان وينصرف، فيخسر الطرفان ونخسر نحن الاثنين.
class PushService {
  PushService(this._sb);

  final SupabaseClient _sb;

  static final _local = FlutterLocalNotificationsPlugin();

  /// **قناة واحدة لا قناتان.** قناة السائق (`trip_offers`) صوتها إلحاحي
  /// لأن العرض يموت بعد ثوانٍ. وحالة الراكب ليست كذلك — إشعارٌ بنبرة
  /// إنذار على «انتهت رحلتك» يُزعج بلا فائدة، وأول ما يفعله المستخدم
  /// حينها أن يُسكت القناة كلها فيفقد إشعار الوصول معها.
  /// **`trip_status_v2` لا `trip_status`.**
  ///
  /// قناةُ أندرويد لا تتغيّر بعد إنشائها — الصوت يُثبَّت أول مرة وكل
  /// تعديل بعده يُتجاهَل بصمت. فالمعرّف الجديد هو السبيل الوحيد لصوتٍ
  /// جديد على أجهزةٍ ثبّتت التطبيق قبل اليوم.
  static const _statusChannel = AndroidNotificationChannel(
    'trip_status_v2',
    'حالة الرحلة',
    description: 'قبول السائق، وصوله، وانتهاء الرحلة',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('notice'),
    enableVibration: true,
  );

  /// إشعارات الإدارة — نفس نغمة حالة الرحلة، فكلاهما خبرٌ لا نداء.
  static const _noticeChannel = AndroidNotificationChannel(
    'admin_notices',
    'إشعارات الإدارة',
    description: 'إعلانات وأخبار من زنبور',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('notice'),
    enableVibration: true,
  );

  /// **يكتمل حين تنتهي التهيئة — نجحت أو فشلت.**
  ///
  /// فايربيز لا يوجد إلا بعد `initialize`، وهذه تعمل بعد أول إطار. أما
  /// الشاشة الرئيسية فتُبنى فوراً وتسأل `diagnose` عن حال الإشعارات —
  /// فكان السؤال يسبق وجود فايربيز، فيرمي، فيُقرأ الإذن «مجهولاً» والرمز
  /// «غائباً»، ويظهر الشريط الأحمر عند **كل** إقلاع. ثم يضغط المستخدم
  /// «تطبيق» فيُعاد الفحص وقد اكتملت التهيئة، فيختفي — ويعود مع الإقلاع
  /// التالي. الإشعارات كانت تعمل؛ الفحص هو الذي كان يكذب.
  static final _ready = Completer<void>();

  Future<void> initialize({
    required void Function(Map<String, dynamic> data) onOpened,
  }) async {
    try {
      await _initialize(onOpened: onOpened);
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<void> _initialize({
    required void Function(Map<String, dynamic> data) onOpened,
  }) async {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);

    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),

        // **بدون هذا السطر لا يعمل أي إشعار محلي على iOS.**
        // `initialize` ينجح، و`show` لا يرمي خطأً، ولا يظهر شيء — فشلٌ
        // صامت لا يُكتشف إلا على جهاز آبل حقيقي.
        //
        // والأذونات هنا `false` عمداً: `firebase_messaging` يطلبها
        // بنفسه في `requestPermission` أدناه. وطلبان متتاليان يُظهران
        // للمستخدم حوارين، والثاني يُرفض تلقائياً لأن iOS لا يسأل
        // مرتين — فيبدو أنه رفض وهو لم يُسأل.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null) {
          onOpened(jsonDecode(r.payload!) as Map<String, dynamic>);
        }
      },
    );

    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_statusChannel);

    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_noticeChannel);

    // **المستمعون قبل طلب الإذن.** حوار النظام يتوقف حتى يردّ المستخدم؛
    // ولو سجّل دخوله بينما الحوار معلّق لضاع الحدث ولم يُحفظ الرمز — ولا
    // شيء يعيد المحاولة، لأن `onTokenRefresh` لا يُطلق حين يتغيّر
    // **المستخدم** ولا يتغيّر الرمز.
    FirebaseMessaging.instance.onTokenRefresh.listen(_saveToken);
    _sb.auth.onAuthStateChange.listen((s) {
      if (s.session != null) _syncToken();
    });

    // أندرويد ١٣ فما فوق يتطلب إذناً صريحاً. بدونه تُرسل الرسائل بنجاح
    // ولا تظهر شيئاً — فشل صامت يصعب تشخيصه.
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Firebase لا يعرض إشعاراً تلقائياً والتطبيق مفتوح — يمرّر الرسالة
    // فقط. نعرضها نحن.
    FirebaseMessaging.onMessage.listen((m) async {
      final n = m.notification;
      if (n == null) return;

      await _local.show(
        // **معرّف مشتق من الرحلة لا من الرسالة.** إشعارات الرحلة الواحدة
        // تتتابع — قُبل، وصل، انتهت — ومعرّفٌ ثابت يجعل كل واحد يحلّ
        // محلّ سابقه بدل أن يتكدّس ثلاثة عن رحلةٍ واحدة.
        id: _notificationId(m),
        title: n.title,
        body: n.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _statusChannel.id,
            _statusChannel.name,
            channelDescription: _statusChannel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
          // iOS لا يعرف القنوات — الأولوية والصوت يُضبطان لكل إشعار.
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            // **الاسم بامتداده.** iOS لا يعرف القنوات، فيُذكر الصوت في
            // كل إشعار — والملف في حزمة التطبيق لا في أصول فلاتر.
            sound: 'notice.wav',
          ),
        ),
        payload: jsonEncode(m.data),
      );
    });

    FirebaseMessaging.onMessageOpenedApp.listen((m) => onOpened(m.data));

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) onOpened(initial.data);

    // على iOS: عرض الإشعار في المقدّمة حتى لو مرّ عبر FCM مباشرة
    // (بجانب عرضنا المحلي عبر flutter_local_notifications).
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    await _syncToken();
    // APNs قد يتأخّر بعد الإقلاع — إعادة محاولة صامتة بعد ثوانٍ.
    unawaited(_retrySyncTokenLater());
  }

  /// إعادة مزامنة الرمز بعد تأخير — إن فشلت المحاولة الأولى على iOS.
  Future<void> _retrySyncTokenLater() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    await Future<void>.delayed(const Duration(seconds: 3));
    await _syncToken();
    await Future<void>.delayed(const Duration(seconds: 8));
    await _syncToken();
  }

  /// إشعارات الرحلة الواحدة تتبادل المكان بدل أن تتكدّس.
  static int _notificationId(RemoteMessage m) {
    final id = m.data['trip_id'];
    if (id != null) return id.hashCode & 0x7fffffff;
    return DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
  }

  Future<void> _syncToken() async {
    try {
      // **على iOS: انتظر رمز APNs قبل `getToken`.** بدونه ترمي
      // `apns-token-not-set` — وكان الخطأ يُبتلَع هنا مرةً واحدة ولا
      // يُعاد إلا عند تغيّر الجلسة، فيبقى الجهاز أصمّ بعد الإقلاع.
      await _waitForApnsToken();
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _saveToken(token);
    } catch (e) {
      // أندرويد بلا خدمات Google، أو آيفون بلا رمز APNs بعد.
      // الشاشة تتابع الحالة لحظياً ما دامت مفتوحة.
      debugPrint('تعذّر الحصول على رمز الإشعارات: $e');
    }
  }

  /// ينتظر رمز APNs على آيفون قبل طلب رمز FCM.
  ///
  /// آبل قد تتأخّر ثوانٍ بعد `registerForRemoteNotifications`. وبدون
  /// الانتظار يفشل `getToken` مرةً ويُبتلَع الخطأ، ولا يصل إشعار.
  static Future<void> _waitForApnsToken() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    // حتى ~12 ثانية — شبكة بطيئة أو إقلاع أول بعد التثبيت يحتاج وقتاً.
    for (var i = 0; i < 48; i++) {
      final apns = await FirebaseMessaging.instance.getAPNSToken();
      if (apns != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// يسجّل هذا الجهاز في `user_devices` (0048) — لا في عمود واحد.
  ///
  /// العمود الواحد كان يعني رمزاً واحداً لكل حساب: من يدخل على جهاز ثانٍ
  /// يدوس على رمز الأول فيصير الأول أعمى بلا أن يعلم.
  Future<void> _saveToken(String token) async {
    if (_sb.auth.currentUser == null) return;
    try {
      await _sb.rpc('register_device',
          params: {'p_token': token, // للإحصاء وحده — لا شيء يرشّح به؛ لكنه كان يقول «android» لكل آيفون.
          'p_platform':
              defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android'});
    } catch (e) {
      debugPrint('تعذّر تسجيل الجهاز: $e');
    }
  }


  /// يعرض إشعاراً **من داخل التطبيق** بلا مرور بفايربيز.
  ///
  /// **الحاجة إليه ليست نظرية.** أجهزة كثيرة في سوقنا لا تولّد رمز FCM
  /// أصلاً — نسخٌ بلا خدمات Google، أو خدماتٌ قديمة، أو شبكةٌ تحجب
  /// خوادم جوجل. يظهر العطل هكذا في السجلّ:
  ///
  ///     java.io.IOException: SERVICE_NOT_AVAILABLE. Won't retry.
  ///
  /// وحينها لا يملك الخادم رمزاً يرسل إليه، فلا يصل الراكب شيءٌ مهما
  /// كانت أذوناته صحيحة. وقد رصدناه على جهاز المطوّر نفسه.
  ///
  /// **وحدّه الذي لا يتجاوزه:** يعمل ما دامت عملية التطبيق حيّة — على
  /// الشاشة أو خلفها. فإن قتلها النظام لم يبقَ إلا FCM. فهو طبقةٌ
  /// ثانية لا بديل.
  static Future<void> showLocal({
    required int id,
    required String title,
    required String body,
    Map<String, dynamic>? payload,
  }) async {
    try {
      await _local.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _statusChannel.id,
            _statusChannel.name,
            channelDescription: _statusChannel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
          // iOS لا يعرف القنوات — الأولوية والصوت يُضبطان لكل إشعار.
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            sound: 'notice.wav',
          ),
        ),
        payload: payload == null ? null : jsonEncode(payload),
      );
    } catch (e) {
      debugPrint('تعذّر عرض الإشعار المحلي: $e');
    }
  }

  /// حالة الإشعارات كما يراها الجهاز والقاعدة — لشاشة «فحص الإشعارات».
  ///
  /// **لماذا شاشة داخل التطبيق؟** لأن كل حلقة هنا تفشل صامتة: إذنٌ
  /// مرفوض، ورمزٌ لم يُولَّد، ورمزٌ لم يصل القاعدة. ثلاثة أعطال مختلفة
  /// عرضها واحد — «لا يصل إشعار» — وتمييزها بالتخمين يضيّع ساعات،
  /// خاصةً مع مختبِر لا يعرف أين إعدادات هاتفه.
  Future<RiderPushStatus> diagnose() async {
    // ننتظر التهيئة؛ ولا ننتظر إلى الأبد — حوار الإذن قد يبقى معلّقاً،
    // والفحص يُعاد على أي حال حين يعود المستخدم إلى التطبيق.
    await _ready.future
        .timeout(const Duration(seconds: 20), onTimeout: () {});

    bool? granted;
    String? token;
    bool registered = false;
    String? error;

    try {
      final s = await FirebaseMessaging.instance.getNotificationSettings();
      granted = s.authorizationStatus == AuthorizationStatus.authorized;
    } catch (e) {
      error = 'تعذّر قراءة الإذن: $e';
    }

    try {
      await _waitForApnsToken();
      token = await FirebaseMessaging.instance.getToken();
    } catch (e) {
      // **لا نُخفيه خلف رسالة عامة.** على أندرويد `SERVICE_NOT_AVAILABLE`
      // يعني خدمات Google؛ وعلى آيفون `apns-token-not-set` يعني أن
      // تسجيل APNs لم يكتمل — مكانان مختلفان للبحث.
      error = '$e';
    }

    if (token != null && _sb.auth.currentUser != null) {
      try {
        final row = await _sb
            .from('user_devices')
            .select('token')
            .eq('token', token)
            .maybeSingle();
        registered = row != null;
      } catch (e) {
        error ??= 'تعذّر قراءة تسجيل الجهاز: $e';
      }
    }

    return RiderPushStatus(
      permissionGranted: granted,
      hasToken: token != null,
      registered: registered,
      error: error,
    );
  }

  /// يعيد تسجيل الجهاز. يستدعيه زر «إعادة المحاولة».
  Future<void> resync() => _syncToken();

  /// يمسح رمز **هذا الجهاز وحده** عند الخروج.
  Future<void> clearToken() async {
    if (_sb.auth.currentUser == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _sb.rpc('unregister_device', params: {'p_token': token});
      }
      await _local.cancelAll();
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {
      // الخروج لا يجب أن يفشل بسبب هذا
    }
  }
}

/// نتيجة فحص الإشعارات كما تُعرض للمستخدم.
class RiderPushStatus {
  const RiderPushStatus({
    required this.permissionGranted,
    required this.hasToken,
    required this.registered,
    this.error,
  });

  final bool? permissionGranted;
  final bool hasToken;
  final bool registered;
  final String? error;

  /// **الجهاز صالح لاستقبال الإشعارات البعيدة؟** الثلاثة معاً أو لا شيء.
  bool get healthy => permissionGranted == true && hasToken && registered;
}
