import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/push_service.dart';

/// عميل Supabase — نقطة وصول واحدة بدل استدعاء المفرد في كل ملف.
final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

/// تدفّق حالة المصادقة.
final authStateProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(supabaseProvider).auth.onAuthStateChange;
});

final sessionProvider = Provider<Session?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentSession;
});

final myProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return null;

  return await ref
      .watch(supabaseProvider)
      .from('profiles')
      .select()
      .eq('id', session.user.id)
      .maybeSingle();
});

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(supabaseProvider)),
);

enum SignUpOutcome { signedIn, needsEmailConfirmation }

/// أنواع الوثائق التي يرفعها السائق، مع تسمياتها العربية.
///
/// الإلزامية منها تحدّدها **قاعدة البيانات** لا هذا الملف — الدالة
/// `recompute_verification` تعرف ما يلزم للاعتماد. هنا مجرد عرض.
enum DriverDocument {
  liveSelfie('live_selfie', 'صورة حية لوجهك', true),
  nationalIdFront('national_id_front', 'وجه البطاقة الوطنية', true),
  nationalIdBack('national_id_back', 'ظهر البطاقة الوطنية', true),
  vehiclePhoto('vehicle_photo', 'صور الدراجة', true),
  drivingLicense('driving_license', 'إجازة السوق', false),
  vehicleRegistration('vehicle_registration', 'سنوية الدراجة', false);

  const DriverDocument(this.code, this.label, this.required);

  final String code;
  final String label;
  final bool required;
}

class AuthRepository {
  AuthRepository(this._sb);

  final SupabaseClient _sb;

  User? get currentUser => _sb.auth.currentUser;

  /// تسجيل سائق جديد.
  ///
  /// الفرق عن الراكب: `role: 'driver'` و `vehicle_type`. المُشغّل
  /// `handle_new_user` يقرؤهما، ينشئ صف `drivers`، ويفرض حد العمر ١٨
  /// بدل ١٦ لأن السائق يقود مركبة وينقل ركّاباً.

  /// يفحص التعارضات **قبل** التسجيل.
  ///
  /// **ولماذا قبل لا بعد؟** لأن GoTrue يستبدل نصّ خطأ القاعدة كلياً
  /// ويردّ `Database error saving new user` لكل سبب. فمهما أتقنّا صياغة
  /// الخطأ في القاعدة لا يصل المستخدم إلا تخمين. انظر 0066.
  ///
  /// يرمي برسالةٍ تسمّي الحقل، أو يعود صامتاً إن كان كل شيء سليماً.
  Future<void> _assertNoConflicts({
    required String fullName,
    required String phone,
    required String email,
  }) async {
    final Map<String, dynamic> c;
    try {
      final v = await _sb.rpc('check_signup_conflicts', params: {
        'p_full_name': fullName,
        'p_phone': phone,
        'p_email': email,
      });
      c = (v as Map).cast<String, dynamic>();
    } catch (_) {
      // **قاعدةٌ لم تُرحَّل أو شبكةٌ منقطعة لا تمنع التسجيل.** يمضي
      // كما كان، ويردّ الخطأ الغامض إن وقع — أهون من منع رجلٍ سليم.
      return;
    }

    if (c['name_short'] == true) {
      throw AuthException('الاسم يجب أن يكون ثلاثياً — اسمك واسم أبيك وجدّك');
    }
    if (c['phone_invalid'] == true) {
      throw AuthException('رقم الهاتف غير صحيح. اكتبه هكذا: 07701234567');
    }
    if (c['phone_taken'] == true) {
      throw AuthException(
          'رقم الهاتف مسجّل بحساب آخر. إن كان رقمك فسجّل دخولك.');
    }
    if (c['email_taken'] == true) {
      throw AuthException(
          'هذا البريد مسجّل مسبقاً. سجّل دخولك أو استعد كلمة المرور.');
    }
    if (c['name_taken'] == true) {
      throw AuthException(
          'هذا الاسم مسجّل بحساب آخر. أضف اسم جدّك أو لقبك.');
    }
  }

