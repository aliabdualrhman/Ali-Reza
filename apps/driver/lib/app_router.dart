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
import 'features/driver/active_trip_screen.dart';
import 'features/driver/cash_change_screen.dart';
import 'features/driver/store_dues_screen.dart';
import 'features/driver/documents_screen.dart';
import 'features/driver/driver_home_screen.dart';
import 'features/driver/driver_repository.dart';
import 'features/driver/incentives_screen.dart';
import 'features/driver/guest_home_screen.dart';
import 'features/driver/my_ratings_screen.dart';
import 'features/driver/my_trips_screen.dart';
import 'features/driver/offer_screen.dart';
import 'features/driver/rate_rider_screen.dart';
import 'features/driver/pending_approval_screen.dart';
import 'features/driver/push_check_screen.dart';
import 'features/driver/wallet_screen.dart';

/// موجّه تطبيق السائق.
///
/// أعقد من موجّه الراكب لأنه يحرس **بوابتين** لا واحدة:
///
///   ١) الجلسة — هل سجّل الدخول؟
///   ٢) الاعتماد — هل وافق المدير على وثائقه؟
///
/// السائق غير المعتمد لا يصل الشاشة الرئيسية مهما فعل، لأن كل ما فيها
/// (الاتصال، استقبال العروض) ترفضه القاعدة عليه أصلاً. حجبه هنا يوفّر
/// عليه رسائل رفض متكررة لا يفهم سببها.
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
      final onPublic = publicPaths.contains(path);

      // ---- البوابة الأولى: الجلسة ----
      if (!loggedIn) {
        // **الضيف له شاشةٌ واحدة.** انظر `GuestHomeScreen` — رئيسية
        // السائق قائمةٌ على سجلّه ولا تعمل بلا حساب.
        if (ref.read(guestModeProvider)) {
          return (path == '/guest' || onPublic) ? null : '/guest';
        }
        return onPublic ? null : '/login';
      }

      // **من سجّل دخوله لم يعد ضيفاً** — والجلسة قد تأتي من التسجيل أو
      // من رابط الاستعادة، لا من شاشة الدخول وحدها.
      if (ref.read(guestModeProvider)) {
        ref.read(guestModeProvider.notifier).exit();
      }
      if (path == '/guest') return _afterAuth(ref);

      // **لا حاجز توثيقٍ على الدخول.** شاشة الرمز تُفتح من التسجيل
      // وحده (انظر `signup_screen`)، أو يطلبها المستخدم من «حسابي».
      //
      // وكان حاجزٌ هنا يعترض كل دخول: فمن سجّل قبل تفعيل الوضع، أو
      // تخطّى التوثيق مرة، يُساق إليه في كل مرة يفتح التطبيق — ولا
      // مخرج له إلا أن يوثّق أو يترك التطبيق. وهو ما لم نقصده:
      // التوثيق مطلوبٌ عند إنشاء الحساب، لا شرطاً لكل جلسة.
      if (onPublic && !_midAuthFlow(path)) return _afterAuth(ref);



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

      // ---- البوابة الثانية: الاعتماد ----
      //
      // نقرأ القيمة المخزّنة لا ننتظرها: redirect دالة متزامنة لا تقبل
      // await. وأثناء التحميل الأول تكون null فلا نوجّه — يعيد
      // refreshListenable التقييم فور وصول البيانات.
      final driver = ref.read(driverRecordProvider).value;
      if (driver == null) return null;

      // صفحات مسموحة قبل الاعتماد: الانتظار والوثائق والصورة الحية
      // **والرمز معها.** بوابة الاعتماد تطرد كل ما ليس في هذه القائمة،
      // وشاشة الرمز تُفتح قبل الاعتماد بالتعريف.
      const preApproval = {
        '/pending',
        '/documents',
        '/selfie',
        '/verify-phone',
      };

      if (!driver.canGoOnline) {
        // **التوثيق قبل الوثائق — عند كل دخول لا بعد التسجيل وحده.**
        // الراية أعلاه تُرفع في شاشة التسجيل؛ فمن أغلقها قبل الرمز ثم دخل
        // لاحقاً كان يصل إلى رفع وثائقه برقمٍ غير موثَّق، فيصل طلبه إلى
        // المدير. والمعتمَد لا يُعترض — راجعه المدير بنفسه.
        //
        // وفي وضع البريد لا شيء هنا: Supabase لا يُدخل بريداً غير مؤكَّد.
        final v = ref.read(verificationProvider).value;
        final needsPhone = v != null &&
            v['mode'] == 'phone' &&
            v['otp_enabled'] == true &&
            v['phone'] != true;
        if (needsPhone && path != '/verify-phone') return '/verify-phone';

        return preApproval.contains(path) ? null : _afterAuth(ref);
      }

      // معتمد: نخرجه من شاشة الانتظار، ونترك له الوثائق ليراجعها
      if (path == '/pending' || path == '/selfie') return '/home';

      // ---- عرض معلّق: يسبق كل شيء ----
      //
      // **ثغرة أصلحناها بعد اختبار حقيقي:** كان فتح الإشعار لا يفعل
      // شيئاً — كتبت debugPrint وعلّقت أن "الموجّه يقرر"، ولم أكتب
      // ذلك المنطق. فالإشعار يوقظ التطبيق ثم يقف.
      //
      // الفحص هنا يعمل مهما كان طريق الوصول: بثّ لحظي، أو ضغط إشعار،
      // أو إقلاع بارد من إشعار.
      //
      // **ونفرّق بين "لا عرض" و"لم نعرف بعد".** كلاهما `value == null`،
      // لكن معناهما متضادّان: الأول يعني أن العرض انتهى فنخرج، والثاني
      // أن الجلب لم يكتمل — والخروج عنده يطرد السائق من شاشة عرض قائم.
      // يحدث ذلك في كل تحديث للحالة، ومنها التحديث الذي نطلقه نحن فور
      // فتح الإشعار.
      final offersAsync = ref.read(pendingOffersProvider);
      final offers = offersAsync.value;
      if (offers != null && offers.isNotEmpty && path != '/offer') {
        return '/offer';
      }
      if ((offers == null || offers.isEmpty) && path == '/offer') {
        if (offersAsync.isLoading) return null;   // ننتظر، لا نطرد
        return '/home';
      }

      // ---- رحلة جارية ----
      final tripAsync = ref.read(activeDriverTripProvider);
      final trip = tripAsync.value;
      if (trip != null && path != '/trip' && path != '/offer') return '/trip';

      // ---- تقييم معلّق ----
      //
      // بعد العرض والرحلة لا قبلهما: طلبٌ جديد أولى من تقييم رحلة
      // ماضية، والسائق لا يجب أن يُحبس عن العمل بسبب نجمة لم يعطها.
      //
      // **ولماذا شاشة في الموجّه لا نافذة في شاشة الرحلة؟** لأن النافذة
      // تموت مع الشاشة التي فتحتها — والموجّه ينقله إلى الخريطة فور
      // اكتمال الرحلة، فتظهر النافذة وتختفي في اللحظة نفسها.
      final rating = ref.read(pendingRatingProvider);
      // **المال قبل التقييم.** من قيّم ثم أُغلق التطبيق نسي الباقي،
      // والراكب ينتظره. والتقييم يحتمل التأجيل، والمال لا.
      final cash = ref.read(pendingCashProvider);
      if (cash != null && path != '/cash') return '/cash';
      if (cash == null && path == '/cash') return '/home';

      if (rating != null && path != '/rate') return '/rate';
      if (rating == null && path == '/rate') return '/home';

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
          onDone: () => c.go('/pending'),
        ),
      ),
      GoRoute(path: '/selfie', builder: (_, _) => const SelfieScreen()),
      GoRoute(
        path: '/pending',
        builder: (_, _) => const PendingApprovalScreen(),
      ),
      GoRoute(path: '/documents', builder: (_, _) => const DocumentsScreen()),
      GoRoute(path: '/home', builder: (_, _) => const DriverHomeScreen()),
      GoRoute(path: '/guest', builder: (_, _) => const GuestHomeScreen()),
      GoRoute(path: '/wallet', builder: (_, _) => const WalletScreen()),
      GoRoute(
          path: '/incentives',
          builder: (_, _) => const IncentivesScreen()),
      GoRoute(path: '/my-trips', builder: (_, _) => const MyTripsScreen()),
      GoRoute(
          path: '/store-dues', builder: (_, _) => const StoreDuesScreen()),
      GoRoute(
        path: '/verify-phone',
        // **`onDone` لا `pop`.** الشاشة تُفتح بـ`pushReplacement` فتصير
        // الجذر، و`canPop` تعود false — فيضغط المستخدم «تأكيد» وينجح
        // التوثيق ولا يتحرّك شيء. وإبطالُ المزوّد قبل الانتقال ضروري:
        // بدونه يقرأ الحاجزُ حالةً قديمة فيعيده إلى الشاشة نفسها.
        builder: (ctx, _) => VerifyPhoneScreen(
          onDone: () {
            // **الوجهة قبل طيّ الراية.** `_afterAuth` يعتمد على
            // `justSignedUp` لإرسال التسجيل الجديد إلى الوثائق لا
            // الانتظار. طيّها أولاً كان يُسقطه على `/pending`.
            ref.invalidate(verificationProvider);
            final next = _afterAuth(ref);
            ref.read(justSignedUpProvider.notifier).set(false);
            ctx.go(next);
          },
        ),
      ),
      GoRoute(path: '/account',
          builder: (_, _) => const AccountScreen(driver: true)),
      GoRoute(path: '/my-ratings', builder: (_, _) => const MyRatingsScreen()),
      GoRoute(path: '/push-check', builder: (_, _) => const PushCheckScreen()),
      GoRoute(path: '/offer', builder: (_, _) => const OfferScreen()),
      GoRoute(path: '/trip', builder: (_, _) => const ActiveTripScreen()),
      GoRoute(
        path: '/cash',
        builder: (c, _) {
          final t = ref.read(pendingCashProvider);
          if (t == null) return const SizedBox.shrink();
          return CashChangeScreen(
            tripId: t['id'] as String,
            cashDue: t['_due'] as num,
            // **إبطالٌ قبل الانتقال.** بدونه يقرأ الحارس حالةً قديمة
            // فيعيده إلى الشاشة نفسها.
            onDone: () {
              ref.invalidate(lastCompletedTripProvider);
              c.go('/rate');
            },
          );
        },
      ),
      GoRoute(path: '/rate', builder: (_, _) => const RateRiderScreen()),
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
/// نراقب المصادقة **وسجل السائق**: حين يعتمده المدير يتبدّل الصف عبر
/// البثّ اللحظي، فيُعاد تقييم التوجيه وينتقل من شاشة الانتظار إلى العمل
/// وهو ينظر إلى الشاشة — بلا إعادة تشغيل ولا سحب للتحديث.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    _subs.add(ref.listen(authStateProvider, (_, _) => notifyListeners()));
    // دخول الضيف وخروجه يغيّران الوجهة ولا يغيّران الجلسة.
    _subs.add(ref.listen(guestModeProvider, (_, _) => notifyListeners()));
    // **حارس نوع الحساب.** يفحص كل جلسة — بما فيها المحفوظة من قبل
    // الإصلاح — ويُخرج من دخل بحسابٍ من النوع الخطأ.
    _subs.add(ref.listen(roleGuardProvider, (_, _) => notifyListeners()));
    // **بوابة الرمز تقرأ هذين.** بلا الاستماع إليهما تبقى الراية
    // مرفوعة وبيانات التوثيق واصلة، ولا يُعاد التقييم أبداً — فتضيع
    // الشاشة كما ضاعت من قبل.
    _subs.add(ref.listen(verificationProvider, (_, _) => notifyListeners()));
    _subs.add(ref.listen(justSignedUpProvider, (_, _) => notifyListeners()));

    _subs.add(ref.listen(driverRecordProvider, (_, _) => notifyListeners()));
    // **والوثائق أيضاً.** `_afterAuth` تقرؤها، ولو لم نستمع لها بقي
    // السائق على «قيد المراجعة» حتى تصل — ثم لا يُعاد التقييم أبداً.
    _subs.add(ref.listen(myDocumentsProvider, (_, _) => notifyListeners()));
    // بدون مراقبة العرض والرحلة لن يُعاد التقييم عند وصولهما،
    // فيبقى السائق في الشاشة الرئيسية بينما ينتظره طلب.
    _subs.add(ref.listen(pendingOffersProvider, (_, _) => notifyListeners()));
    _subs.add(
        ref.listen(activeDriverTripProvider, (_, _) => notifyListeners()));
    // ومراقبة التقييم المعلّق: بدونها لا يُعاد التقييم حين تكتمل رحلة،
    // فلا تظهر شاشة التقييم إلا بتنقّل يدوي مصادف.
    _subs.add(ref.listen(pendingRatingProvider, (_, _) => notifyListeners()));
    _subs.add(ref.listen(pendingCashProvider, (_, _) => notifyListeners()));
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

