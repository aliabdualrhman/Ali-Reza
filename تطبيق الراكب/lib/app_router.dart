import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'features/auth/auth_repository.dart';
import 'features/auth/forgot_password_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/selfie_screen.dart';
import 'features/auth/signup_screen.dart';
import 'features/auth/verify_email_screen.dart';
import 'features/delivery/deliveries_screen.dart';
import 'features/delivery/delivery_detail_screen.dart';
import 'features/delivery/new_delivery_screen.dart';
import 'features/delivery/store_screen.dart';
import 'features/home/home_screen.dart';
import 'features/trip/map_screen.dart';
import 'features/shopping/shopping_screen.dart';
import 'features/trip/my_trips_screen.dart';
import 'features/trip/rate_driver_screen.dart';
import 'features/trip/searching_screen.dart';
import 'features/trip/trip_repository.dart';
import 'features/settings/notifications_screen.dart';

/// موجّه التطبيق مع حراسة المصادقة واكتمال الملف الشخصي.
///
/// **المبدأ:** الشاشات لا تقرر إلى أين تنتقل. الموجّه يراقب الجلسة والملف
/// الشخصي ويعيد التوجيه من مكان واحد.
///
/// لو تركنا كل شاشة تنقل بنفسها لتفرّق المنطق في عشرة أماكن، ولظهرت حالات
/// مثل: انتهت الجلسة أثناء التصفح فبقي المستخدم يرى بيانات لا يملكها.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: _RouterRefresh(ref),

    redirect: (context, state) {
      final loggedIn = ref.read(sessionProvider) != null;
      final path = state.matchedLocation;

      const publicPaths = {
        '/login',
        '/signup',
        '/forgot-password',
        '/verify-email',
        '/reset-password',
      };
      final onPublicPage = publicPaths.contains(path);

      // ---- غير مسجّل ----
      if (!loggedIn) {
        // **الضيف يرى الواجهة لا البيانات.** ثلاث شاشاتٍ فقط، وكلها
        // تعمل بدور `anon` — وأي مسارٍ غيرها يعيده إلى الرئيسية لا إلى
        // شاشة الدخول، فالتصفّح لا ينقطع بضغطةٍ خاطئة.
        if (ref.read(guestModeProvider)) {
          if (_guestPaths.contains(path) || onPublicPage) return null;
          return '/home';
        }
        return onPublicPage ? null : '/login';
      }

      // **من سجّل دخوله لم يعد ضيفاً.** العلامة تُنزل هنا لا في شاشة
      // الدخول وحدها: الجلسة قد تأتي من رابط استعادة أو من التسجيل.
      if (ref.read(guestModeProvider)) {
        ref.read(guestModeProvider.notifier).exit();
      }



      // **لا حاجز توثيقٍ على الدخول.** شاشة الرمز تُفتح من التسجيل
      // وحده (انظر `signup_screen`)، أو يطلبها المستخدم من «حسابي».
      //
      // وكان حاجزٌ هنا يعترض كل دخول: فمن سجّل قبل تفعيل الوضع، أو
      // تخطّى التوثيق مرة، يُساق إليه في كل مرة يفتح التطبيق — ولا
      // مخرج له إلا أن يوثّق أو يترك التطبيق. وهو ما لم نقصده:
      // التوثيق مطلوبٌ عند إنشاء الحساب، لا شرطاً لكل جلسة.
      // ---- مسجّل ----
      // نستثني /verify-email لئلا نقطع شاشة الرمز على من سجّل للتو.
      if (onPublicPage && !_midAuthFlow(path)) return '/home';


      // ---- بوابة الرمز: للتسجيل الجديد وحده ----
      //
      // **تُقرأ في كل تقييم لا مرةً واحدة.** فإن تأخّرت بيانات التوثيق
      // بقيت الراية مرفوعة، وأعاد `refreshListenable` التقييم فور
      // وصولها — فالشبكة البطيئة تؤجّل الشاشة ولا تُلغيها.
      //
      // ولا تعترض الدخول: الراية تُرفع في شاشة التسجيل وحدها.
      if (ref.read(justSignedUpProvider) && path != '/verify-phone') {
        final v = ref.read(verificationProvider).value;
        if (v != null && v.isNotEmpty) {
          final needsPhone = v['mode'] == 'phone' &&
              v['otp_enabled'] == true &&
              v['phone'] != true;
          if (needsPhone) return '/verify-phone';
          // وضعٌ غير الهاتف، أو رقمٌ موثَّق أصلاً: تُطوى الراية.
          ref.read(justSignedUpProvider.notifier).set(false);
        }
        // ما زالت `null`: لا نوجّه، ولا نُسقط الراية. التقييم يتكرّر.
      }

      // ---- الرحلة النشطة تسبق كل شيء ----
      //
      // **ثغرة أصلحناها بعد اختبار حقيقي:** كان الانتقال لشاشة البحث
      // يحدث بعد الطلب فقط. فإذا أعاد النظام تشغيل التطبيق — وشاومي
      // تفعلها كثيراً حين تُقفل الشاشة — يفتح على الرئيسية بينما رحلته
      // ما زالت نشطة في القاعدة.
      //
      // النتيجة: راكب عالق. لا يرى رحلته، ولا يستطيع طلب غيرها لأن
      // الفهرس الفريد يمنع رحلتين نشطتين.
      //
      // الحل: الموجّه يتحقق في كل تقييم، فيعيده إلى رحلته أينما كان.
      final activeTrip = ref.read(activeTripProvider).value;
      if (activeTrip != null && path != '/searching') {
        return '/searching';
      }

      // ---- تقييم معلّق ----
      //
      // بعد الرحلة النشطة لا قبلها: رحلة جارية أولى من تقييم ماضية.
      //
      // **ولماذا شاشة في الموجّه لا نافذة منبثقة؟** لأن النافذة تموت مع
      // الشاشة التي فتحتها، والتوجيه يحدث فور اكتمال الرحلة — فتظهر
      // وتختفي في اللحظة نفسها. الشاشة تصمد أمام التصغير والإغلاق.
      final rating = ref.read(pendingRatingProvider);
      if (rating != null && path != '/rate') return '/rate';
      if (rating == null && path == '/rate') return '/home';

      // **لا حاجز صورةٍ على الراكب.** كان يُمنع من التطبيق حتى يرفع
      // صورةً حية، والحاجز في موضعٍ خاطئ: الراكب لا ينقل أحداً ولا
      // يقبض مالاً، والصورة لم تكن تُراجَع أصلاً — يعتمدها مُشغّل 0011
      // تلقائياً بلا أن ينظر إليها أحد. حاجزٌ يزعج ولا يحمي، وكل خطوة
      // بين «حمّلتُ» و«طلبتُ» تفقد جزءاً من الناس. انظر 0058.
      //
      // والشاشة باقية: من أراد صورةً لملفه يفتحها من «حسابي».

      return null;
    },

    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/signup', builder: (_, _) => const SignUpScreen()),
      GoRoute(
        path: '/forgot-password',
        builder: (_, _) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/verify-email',
        builder: (_, s) => VerifyEmailScreen(email: s.extra as String? ?? ''),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (c, s) => ResetPasswordScreen(
          email: s.extra as String? ?? '',
          onDone: () => c.go('/home'),
        ),
      ),
      GoRoute(path: '/selfie', builder: (_, _) => const SelfieScreen()),
      GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/map', builder: (_, _) => const MapScreen()),
      GoRoute(path: '/my-trips', builder: (_, _) => const MyTripsScreen()),
      GoRoute(
        path: '/verify-phone',
        // **`onDone` لا `pop`.** الشاشة تُفتح بـ`pushReplacement` فتصير
        // الجذر، و`canPop` تعود false — فيضغط المستخدم «تأكيد» وينجح
        // التوثيق ولا يتحرّك شيء. وإبطالُ المزوّد قبل الانتقال ضروري:
        // بدونه يقرأ الحاجزُ حالةً قديمة فيعيده إلى الشاشة نفسها.
        builder: (ctx, _) => VerifyPhoneScreen(
          onDone: () {
            // **تُطوى الراية أولاً.** لو انتقلنا وهي مرفوعة لأعادنا
            // الموجّه إلى الشاشة نفسها.
            ref.read(justSignedUpProvider.notifier).set(false);
            ref.invalidate(verificationProvider);
            ctx.go('/home');
          },
        ),
      ),
      GoRoute(
          path: '/shopping', builder: (_, _) => const ShoppingScreen()),
      GoRoute(path: '/store', builder: (_, _) => const StoreScreen()),
      GoRoute(
          path: '/deliveries', builder: (_, _) => const DeliveriesScreen()),
      GoRoute(
          path: '/delivery/new',
          builder: (_, _) => const NewDeliveryScreen()),
      GoRoute(
        path: '/delivery/:id',
        builder: (_, s) =>
            DeliveryDetailScreen(tripId: s.pathParameters['id']!),
      ),
      GoRoute(path: '/account',
          builder: (_, _) => const AccountScreen(driver: false)),
      GoRoute(path: '/notifications',
          builder: (_, _) => const NotificationsScreen()),
      GoRoute(path: '/rate', builder: (_, _) => const RateDriverScreen()),
      GoRoute(
        path: '/searching',
        builder: (_, _) => const SearchingScreen(),
      ),
    ],

    errorBuilder: (_, state) => Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64),
              const SizedBox(height: 16),
              Text('الصفحة غير موجودة\n${state.uri}',
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
});

