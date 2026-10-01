import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'app_router.dart';
import 'core/push_service.dart';
import 'features/auth/auth_repository.dart';
import 'features/driver/driver_repository.dart';
import 'features/driver/earnings_card.dart' show earningsProvider;
import 'features/driver/incentives_screen.dart' show myIncentivesProvider;
import 'features/driver/store_dues_screen.dart'
    show storeDuesProvider, orderBlocksProvider;
import 'features/driver/location_tracker.dart';

/// سبب فشل الإقلاع إن وُجد — يُعرض للمستخدم بدل شاشة سوداء صامتة.
String? bootError;

Future<void> main() async {
  // مطلوب قبل أي عمل غير متزامن يسبق runApp، وإلا انهار التطبيق عند الإقلاع.
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: '.env');

    // تحميل بيانات التقويم العربي — بدونها يفشل DateFormat('...', 'ar')
    // في شاشة التسجيل بخطأ LocaleDataException.
    await initializeDateFormatting('ar');

    final url = dotenv.env['SUPABASE_URL'] ?? '';
    final key = dotenv.env['SUPABASE_ANON_KEY'] ?? '';

    if (url.isEmpty || key.isEmpty || url.contains('xxxx')) {
      bootError = 'ملف .env غير مكتمل — راجع .env.example';
    } else {
      // publishableKey لا anonKey: Supabase غيّرت صيغة مفاتيحها
      // (sb_publishable_...) وهجرت التسمية القديمة.
      await Supabase.initialize(url: url, publishableKey: key);

      // **مفتاح الخرائط من اللوحة لا من البناء** (0119). لا ننتظره:
      // لو تأخّرت الشبكة يقلع التطبيق بمفتاح البناء، وتصل القيمة
      // الجديدة عند أوّل شاشةٍ تقرأ الإعدادات.
      // **مفتاح الخرائط من .env قبل اللوحة.** كان لا يُقرأ إلا من
      // `--dart-define`، فمن بنى بلا الراية خرج بخرائط تنتظر اللوحة.
      // والقيمة في .env أصلاً؛ فتُتبنّى هنا، ثم تعلوها قيمةُ اللوحة
      // إن وصلت — فيبقى تغيير المفتاح من اللوحة بلا بناء.
      MapEndpoints.adopt(key: dotenv.env['GEOAPIFY_KEY']);
      // **المسجَّل لا ينتظر الشبكة قبل أول شاشة.** كان الإقلاع يقف هنا
      // على ردّ الخادم — حتى أربع ثوانٍ على شبكةٍ بطيئة — في كلّ فتحة.
      // ومفتاح الخرائط في يده من .env، ومفتاح البريد لا يلزمه إلا في
      // شاشة الدخول. فيصل الردّ وهو يرى رئيسيته.
      //
      // **ومن لا جلسة له ينتظر — قليلاً.** شاشته الأولى الدخول، وهي تقرأ
      // مفتاح البريد لتعرف أتطلب الرقم وحده أم البريد معه.
      final signedIn = Supabase.instance.client.auth.currentSession != null;
      final boot = loadMapConfig(
        Supabase.instance.client,
        timeout: Duration(seconds: signedIn ? 4 : 2),
      );
      if (!signedIn) await boot;
    }
  } catch (e) {
    final msg = e.toString();
    // غالباً .env داخل الـ IPA بترميز UTF-16 أو base64 فاسد من Codemagic.
    if (msg.contains('FormatException') || msg.contains('Unexpected extension')) {
      bootError =
          'ملف الإعدادات تالف (ترميز خاطئ).\nحدّث RIDER/DRIVER_ENV_B64 في Codemagic من prepare-codemagic.ps1 ثم أعد البناء.';
    } else {
      bootError = msg;
    }
  }

  runApp(const ProviderScope(child: ZanbourApp()));
}

/// نهيّئ الإشعارات داخل الودجة لا في main: تحتاج عميل Supabase الذي
/// يُنشأ في ProviderScope، وتحتاج موجّهاً لتنقل عند فتح الإشعار.
class ZanbourApp extends ConsumerStatefulWidget {
  const ZanbourApp({super.key});