/// أين يهبط السائق بعد الدخول: الوثائق أم الانتظار؟
///
/// **«قيد المراجعة» قبل رفع الوثائق كذبة.** لا شيء يُراجَع ولا أحد
/// ينتظره — بل هو الذي ينتظر بلا أن يعرف أن الدور عليه، فيقعد يوماً
/// يظنّ المدير متأخّراً. فما دام مطلوبٌ لم يُرفع، وجهته الرفع.
///
/// وأثناء أول تحميل تكون القائمة `null` فنختار الانتظار: شاشةٌ ساكنة
/// خيرٌ من قفزةٍ إلى الوثائق ثم قفزةٍ عنها حين تصل البيانات.
String _afterAuth(Ref ref) {
  // **شاشة الوثائق للتسجيل الجديد وحده.**
  //
  // كانت تُحسب من عدّاد الملفّات، فيمرّ بها سائقٌ معتمَدٌ رفع وثائقه
  // كلها في كل مرة يفتح التطبيق — ومضةً قبل أن يصل إلى عمله. والسبب
  // أن العدّاد يُقرأ من الشبكة، فيكون فارغاً في اللحظة الأولى فيُحسب
  // «ناقصاً».
  //
  // **والراية أصدق من العدّاد:** من سجّل للتوّ يحتاج الرفع، ومن دخل
  // بحسابٍ قائمٍ لا يحتاجه — ولو نقصته وثيقة، فشاشة الانتظار تقول له
  // «بقيت وثائقك» وفيها زرّها.
  if (ref.read(justSignedUpProvider)) return '/documents';
  return '/pending';
}

/// مسارات التسجيل التي لا يجوز للموجّه أن يقاطعها.
///
/// **`/verify-phone` كانت ناقصة، فكانت الشاشة تُطرد قبل أن تُرسم.**
/// التسجيل يدفعها، فيعمل `redirect` على المسار الجديد فلا يجدها في
/// أيّ قائمة مسموحة فيردّها إلى `/documents`. فيمرّ السائق بلا رمزٍ
/// أبداً — لا لأن الوضع بريد، بل لأن الموجّه لم يعرفها.
///
/// **`/verify-email` ليست هنا عمداً.** قبل الجلسة يبقيها `!loggedIn`.
/// وبعد نجاح الرمز تُنشأ الجلسة؛ إن بقيت في القائمة منع السطر أعلاه
/// التوجيه فيبقى السائق عالقاً على شاشة التوثيق إلى الأبد.
bool _midAuthFlow(String path) =>
    path == '/reset-password' ||
    path == '/verify-phone';