/// جسر بين مزوّدات Riverpod و refreshListenable الذي يتوقعه go_router.
///
/// نراقب شيئين: حالة المصادقة (دخول/خروج/انتهاء جلسة)، والملف الشخصي
/// (لتُعاد المحاسبة فور اعتماد الصورة الحية).
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    _subs.add(ref.listen(authStateProvider, (_, _) => notifyListeners()));
    // **دخول الضيف وخروجه يغيّران الوجهة** ولا يغيّران الجلسة — فبلا
    // هذا يضغط «تصفّح كضيف» ويبقى على شاشة الدخول.
    _subs.add(ref.listen(guestModeProvider, (_, _) => notifyListeners()));
    // **حارس نوع الحساب.** يفحص كل جلسة — بما فيها المحفوظة من قبل
    // الإصلاح — ويُخرج من دخل بحسابٍ من النوع الخطأ.
    _subs.add(ref.listen(roleGuardProvider, (_, _) => notifyListeners()));
    // **بوابة الرمز تقرأ هذين.** بلا الاستماع إليهما تبقى الراية
    // مرفوعة وبيانات التوثيق واصلة، ولا يُعاد التقييم أبداً — فتضيع
    // الشاشة كما ضاعت من قبل.
    _subs.add(ref.listen(verificationProvider, (_, _) => notifyListeners()));
    _subs.add(ref.listen(justSignedUpProvider, (_, _) => notifyListeners()));

    _subs.add(ref.listen(myProfileProvider, (_, _) => notifyListeners()));
    // بدون مراقبة الرحلة النشطة لن يُعاد التقييم حين تنتهي، فيبقى
    // الراكب حبيس شاشة البحث بعد وصوله.
    _subs.add(ref.listen(activeTripProvider, (_, _) => notifyListeners()));
    // ومراقبة التقييم المعلّق: بدونها لا يُعاد التقييم حين تكتمل رحلة،
    // فلا تظهر شاشة التقييم إلا بتنقّل يدوي مصادف.
    _subs.add(ref.listen(pendingRatingProvider, (_, _) => notifyListeners()));
  }

  final List<ProviderSubscription> _subs = [];

  @override
  void dispose() {
    for (final s in _subs) {
      s.close();
    }
    super.dispose();
  }
}