  @override
  ConsumerState<ZanbourApp> createState() => _ZanbourAppState();
}

class _ZanbourAppState extends ConsumerState<ZanbourApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initPush());

    // **عند كل عودة من الخلفية: جلبٌ جديد لا ثقةٌ بالمقبس.** شاومي
    // وأخواتها تجمّد التطبيق فيموت اتصاله اللحظي صامتاً، ويبقى في الذاكرة
    // آخر ما وصل قبل التجميد. فإعادة الإنشاء تجلب الحالة الحقيقية من
    // الخادم، ومستمع السجلّ في `build` يقرّر بعدها.
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.invalidate(driverRecordProvider),
    );
  }

  AppLifecycleListener? _lifecycle;

  /// **المفتاح مفعّل والحالة «غير متصل» — نعيد الاتصال.**
  ///
  /// الخادم يُخرج السائق من الشبكة بعد دقيقتين بلا موقع: تطبيقٌ أُغلق،
  /// أو هاتفٌ جمّده النظام. والمفتاحان يبقيان كما هما — فيفتح السائق
  /// التطبيق فيرى مفتاحين أخضرين وتحتهما «غير متصل».
  ///
  /// **كان هذا في الشاشة الرئيسية، ولم يعمل.** يعمل هناك إن كانت هي
  /// المفتوحة ساعة الفتح أو العودة، وإن جاءت الحالة الحقيقية وهي حيّة
  /// — وكلا الشرطين يسقط كثيراً. هنا يعمل على أيّ شاشة، كلما تغيّر
  /// السجلّ.
  ///
  /// المفتاحان نيّة السائق والحالة أثرٌ تقنيّ؛ فحين يختلفان نتبع النيّة.
  bool _reconnecting = false;

  /// **المحاولة الأولى تفشل عادةً، لا استثناءً.**
  ///
  /// أول ما يفعله التتبّع قراءةُ موقعٍ حيّ بمهلة عشرين ثانية. والسائق
  /// يفتح تطبيقه في بيته أو تحت سقف، وجهاز GPS نائمٌ منذ أُغلق التطبيق
  /// — فأول قراءةٍ بعد الإقلاع تتجاوز المهلة كثيراً. فكانت المحاولة
  /// الواحدة تسقط، ولا تُعاد، فيرى السائق مفاتيحه خضراء وتحتها «غير
  /// متصل» حتى يطفئ مفتاحاً ويشعله بيده.
  ///
  /// **ولماذا ينجح بيده؟** لأن محاولتنا الفاشلة أيقظت GPS، فالقراءة
  /// الثانية تأتي في ثوانٍ. فالعلّة ليست في الإذن ولا في الحساب، بل في
  /// أننا سألنا مرة واحدة في أسوأ لحظة.
  ///
  /// فنُعيد ثلاث مرات، بفاصلٍ يتسع. أما ما لا يُصلحه التكرار — إذنٌ
  /// مرفوض، أو خدمة موقعٍ مطفأة، أو رفضٌ من الخادم كرصيدٍ دون الحدّ —
  /// فنتوقف عنده فوراً: السائق يراه مكتوباً حين يضغط المفتاح بنفسه.
  static const _retryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      for (var attempt = 0;; attempt++) {
        try {
          // التتبّع قبل الإعلان: `online` بلا موقعٍ حديث يُستبعد من البحث.
          await ref.read(locationTrackerProvider.notifier).start();
          await ref.read(driverRepositoryProvider).setOnline(true);
          await WakelockPlus.enable();
          debugPrint('أُعيد الاتصال تلقائياً (محاولة ${attempt + 1})');
          return;
        } on GeoException catch (e) {
          // إذنٌ أو خدمةُ موقع: قرارٌ بيد السائق، والتكرار لا يغيّره.
          debugPrint('تعذّرت إعادة الاتصال — الموقع: ${e.message}');
          await ref.read(locationTrackerProvider.notifier).stop();
          return;
        } on PostgrestException catch (e) {
          // رفضٌ من الخادم: وثائق لم تُعتمد، أو رصيدٌ دون الحدّ.
          debugPrint('تعذّرت إعادة الاتصال — الخادم: ${e.message}');
          await ref.read(locationTrackerProvider.notifier).stop();
          return;
        } catch (e) {
          // التتبّع بدأ قبل الرفض؛ لا يبقى يعمل وسائقه خارج الشبكة.
          await ref.read(locationTrackerProvider.notifier).stop();
          if (attempt >= _retryDelays.length) {
            debugPrint('تعذّرت إعادة الاتصال التلقائي نهائياً: $e');
            return;
          }
          debugPrint('تعذّرت إعادة الاتصال (محاولة ${attempt + 1}): $e');
          await Future<void>.delayed(_retryDelays[attempt]);
          // الجلسة قد تنتهي أثناء الانتظار — لا نُعلن اتصال من خرج.
          if (!mounted || ref.read(sessionProvider) == null) return;
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  /// يُبقي إشعارات العروض مطابقةً للعروض القائمة فعلاً.
  ///
  /// **العطل الذي يعالجه:** الإشعار كان يُعرض ولا يُلغى أبداً. قبِل
  /// السائق الطلب فبقي يرنّ؛ انتهت مهلته فبقي؛ سبقه سائق آخر فبقي. ومع
  /// البثّ المتوازي وخمسة عروض تصل معاً، صار الهاتف يرنّ لطلبات ماتت
  /// كلها — «المنبّه المزعج» الذي شكا منه السائقون.
  ///
  /// نستمع لقائمة العروض: كل عرضٍ اختفى منها يُلغى إشعاره.
  ProviderSubscription<AsyncValue<List<Map<String, dynamic>>>>? _offerWatch;

  void _watchOffers(PushService push) {
    var known = <String>{};
    _offerWatch = ref.listenManual(pendingOffersProvider, (_, next) {
      final now = {...?next.value?.map((o) => '${o['id']}')};
      for (final gone in known.difference(now)) {
        push.cancelOffer(gone);
      }
      known = now;
    });
  }

  @override
  void dispose() {
    _offerWatch?.close();
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _initPush() async {
    try {
      final push = PushService(ref.read(supabaseProvider));
      _watchOffers(push);
      await push.initialize(
        onOpened: (data) {
          debugPrint('فُتح إشعار: $data');
          // **الإعلان ليس عرضاً.** كلّ إشعارٍ كان يُعامَل كعرض رحلة: يُبحث
          // عن عرضٍ معلّق فلا يوجد، فيُقال للسائق «انتهت مهلة هذا الطلب
          // وانتقل إلى سائق آخر» — عن إعلان حافزٍ لم يكن طلباً أصلاً.
          // والنوع في بيانات الإشعار نفسه (`admin_notice` من
          // notify-broadcast، و`trip_offer` من notify-driver).
          if (data['type'] == 'admin_notice') {
            _openNotice(data);
            return;
          }
          // الإشعار يحمل معرّف الرحلة؛ نترك الموجّه يقرر الوجهة من
          // حالة السائق بدل التنقّل الأعمى — قد يكون العرض انتهى.
          _refreshAfterNotification();
        },
      );

    } catch (e) {
      // فشل الإشعارات لا يمنع عمل التطبيق — السائق يرى العروض ما دام
      // التطبيق مفتوحاً. نسجّل ولا نُسقط.
      debugPrint('تعذّرت تهيئة الإشعارات: $e');
    }

    // **إذن الموقع ليس هنا.** كان يُطلب عند الإقلاع، فيرى المستخدم
    // نافذةً تسأل عن موقعه قبل أن يسجّل دخوله — يُخيف ولا يُفسَّر،
    // وأكثر الناس يرفض ما لا يفهم سببه.
    //
    // فانتقل إلى شاشة الخريطة نفسها (`_seedFromLastKnown`): تُسأل حين
    // يكون السؤال مفهوماً — خريطةٌ أمامه تنتظر موقعه.
  }

  /// يعيد جلب حالة العرض والرحلة فور فتح إشعار.
  ///
  /// **لماذا لا ننتظر البثّ اللحظي؟** أندرويد يقطع مقابس الويب في وضع
  /// الخمول (doze)، فقد تمرّ ثوانٍ بعد الاستيقاظ قبل أن يعود الاتصال
  /// ويصل خبر العرض — وهي ثوانٍ من مهلة محدودة. الإبطال يفرض جلباً
  /// مباشراً بـ HTTP لا ينتظر عودة المقبس.
  ///
  /// ولا نزال لا ننقل يدوياً: نحدّث الحالة فقط، والموجّه يقرأها ويقرر.
  /// إعلانٌ من الإدارة فُتح: إن كان حافزاً فُتحت «الحوافز»، وإلا فلا شيء.
  ///
  /// **يُعرف الحافز من عنوانه.** `my_notifications` تعيد العنوان لا النوع،
  /// وإعلانات الحوافز كلّها تبدأ بـ«حافز» (0108 و0110: «حافز جديد: …»
  /// و«حافز خاصٌّ لك: …»). ولا تُحمَّل الشاشة إن فشل شيء: أسوأ ما يحدث
  /// أن يبقى السائق حيث هو — لا رسالةٌ كاذبة.
  Future<void> _openNotice(Map<String, dynamic> data) async {
    final id = '${data['notification_id'] ?? ''}';
    if (id.isEmpty || ref.read(sessionProvider) == null) return;
    try {
      final rows = await ref
          .read(supabaseProvider)
          .rpc('my_notifications', params: {'p_limit': 50}) as List;
      final n = rows.cast<Map>().where((r) => '${r['id']}' == id).firstOrNull;
      if (n != null && '${n['title']}'.trim().startsWith('حافز')) {
        ref.invalidate(myIncentivesProvider);
        ref.read(routerProvider).push('/incentives');
      }
    } catch (e) {
      debugPrint('تعذّر فتح الإعلان: $e');
    }
  }

  Future<void> _refreshAfterNotification() async {
    try {
      ref.invalidate(pendingOffersProvider);
      ref.invalidate(activeDriverTripProvider);

      // إن لم يكن هناك عرض معلّق بعد التحديث، فقد فات أوانه — نُعلم
      // السائق بدل أن يجد نفسه في الخريطة بلا تفسير.
      //
      // إلا في حالة واحدة: الإقلاع البارد قبل استعادة الجلسة. المزوّد
      // يعيد null لأنه لا يعرف السائق بعد، لا لأن العرض انتهى — والإعلان
      // هنا كذبٌ يربك السائق في كل مرة يفتح فيها إشعاراً والتطبيق مغلق.
      if (ref.read(sessionProvider) == null) return;

      final offers = await ref.read(pendingOffersProvider.future);
      final trip = await ref.read(activeDriverTripProvider.future);
      if (offers.isEmpty && trip == null && mounted) {
        ref.read(missedOfferProvider.notifier).flag();
      }
    } catch (e) {
      debugPrint('تعذّر تحديث الحالة بعد الإشعار: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (bootError != null) return _BootErrorApp(message: bootError!);

    final router = ref.watch(routerProvider);

    // سائق حالته `online` في القاعدة والتتبّع لا يعمل: يحدث بعد إغلاق
    // التطبيق أو قتله من قائمة المهام دون قطع الاتصال. يبدو متصلاً في
    // اللوحة ولا تصله طلبات، لأن موقعه يتقادم فيستبعده البحث.
    //
    // نراقب هنا لا في الشاشة الرئيسية: الإقلاع البارد من إشعار قد
    // يهبط مباشرة على شاشة الرحلة ولا يمرّ بها إطلاقاً.
    // **لا جلسة = لا تتبّع.** كان المتتبّع يبقى يعمل بعد الخروج، فيرسل
    // الموقع كل خمس ثوانٍ بلا حساب ويُرفض كل مرة (42501) — بطاريةٌ
    // تُستنزف، وإشعار «متصل» دائمٌ لسائقٍ خرج.
    // **رحلةٌ اكتملت ⇐ أرقام اليوم والحافز تُعاد من القاعدة.** المزوّدان
    // يُجلبان مرّةً ويبقيان في الذاكرة، فكانت حلقة الحافز وأرباح اليوم
    // تتجمّد على قيمتها الأولى — والقاعدة تعدّ صحيحاً. و`trips_completed`
    // يزيد في `complete_trip` لكلّ رحلة، ويصل ببثّ سجلّ السائق.
    ref.listen(driverRecordProvider, (prev, next) {
      final a = prev?.value?.tripsCompleted;
      final b = next.value?.tripsCompleted;
      if (a != null && b != null && a != b) {
        ref.invalidate(myIncentivesProvider);
        ref.invalidate(earningsProvider);
        // طلب مندوبٍ «يُعاد الثمن بعد التسليم» ينشئ دَيناً للمتجر لحظة
        // اكتماله — فيظهر في بطاقة الرئيسية الحمراء فوراً.
        ref.invalidate(storeDuesProvider);
      }
      // **والرصيد وحده يكفي لإعادة الفحص:** شحنٌ برمزٍ يرفع الإيقاف، وعمولةٌ
      // تُنزل الرصيد تحت الأرضية — ولا رحلة في أيٍّ منهما بالضرورة.
      if (a != b ||
          prev?.value?.walletBalance != next.value?.walletBalance) {
        ref.invalidate(orderBlocksProvider);
      }
    });

    ref.listen(sessionProvider, (_, next) {
      if (next == null) {
        ref.read(locationTrackerProvider.notifier).stop();
        WakelockPlus.disable();
      }
    });

    ref.listen(driverRecordProvider, (_, next) {
      final d = next.value;
      if (d == null) return;
      final tracker = ref.read(locationTrackerProvider.notifier);
      // **بلا await ولا catch كان الاستثناء يسقط بعد الدخول.** سائقٌ
      // حالته `online` في القاعدة (حساب مراجعة أو جلسة سابقة) يطلق
      // التتبّع فور وصول السجلّ — ورفض إذن الموقع أو فشل GPS على
      // iPad المراجعة يرمي GeoException بلا ملتقط، فيبدو التطبيق
      // معطوباً بعد تسجيل الدخول (رفض آبل 2.1).
      if (d.status != DriverStatus.offline && !tracker.isRunning) {
        // ignore: discarded_futures
        tracker.start().catchError((Object e) {
          debugPrint('تعذّر بدء تتبّع الموقع تلقائياً: $e');
        });
      }

      // الخدمة المغلقة من الإدارة لا تُحسب نيّةً: مفتاحها مخفيّ عنه.
      final services = ref.read(serviceStatusProvider).value ??
          const ServiceAvailability.open();
      if (d.wantsWork(services) &&
          d.canGoOnline &&
          d.status == DriverStatus.offline) {
        _reconnect();
      }
    });

    return MaterialApp.router(
      // **الخلفية الحيّة خلف الشاشات كلّها من هنا.** `go_router` يبني
      // شاشاته بلا انتقالٍ (`NoTransitionPage`)، فلا يمرّ بانتقال السمة
      // الذي يرسمها للصفحات العادية — وُجد ذلك بتجربةٍ لا بقراءة. فتُرسم
      // مرّةً تحت الملّاح كلّه، والشاشات شفّافةٌ فوقها.
      builder: (context, child) =>
          ZMeshBackground(child: child ?? const SizedBox.shrink()),
      title: 'كابتن زنبور',
      debugShowCheckedModeBanner: false,
      routerConfig: router,

      // -----------------------------------------------------------------------
      // التعريب واتجاه الكتابة
      //
      // تحديد locale بالعربية يقلب الواجهة كلها إلى RTL تلقائياً: الحشوات،
      // والمحاذاة، واتجاه أيقونات الرجوع. لا نحتاج Directionality يدوياً.
      // -----------------------------------------------------------------------
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      theme: ZanbourTheme.light,
      darkTheme: ZanbourTheme.dark,
    );
  }
}

/// شاشة بديلة حين يفشل الإقلاع — تعرض السبب بدل انهيار صامت.
class _BootErrorApp extends StatelessWidget {
  const _BootErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ZanbourTheme.light,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 72, color: ZanbourTheme.warning),
                const SizedBox(height: 16),
                const Text('تعذّر تشغيل التطبيق',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
