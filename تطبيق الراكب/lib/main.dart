import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'app_router.dart';
import 'core/push_service.dart';
import 'core/trip_notifier.dart';
import 'features/auth/auth_repository.dart';
import 'features/trip/trip_repository.dart';

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
    }
  } catch (e) {
    bootError = e.toString();
  }

  runApp(const ProviderScope(child: ZanbourApp()));
}

class ZanbourApp extends ConsumerStatefulWidget {
  const ZanbourApp({super.key});

  @override
  ConsumerState<ZanbourApp> createState() => _ZanbourAppState();
}

class _ZanbourAppState extends ConsumerState<ZanbourApp> {
  @override
  void initState() {
    super.initState();
    // بعد أول إطار: التهيئة تلمس المزوّدات، وقراءتها أثناء البناء ممنوعة.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initPush());
  }

  Future<void> _initPush() async {
    if (bootError != null) return;

    // **الطبقة التي لا تحتاج جوجل.** تُصغي لتدفّق الرحلة وتعرض إشعاراً
    // محلياً عند تبدّل الحالة — فتعمل على جهاز لا يولّد رمز FCM أصلاً.
    // نبدأها قبل فايربيز: تهيئة الأخيرة قد تفشل كلياً على تلك الأجهزة.
    ref.read(tripNotifierProvider).listen();
    try {
      final push = PushService(ref.read(supabaseProvider));
      await push.initialize(
        onOpened: (data) {
          // **لا ننقل يدوياً.** الموجّه يقرأ حالة الرحلة ويقرر الوجهة؛
          // والرحلة قد تكون انتهت أو أُلغيت بين وصول الإشعار وفتحه.
          debugPrint('فُتح إشعار: $data');
          ref.invalidate(activeTripProvider);
        },
      );

    } catch (e) {
      // فشل الإشعارات لا يمنع عمل التطبيق — الشاشة تتابع الحالة لحظياً
      // ما دامت مفتوحة. نسجّل ولا نُسقط.
      debugPrint('تعذّرت تهيئة الإشعارات: $e');
    }

    // **إذن الموقع ليس هنا.** كان يُطلب عند الإقلاع، فيرى المستخدم
    // نافذةً تسأل عن موقعه قبل أن يسجّل دخوله — يُخيف ولا يُفسَّر،
    // وأكثر الناس يرفض ما لا يفهم سببه.
    //
    // فانتقل إلى شاشة الخريطة نفسها (`_seedFromLastKnown`): تُسأل حين
    // يكون السؤال مفهوماً — خريطةٌ أمامه تنتظر موقعه.
  }

  @override
  Widget build(BuildContext context) {
    if (bootError != null) return _BootErrorApp(message: bootError!);

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'زنبور',
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