/// مسارات لا يقطعها الحارس رغم وجود جلسة.
///
/// **لماذا؟** كلاهما يُنشئ الجلسة في منتصف العمل لا في نهايته: تأكيد
/// التسجيل، والتحقق من رمز الاستعادة. ولو وجّه الحارس عندها لَقُطعت
/// الشاشة قبل أن يضبط صاحبها كلمة مروره الجديدة — فيبقى بحساب لا يعرف
/// كلمة مروره.
/// مسارات التسجيل التي لا يجوز للموجّه أن يقاطعها.
///
/// **و`/verify-phone` منها.** مساواةً بتطبيق السائق، حيث كان غيابها
/// يطرد الشاشة إلى `/documents` قبل أن تُرسم.
bool _midAuthFlow(String path) =>
    path == '/verify-email' ||
    path == '/reset-password' ||
    path == '/verify-phone';

/// ما يراه الضيف — الرئيسية، والخريطة بأجرتها التقديرية، والتسوّق.
///
/// **لا «حسابي» ولا «رحلاتي».** شاشتان لا معنى لهما بلا حساب، وتقرآن
/// بياناتٍ لا يملكها `anon` أصلاً — فتظهران فارغتين أو معطوبتين.
const _guestPaths = {'/home', '/map', '/shopping'};