  Future<SignUpOutcome> signUp({
    /// من أين سمع عن التطبيق: ad · street · friend · other
    String? heardFrom,
    String? heardFromNote,

    /// رمز دعوة صديق. **يُمرَّر في بيانات الحساب لا يُستدعى بعدها** —
    /// `redeem_referral_code` تعمل بـ`auth.uid()` وهي معدومة قبل تأكيد
    /// البريد، فيلتقطه مُشغّلٌ في القاعدة لحظة الإنشاء (0055).
    String? referralCode,
    required String email,
    required String password,
    required String fullName,
    required String phoneE164,
    required DateTime birthDate,
    required String address,
    required String vehicleType,
    required String vehiclePlate,
    required String vehicleColor,
    required String vehicleKind,
  }) async {
    await _assertNoConflicts(
      fullName: fullName,
      phone: phoneE164,
      email: email,
    );

    final res = await _sb.auth.signUp(
      email: email.trim(),
      password: password,
      data: {
        'role': 'driver',
        'full_name': fullName.trim(),
        'phone': phoneE164,
        'date_of_birth': birthDate.toIso8601String().split('T').first,
        'address': address.trim(),
        'vehicle_type': vehicleType.trim(),
        'vehicle_plate': vehiclePlate.trim(),
        'vehicle_color': vehicleColor.trim(),
        // 'bike' أو 'tuktuk' — المُشغّل handle_new_user يقرؤه ويكتبه
        // في سجل السائق. النوع لا يتغيّر بعد التسجيل.
        'vehicle_kind': vehicleKind,
        'locale': 'ar',
        'heard_from': ?heardFrom,
        if (heardFromNote != null && heardFromNote.trim().isNotEmpty)
          'heard_from_note': heardFromNote.trim(),
        if (referralCode != null && referralCode.trim().isNotEmpty)
          'referral_code': referralCode.trim().toUpperCase(),
      },
    );

    if (res.session != null) return SignUpOutcome.signedIn;

    // **بريدٌ مسجَّل سلفاً — يُكتشف هنا أو لا يُكتشف أبداً.**
    //
    // Supabase لا يُظهر خطأً حين يكون البريد موجوداً: يردّ نجاحاً وهمياً
    // عمداً، حمايةً من كشف من هو مسجَّل عنده. فيظنّ التطبيق أن حساباً
    // أُنشئ، ويفتح شاشة رمزٍ لن يصل أبداً، ويبقى المستخدم ينتظر ويعيد
    // الإرسال ويشكّ في بريده وفي الشبكة — والسبب أنه مسجَّل منذ شهر.
    //
    // والإشارة الوحيدة `identities` فارغة. وهي موثّقة ومقصودة.
    if (res.user != null && (res.user!.identities?.isEmpty ?? false)) {
      throw AuthException(
        'هذا البريد مسجّل مسبقاً. سجّل دخولك أو استعد كلمة المرور.',
      );
    }

    // **جلسةٌ فارغة لا تعني دائماً انتظار البريد.**
    //
    // حين يكون تأكيد البريد مفعّلاً في Supabase، `signUp` يُنشئ الحساب
    // ولا يُعيد جلسة. وفي وضع الهاتف يؤكّد مُشغّلٌ البريد لحظة الإنشاء
    // (0064) — فالحساب صار صالحاً للدخول، لكنّ الاستجابة كُتبت قبل ذلك.
    //
    // فالنتيجة: مستخدمٌ بحسابٍ سليم وبلا جلسة، **ولا يستطيع طلب رمز
    // الواتساب** لأن `request_phone_code` تعمل بـ`auth.uid()`. فيعلق في
    // شاشة تأكيد بريدٍ لا يحتاجه ولا يصله.
    //
    // ندخل نيابةً عنه بالبيانات التي كتبها للتوّ. ونجاحُه دليلٌ على أن
    // البريد مؤكَّد فعلاً — وفشلُه يعني أن التأكيد مطلوب حقاً.
    try {
      final signedIn = await _sb.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      if (signedIn.session != null) return SignUpOutcome.signedIn;
    } catch (_) {
      // البريد ما زال غير مؤكَّد — وهو الوضع `email` الطبيعي.
    }

    return SignUpOutcome.needsEmailConfirmation;
  }

  Future<void> signIn({required String email, required String password}) async {
    final res = await _sb.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    await assertRole(res.user?.id);
  }

