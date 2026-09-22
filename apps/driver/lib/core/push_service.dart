import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// معالج الرسائل حين يكون التطبيق **مغلقاً تماماً**.
///
/// **يجب أن يكون دالة عليا (top-level) موسومة بـ pragma:** أندرويد يشغّلها
/// في عزلة Dart منفصلة لا ترى حالة التطبيق ولا متغيراته. أي دالة داخل صنف
/// أو مغلقة (closure) تفشل صامتة — وهي أشيع خطأ في إعداد الإشعارات.
@pragma('vm:entry-point')
Future<void> _backgroundHandler(RemoteMessage message) async {
  // لا نفعل شيئاً هنا سوى ضمان تشغيل Firebase في العزلة.
  // أندرويد يعرض الإشعار بنفسه من حمولة `notification`.
  await Firebase.initializeApp();
}

/// إشعارات السائق.
///
/// **لماذا هي ضرورية لا تحسينية؟** بدونها يجب أن يبقى التطبيق مفتوحاً على
/// الشاشة ليصل العرض. والسائق الحقيقي يضع هاتفه في جيبه أو على المقود
/// بشاشة مطفأة — فلا تصله رحلة واحدة، ولا يعمل المنتج مهما أتقنّا بقيته.
class PushService {
  PushService(this._sb);

  final SupabaseClient _sb;

  static final _local = FlutterLocalNotificationsPlugin();

  /// انتظار · اهتزاز · صمت · اهتزاز — يُحسّ من الجيب على دراجةٍ تهتزّ.
  static final _offerVibration =
      Int64List.fromList([0, 500, 250, 500]);

  /// قناة عالية الأولوية لعروض الرحلات.
  ///
  /// أندرويد ٨ فما فوق يتجاهل أي إشعار بلا قناة مُعرّفة. والأولوية العالية
  /// ضرورية هنا: العرض صالح دقيقة أو أقل، وإشعار صامت في شريط الحالة
  /// يضيع الفرصة.
  /// **`trip_offers_v2` لا `trip_offers`.**
  ///
  /// قناةُ أندرويد **لا تتغيّر بعد إنشائها**: الصوت والأولوية والاهتزاز
  /// تُثبَّت أول مرة، وكل تعديل بعدها يُتجاهَل بصمت. فمن ثبّت التطبيق
  /// قبل اليوم يبقى على النغمة الافتراضية مهما غيّرنا الكود.
  ///
  /// والسبيل الوحيد معرّفٌ جديد. والقديمة تبقى في إعدادات الهاتف فارغة
  /// حتى يُزال التطبيق — وهو ثمنٌ مقبول لصوتٍ يسمعه السائق في الشارع.
  static final _offerChannel = AndroidNotificationChannel(
    'trip_offers_v2',
    'عروض الرحلات',
    description: 'إشعار فوري عند وصول طلب رحلة جديد',
    importance: Importance.max,
    playSound: true,
    // ثلاث نبضات صاعدة تتكرر — صاعدةٌ لأنها تُقرأ «انتبه»، ومتكرّرةٌ
    // لتقطع ضجيج الشارع ومحرّك الدراجة.
    sound: RawResourceAndroidNotificationSound('offer'),
    enableVibration: true,
    // نبضٌ طويلٌ مزدوج يُحسّ من الجيب على دراجةٍ تهتزّ أصلاً.
    vibrationPattern: _offerVibration,
  );

  /// إشعارات الإدارة — نغمة أهدأ لا تُشبه العرض.
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

    // ---- الإشعارات المحلية: نعرض بها الرسائل الواصلة والتطبيق مفتوح ----
    await _local.initialize(
      // الإصدار ٢٢ حوّل هذه المعاملات من موضعية إلى مُسمّاة
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
        ?.createNotificationChannel(_offerChannel);

    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_noticeChannel);

    // ---- مستمعو الرمز، قبل أي انتظار ----
    //
    // **ترتيب مقصود:** `requestPermission` يعرض حوار النظام ويتوقف حتى
    // يردّ المستخدم. لو سجّلنا المستمعين بعده، وسجّل السائق دخوله بينما
    // الحوار معلّق، ضاع حدث الدخول ولم يُحفظ الرمز — ولا شيء يعيد
    // المحاولة، لأن `onTokenRefresh` لا يُطلق حين يتغيّر **المستخدم**
    // ولا يتغيّر الرمز.
    FirebaseMessaging.instance.onTokenRefresh.listen(_saveToken);
    _sb.auth.onAuthStateChange.listen((s) {
      if (s.session != null) _syncToken();
    });