  /// **الحارس الذي كان ناقصاً.**
  ///
  /// `auth.users` جدولٌ واحدٌ للتطبيقين — فبريدُ راكبٍ وكلمةُ مروره
  /// يُقبلان في تطبيق السائق، وGoTrue محقٌّ في قبولهما: البيانات صحيحة.
  /// لكنّ الحساب ليس من هذا النوع.
  ///
  /// **وما كان يقع بعدها أسوأ من الدخول نفسه:** لا صفَّ للراكب في
  /// `drivers`، فيظنّه التطبيق سائقاً جديداً ويطلب منه وثائق — فيرفع
  /// راكبٌ بطاقته الوطنية إلى مسارٍ لا يخصّه، ويظهر في قائمة السائقين
  /// المنتظرين.
  ///
  /// **والمشرف يُستثنى** — حسابه واحدٌ ويحتاج فتح التطبيقين للفحص.
  Future<void> assertRole(String? uid) async {
    if (uid == null) return;

    final row = await _sb
        .from('profiles')
        .select('role')
        .eq('id', uid)
        .maybeSingle();

    // **لا صفّ = لا حكم.** لحظةَ التسجيل يسبق إنشاءُ الجلسة إنشاءَ
    // الملف أحياناً؛ وطردُ صاحبها هنا يكسر التسجيل نفسه.
    if (row == null) return;

    final role = '${row['role']}';
    if (role == 'driver' || role == 'admin') return;

    await _sb.auth.signOut();
    throw AuthException(
      role == 'rider'
          ? 'هذا حساب راكب. سجّل دخولك من تطبيق «زنبور» للركّاب.'
          : 'لا يمكن الدخول بهذا الحساب من هنا.',
    );
  }


  /// **يُزال الجهاز قبل إنهاء الجلسة لا بعدها.**
  ///
  /// `unregister_device` تعمل بـ`auth.uid()`، وبعد `signOut` تصير
  /// معدومة فلا تحذف شيئاً — ويبقى الرمز مسجَّلاً فتصل إشعارات الحساب
  /// إلى هاتف من خرج منه.
  ///
  /// وفشلُ الإزالة لا يمنع الخروج: مستخدمٌ عالقٌ في حسابه أسوأ من رمزٍ
  /// يتيم، والخادم يحذفه وحده حين تردّ فايربيز أنه غير مسجَّل.
  Future<void> signOut() async {
    try {
      await PushService(_sb).clearToken();
    } catch (_) {}
    await _sb.auth.signOut();
  }

  Future<void> resetPassword(String email) =>
      _sb.auth.resetPasswordForEmail(email.trim());

  Future<void> resendConfirmation(String email) =>
      _sb.auth.resend(type: OtpType.signup, email: email.trim());

  /// تأكيد البريد برمز مكوّن من ٦ أرقام.
  ///
  /// **يتطلب تعديلاً في لوحة Supabase:** قالب رسالة "Confirm signup" يجب أن
  /// يعرض `{{ .Token }}` بدل `{{ .ConfirmationURL }}`. القالب الافتراضي
  /// يرسل رابطاً يفتح صفحة خطأ ما دام لا يوجد موقع نوجّه إليه.
  ///
  /// عند النجاح تُنشأ الجلسة فوراً ويعيد الموجّه التوجيه تلقائياً.
  Future<void> verifyEmailOtp({
    required String email,
    required String token,
  }) async {
    await _sb.auth.verifyOTP(
      type: OtpType.signup,
      email: email.trim(),
      token: token.trim(),
    );
  }

  // ---------------------------------------------------------------------------
  // الوثائق
  // ---------------------------------------------------------------------------
  /// يرفع صورة ثم يسجّلها عبر دالة القاعدة.
  ///
  /// **اصطلاح المسار إلزامي:** `<user_id>/<doc_type>_<timestamp>.jpg`
  /// سياسات التخزين تقارن أول جزء منه بـ auth.uid()، وأي مسار آخر يُرفض.
  Future<void> uploadDocument({
    required File file,
    required String docType,
  }) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) throw StateError('لا توجد جلسة');

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '$uid/${docType}_$stamp.jpg';

    await _sb.storage.from('documents').upload(
          path,
          file,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );

    // submit_document تعرف الفرق: صور الدراجة تتراكم، وغيرها يُستبدل.
    await _sb.rpc('submit_document', params: {
      'p_doc_type': docType,
      'p_storage_path': path,
    });
  }

  /// الوثائق المرفوعة وحالة مراجعة كل منها.
  Future<List<Map<String, dynamic>>> myDocuments() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return const [];

    final rows = await _sb
        .from('user_documents')
        .select('doc_type, status, review_notes, created_at')
        .eq('user_id', uid);
    return List<Map<String, dynamic>>.from(rows);
  }
}