    // ---- الإذن ----
    // أندرويد ١٣ فما فوق يتطلب إذناً صريحاً للإشعارات. بدونه تُرسل
    // الرسائل بنجاح ولا تظهر شيئاً — فشل صامت يصعب تشخيصه.
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // ---- الرسائل والتطبيق مفتوح ----
    // Firebase لا يعرض إشعاراً تلقائياً في هذه الحالة — يمرّر الرسالة
    // للتطبيق فقط. نعرضها نحن بالإشعارات المحلية.
    FirebaseMessaging.onMessage.listen((m) async {
      final n = m.notification;
      if (n == null) return;

      await _local.show(
        // **معرّف مشتق من العرض لا من الرسالة.** كان `m.hashCode`، وهو
        // يتكرر بين رسالتين متشابهتين — فيستبدل الإشعارُ الجديد القديمَ
        // بدل أن يُضاف إليه. مع البثّ المتوازي وخمسة عروض قد تصل معاً،
        // كان السائق يرى واحداً منها فقط.
        id: _notificationId(m),
        title: n.title,
        body: n.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _offerChannel.id,
            _offerChannel.name,
            channelDescription: _offerChannel.description,
            importance: Importance.max,
            priority: Priority.high,
            // يختفي مع انتهاء العرض بالضبط.
            //
            // **كان ٢٠ ثانية ثابتة** بينما صارت المهلة ٤٥ في 0018، فكان
            // الإشعار يختفي والعرض ما زال حيّاً — وهو ما جعل السائق يقول
            // "أحياناً لا يظهر إشعار". نقرأ `expires_at` من الحمولة
            // نفسها فلا يتكرر انفصال الرقمين مهما تغيّرت المهلة.
            timeoutAfter: _msUntilExpiry(m.data),
          ),
          // iOS لا يعرف القنوات — الأولوية والصوت يُضبطان لكل إشعار.
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            // **الاسم بامتداده.** iOS لا يعرف القنوات، فيُذكر الصوت في
            // كل إشعار — والملف في حزمة التطبيق لا في أصول فلاتر.
            sound: 'offer.wav',
          ),
        ),
        payload: jsonEncode(m.data),
      );
    });

    // ---- فتح التطبيق من إشعار ----
    FirebaseMessaging.onMessageOpenedApp.listen((m) => onOpened(m.data));

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) onOpened(initial.data);

    // ---- تسجيل الرمز الآن إن كانت هناك جلسة ----
    //
    // **العطل الذي أصلحناه هنا:** كنا نزامن الرمز مرة واحدة عند إقلاع
    // التطبيق. وبعد تثبيت جديد يقلع التطبيق على **شاشة الدخول** بلا
    // جلسة، فيخرج `_saveToken` صامتاً لأن `currentUser` فارغ — ثم يسجّل
    // السائق دخوله ولا شيء يعيد المحاولة.
    //
    // النتيجة: `profiles.fcm_token` يحمل رمز التثبيت السابق الميت،
    // وفايربيز ترد `404 NotRegistered`، ولا يصل إشعار واحد أبداً.
    await _syncToken();
  }

  // ---------------------------------------------------------------------------
  // التشخيص
  // ---------------------------------------------------------------------------

  /// حالة الإشعارات كما يراها الجهاز والقاعدة معاً.
  ///
  /// **لماذا نبنيه في التطبيق؟** لأن كل حلقة في هذه السلسلة تفشل صامتة:
  /// إذن مرفوض، ورمز لم يُولَّد، ورمز في الجهاز لا يطابق ما في القاعدة.
  /// ثلاثة أعطال مختلفة عرضها واحد — "لا يصل إشعار" — وتمييزها بالتخمين
  /// يضيّع ساعات.
  Future<PushDiagnostics> diagnose() async {
    // ننتظر التهيئة؛ ولا ننتظر إلى الأبد — حوار الإذن قد يبقى معلّقاً،
    // والفحص يُعاد على أي حال حين يعود المستخدم إلى التطبيق.
    await _ready.future
        .timeout(const Duration(seconds: 20), onTimeout: () {});

    String? error;
    bool? authorized;
    String? device;
    String? stored;

    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      authorized =
          settings.authorizationStatus == AuthorizationStatus.authorized;
    } catch (e) {
      error = 'تعذّر قراءة إذن الإشعارات: $e';
    }

    try {
      device = await FirebaseMessaging.instance.getToken();
    } catch (e) {
      error = 'تعذّر توليد رمز الجهاز: $e';
    }

    final uid = _sb.auth.currentUser?.id;
    if (uid != null && device != null) {
      // **نسأل: هل رمز هذا الجهاز مسجَّل؟** لا: ما الرمز المخزَّن؟
      //
      // السؤال الثاني كان يُنتج «الخادم يرسل إلى جهاز قديم» على كل جهاز
      // عدا آخر واحد دخل — وهو إنذار كاذب بعد 0048، إذ صار الخادم يبثّ
      // إلى الجميع.
      try {
        final row = await _sb
            .from('user_devices')
            .select('token')
            .eq('token', device)
            .maybeSingle();
        stored = row?['token'] as String?;
      } catch (e) {
        error = 'تعذّر قراءة تسجيل الجهاز: $e';
      }
    }

    // فحص التجميد. **لا نُفشل التشخيص كله إن تعذّر** — القياس الفاشل
    // ليس عطلاً، ورفعُ خطأ هنا يخفي أعطال الإشعارات الحقيقية.
    //
    // **و`null` على iOS لا `false`.** لا وجود لتحسين البطارية هناك
    // أصلاً، و`permission_handler` يردّ «مرفوض» عن إذنٍ لا يعرفه —
    // فيقرؤه التطبيق عطلاً دائماً: بطاقةٌ حمراء تقول «نظام هاتفك يوقف
    // التطبيق في الخلفية» على كل آيفون، وخطوةٌ في الورقة لا تكتمل مهما
    // ضغطها السائق، لأن زرّها يفتح إعداداً غير موجود.
    bool? battery;
    if (Platform.isAndroid) {
      try {
        battery = await Permission.ignoreBatteryOptimizations.isGranted;
      } catch (_) {
        battery = null;
      }
    }

    return PushDiagnostics(
      permissionGranted: authorized,
      deviceToken: device,
      storedToken: stored,
      signedIn: uid != null,
      batteryUnrestricted: battery,
      error: error,
    );
  }

  /// يعيد كتابة رمز الجهاز في القاعدة. يستدعيه زر "إعادة المزامنة".
  Future<void> resync() => _syncToken();

  /// معرّف ثابت لكل عرض ومختلف بين العروض.
  ///
  /// نشتقّه من `offer_id` في الحمولة. وإن غاب نرجع إلى وقت الوصول —
  /// لا يتكرر عملياً، وأسوأ حالاته إشعار زائد لا إشعار مفقود.
  static int _notificationId(RemoteMessage m) {
    final id = m.data['offer_id'] ?? m.data['id'];
    if (id != null) return id.hashCode & 0x7fffffff;
    return DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
  }

  /// كم يبقى للعرض بالمللي ثانية، محسوباً من الحمولة.
  static int _msUntilExpiry(Map<String, dynamic> data) {
    final expires = DateTime.tryParse('${data['expires_at']}');
    if (expires != null) {
      final ms = expires.difference(DateTime.now().toUtc()).inMilliseconds;
      // هامش ثانيتين: ساعة الهاتف وساعة الخادم لا تتطابقان تماماً.
      if (ms > 2000) return ms + 2000;
    }
    return 60000;   // لا حمولة صالحة — دقيقة تغطي أطول مهلة معقولة
  }

  Future<void> _syncToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _saveToken(token);
    } catch (e) {
      // فشل الحصول على الرمز لا يمنع عمل التطبيق — السائق سيرى العروض
      // ما دام التطبيق مفتوحاً. نسجّل ولا نُسقط.
      debugPrint('تعذّر الحصول على رمز الإشعارات: $e');
    }
  }

  /// يسجّل هذا الجهاز في `user_devices` ليبثّ إليه الخادم.
  ///
  /// **صار جدولاً بعد أن كان عموداً** (0048). العمود الواحد كان يعني
  /// رمزاً واحداً لكل حساب: من يدخل على جهاز ثانٍ يدوس على رمز الأول،
  /// فيصير الأول أعمى وشاشة التشخيص عنده تقول «الخادم يرسل إلى جهاز
  /// قديم». والدالة تُبقي العمود محدَّثاً أيضاً لنسخٍ لم تُحدَّث بعد.
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

  /// يُلغي إشعار عرضٍ لم يعد قائماً.
  ///
  /// **كان لا يُلغى أبداً.** يُعرض ويُترك: قبله السائق فبقي يرنّ، انتهت
  /// مهلته فبقي، سبقه سائق آخر فبقي. ومع البثّ المتوازي وخمسة عروض
  /// تصل معاً، صار الهاتف يرنّ بلا انقطاع لطلبات ماتت كلها — وهو ما
  /// وصفه السائقون بـ«المنبّه المزعج».
  ///
  /// `timeoutAfter` وحده لا يكفي: طبقات المصنّعين (HyperOS وأخواتها)
  /// لا تحترمه بانتظام.
  Future<void> cancelOffer(String offerId) async {
    try {
      await _local.cancel(id: offerId.hashCode & 0x7fffffff);
    } catch (_) {
      // إلغاء إشعار غير موجود ليس خطأً يستحق إسقاط شيء.
    }
  }

  /// يُسكت كل إشعارات العروض دفعةً — عند دخول رحلة أو قطع الاتصال.
  Future<void> cancelAllOffers() async {
    try {
      await _local.cancelAll();
    } catch (_) {}
  }

  /// يمسح رمز **هذا الجهاز وحده** عند الخروج.
  ///
  /// **لا كل أجهزة الحساب.** كان الخروج يُفرغ العمود فيقطع الإشعارات
  /// عن كل هواتف السائق — فمن خرج من جهازه الثاني فقد عروضه على الأول
  /// بلا سبب يفهمه.
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