/// حالة الوثائق المرفوعة — تُستعمل في شاشة الرفع وشاشة الانتظار.
final myDocumentsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(sessionProvider);
  return ref.watch(authRepositoryProvider).myDocuments();
});

/// سياسة التوثيق وحالتي فيها — في نداءٍ واحد.
///
/// **ولماذا من القاعدة لا من الكود؟** لأن التوثيق يمرّ بطرفٍ ثالث: رصيدٌ
/// ينفد، أو خدمةٌ تتوقف، أو شبكةٌ تحجبها. وشرطٌ مثبّتٌ في الكود يجعل
/// عطلاً عند غيرنا يُقفل التطبيق على كل مستخدم جديد — ولا فتح إلا
/// ببناءٍ ونشرٍ ومراجعةِ متجر تستغرق يوماً. والمفتاح في اللوحة يجعل
/// الإطفاء ثانيةً. انظر 0063.
/// هل خرج المستخدم لتوّه من شاشة التسجيل؟
///
/// **بوابة الرمز مربوطةٌ بهذه لا بلحظةِ نداءٍ واحد.** كانت شاشة التسجيل
/// تسأل القاعدة عن الوضع مرةً واحدة ثم تقرّر؛ والنداء يقع في أبطأ لحظة
/// — بعد إنشاء الحساب مباشرةً — فإن تأخّر أو فشل خرج `mode` فارغاً
/// ومضى المستخدم بلا رمز. ونجاحه كان حظاً لا منطقاً.
///
/// أما الراية فيقرؤها الموجّه في **كل** تقييم، ويعيد التقييم كلما وصلت
/// بيانات التوثيق. فتأخّرُ الشبكة يؤجّل الشاشة ثوانيَ ولا يُلغيها.
///
/// وتُرفع عند التسجيل وحده وتُخفض بعد التوثيق أو التخطّي — فلا تعود
/// حاجزاً على كل دخول، وهو ما أزلناه عمداً من قبل.
class JustSignedUp extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// رسالة الدخول الأخيرة — **خارج الشاشة لا داخلها.**
///
/// حين يدخل حسابٌ من النوع الخطأ (راكبٌ في تطبيق السائق)، يُنشئ الدخول
/// جلسةً فينقل الموجّه المستخدم بعيداً، ثم يُخرجه الحارس فيعيده إلى شاشة
/// دخولٍ **جديدة**. والرسالة كانت في حالة الشاشة القديمة التي أُتلفت —
/// فيرى المستخدم ترميشاً ولا شيء. هنا تبقى حتى تقرأها الشاشة الجديدة.
class AuthNotice extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? value) => state = value;
}

final authNoticeProvider =
    NotifierProvider<AuthNotice, String?>(AuthNotice.new);

final justSignedUpProvider =
    NotifierProvider<JustSignedUp, bool>(JustSignedUp.new);

/// يفحص نوع الحساب في **كل جلسة** لا عند الدخول وحده.
///
/// **لأن الإصلاح لا يطرد من دخل قبله.** جلسةٌ أُنشئت بحسابٍ من النوع
/// الخطأ تبقى محفوظة على الجهاز، ويفتح صاحبها التطبيق غداً فيدخل كما
/// كان — والفحص عند الدخول لا يمرّ عليه أبداً.
final roleGuardProvider = FutureProvider<void>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return;
  try {
    await ref.read(authRepositoryProvider).assertRole(session.user.id);
  } catch (_) {
    // الخروج تمّ داخل الفحص؛ والاستثناء هنا لا مستمع له.
  }
});

final verificationProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  if (ref.watch(sessionProvider) == null) return const {};
  try {
    final v = await ref.watch(supabaseProvider).rpc('my_verification');
    return (v as Map).cast<String, dynamic>();
  } catch (_) {
    // **الشك يُفسَّر لصالح المستخدم.** تعذّرت القراءة؟ لا نحجزه.
    return const {};
  }
});

/// هل يجب توثيق الهاتف الآن؟
bool phoneGateOpen(Map<String, dynamic> v) =>
    v['mode'] == 'phone' &&
    v['otp_enabled'] == true &&
    v['phone'] != true;