/// نتيجة فحص سلسلة الإشعارات وجاهزية العمل.
class PushDiagnostics {
  const PushDiagnostics({
    required this.permissionGranted,
    required this.deviceToken,
    required this.storedToken,
    required this.signedIn,
    this.batteryUnrestricted,
    this.error,
  });

  final bool? permissionGranted;
  final String? deviceToken;
  final String? storedToken;
  final bool signedIn;

  /// هل التطبيق مستثنى من تحسين البطارية؟
  ///
  /// **أخطر بند في هذه القائمة، وأخفاها.** الإشعارات المعطّلة تُنتج
  /// صمتاً مفهوماً؛ أما التجميد فيُنتج تطبيقاً يبدو شغّالاً ولا يعمل:
  /// أندرويد يعلّق طلبات الشبكة، فيدور زر القبول بلا نهاية، ولا يستجيب
  /// «وصلت إلى الراكب»، ويتوقف إرسال الموقع فيستبعده الخادم بعد دقيقتين.
  ///
  /// **والخدمة الأمامية لا تكفي.** رصدناه على شاومي والخدمة الأمامية
  /// تعمل بنوع `location`: النظام جمّد التطبيق على أي حال. مُصنّعو
  /// الأجهزة في المنطقة (شاومي، أوبو، فيفو، هواوي) يضيفون طبقة توفير
  /// طاقة فوق أندرويد لا تحترم الخدمات الأمامية ما لم يستثنِ المستخدم
  /// التطبيق بيده.
  ///
  /// `null` = تعذّر الفحص. لا نعدّه عطلاً: القياس الفاشل ليس عطلاً.
  final bool? batteryUnrestricted;

  final String? error;

  /// الرمز في الجهاز يطابق المخزّن في القاعدة.
  ///
  /// **عدم التطابق أخطر من الغياب**، لأنه يبدو سليماً: القاعدة تحمل رمزاً،
  /// وفايربيز ترسل إليه، وهو رمز جهازٍ لم يعد موجوداً.
  bool get tokenMatches =>
      deviceToken != null && storedToken != null && deviceToken == storedToken;

  /// نعتبره سليماً ما لم يثبت العكس — `null` تعني تعذّر الفحص لا وجود عطل.
  bool get batteryOk => batteryUnrestricted != false;

  bool get healthy =>
      signedIn &&
      permissionGranted == true &&
      tokenMatches &&
      batteryOk &&
      error == null;
}
