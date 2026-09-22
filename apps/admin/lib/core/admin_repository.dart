import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'shell_push.dart';

import 'text.dart';

final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

final sessionProvider = Provider<Session?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentSession;
});

/// هل المستخدم الحالي مدير؟
///
/// **هذا فحص عرض لا فحص أمان.** الحماية الفعلية في سياسات RLS: مستخدم
/// عادي يفتح اللوحة لن يرى صفاً واحداً مهما فعل، لأن كل استعلام يمرّ
/// على `public.is_admin()` في القاعدة.
///
/// نفحص هنا لنعرض رسالة مفهومة بدل جداول فارغة محيّرة.
final isAdminProvider = FutureProvider<bool>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return false;

  final row = await ref
      .watch(supabaseProvider)
      .from('profiles')
      .select('role')
      .eq('id', session.user.id)
      .maybeSingle();

  return row?['role'] == 'admin';
});

/// السائقون المنتظرون مراجعة، مع بياناتهم وعدد وثائقهم.
final pendingDriversProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(sessionProvider);
  return ref.watch(adminRepositoryProvider).driversByStatus('pending');
});

/// شارة «المتاجر» في القائمة الجانبية.
final storesAwaitingProvider = FutureProvider<int>((ref) async {
  ref.watch(sessionProvider);
  try {
    return await ref.watch(adminRepositoryProvider).storesAwaiting();
  } catch (_) {
    return 0; // قاعدةٌ بلا 0092 — لا نُسقط القائمة الجانبية بسبب شارة
  }
});

final allDriversProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(sessionProvider);
  return ref.watch(adminRepositoryProvider).driversByStatus(null);
});

/// كم طلب تعديل ينتظر المراجعة — للشارة في القائمة الجانبية.
///
/// الرقم على الأيقونة هو ما يجعل الطلب يُرى؛ صفحةٌ لا شارة عليها لا
/// يفتحها أحد إلا مصادفةً.
final pendingChangeCountProvider = FutureProvider<int>((ref) async {
  ref.watch(sessionProvider);
  return ref.watch(adminRepositoryProvider).pendingChangeCount();
});

/// يوحّد نصّ البحث قبل إرساله.
///
/// **العطل الذي أصلحه.** الأرقام تُخزَّن دولية `+9647801711922`، والمدير
/// يكتبها كما يعرفها `07801711922`. و`ilike '%07801711922%'` لا يطابق
/// الأول: بعد `964` يأتي `7` لا `0`. فكان البحث يردّ «لا نتائج» عن رقمٍ
/// موجود — ويقف المدير أمام تسجيلٍ يقول «الرقم مسجَّل» ولوحةٍ تقول لا.
///
/// فنقصّ الصفر أو `964` ونبحث بالجزء المشترك بين الصيغتين.
String normalizePhoneQuery(String raw) {
  final t = raw.trim();
  final digits = t.replaceAll(RegExp(r'[^0-9]'), '');

  // ليس رقماً — اسمٌ أو بريد، يُرسل كما هو.
  if (digits.isEmpty || digits.length != t.replaceAll(' ', '').length) {
    return t;
  }

  if (digits.startsWith('00964')) return digits.substring(5);
  if (digits.startsWith('964'))   return digits.substring(3);
  if (digits.startsWith('0'))     return digits.substring(1);
  return digits;
}

/// نتائج البحث في السائقين. النص المفتاح لا الحالة: البحث يشمل الجميع
/// معتمَدين وغيرَهم، فمن يسأل عن سائق بالاسم لا يعرف حالته سلفاً.
final driverSearchProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, q) => ref.watch(adminRepositoryProvider).searchDrivers(query: q),
);

/// صفّ سائق واحد محدَّثاً من القاعدة.
///
/// **لماذا لا نكتفي بالصف الممرَّر إلى الصفحة؟** لأنه لقطة وقت الفتح.
/// بعد تعبئة رصيد أو إيقاف يبقى معروضاً كما كان، فيظنّ المدير أن الفعل
/// لم ينفّذ ويكرّره — والتكرار في التعبئة مالٌ يُدفع مرتين.
final driverRowProvider =
    FutureProvider.family<Map<String, dynamic>?, String>(
        (ref, driverId) async {
  return ref.watch(adminRepositoryProvider).driverById(driverId);
});

/// وثائق سائق معيّن.
final driverDocumentsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
        (ref, driverId) async {
  return ref.watch(adminRepositoryProvider).documentsOf(driverId);
});

/// نتائج البحث في الركّاب. النص المفتاح لا الحالة — كما في السائقين.
final riderSearchProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, q) => ref.watch(adminRepositoryProvider).searchRiders(query: q),
);

/// صفّ راكب واحد محدَّثاً من القاعدة.
///
/// **لماذا لا نكتفي بالصف الممرَّر؟** لأنه لقطة وقت الفتح. بعد تعديل
/// اسم أو إيقاف يبقى معروضاً كما كان، فيظنّ المدير أن الفعل لم ينفّذ.
final riderRowProvider =
    FutureProvider.family<Map<String, dynamic>?, String>(
        (ref, id) => ref.watch(adminRepositoryProvider).riderById(id));

/// رحلات راكب معيّن.
final riderTripsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
        (ref, id) => ref.watch(adminRepositoryProvider).riderTrips(id));

/// الرحلات الجارية الآن — تُحدَّث لحظياً.
final liveTripsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  const live = {'searching', 'accepted', 'driver_arrived', 'in_progress'};

  return ref
      .watch(supabaseProvider)
      .from('trips')
      .stream(primaryKey: ['id'])
      .order('requested_at', ascending: false)
      .limit(50)
      .map((rows) =>
          rows.where((r) => live.contains(r['status'])).toList());
});

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.watch(supabaseProvider)),
);

class AdminRepository {
  AdminRepository(this._sb);

  final SupabaseClient _sb;

  Future<void> signIn({required String email, required String password}) =>
      _sb.auth.signInWithPassword(email: email.trim(), password: password);

  Future<void> signOut() async {
    await ShellPush.unregister(_sb);
    await _sb.auth.signOut();
  }

  // ---------------------------------------------------------------------------
  // السائقون
  // ---------------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> driversByStatus(String? status) async {
    var q = _sb.from('drivers').select(
        'id, status, verification_status, vehicle_kind, vehicle_type, '
        'vehicle_plate, '
        'vehicle_color, '
        'wallet_balance_iqd, rating_avg, trips_completed, created_at, '
        'profiles!inner(full_name, phone, email, address, date_of_birth, '
        'is_blocked)');

    if (status != null) q = q.eq('verification_status', status);

    final rows = await q.order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// صفّ سائق واحد بحالته ورصيده الآن.
  Future<Map<String, dynamic>?> driverById(String id) async {
    final rows = await _sb.from('drivers').select(
        'id, status, verification_status, vehicle_kind, vehicle_type, '
        'vehicle_plate, '
        'vehicle_color, wallet_balance_iqd, rating_avg, rating_count, '
        'trips_completed, trips_cancelled, created_at, rejection_reason, '
        'profiles!inner(full_name, phone, email, address, date_of_birth, '
        'is_blocked)').eq('id', id).limit(1);
    return (rows as List).isEmpty
        ? null
        : Map<String, dynamic>.from(rows.first as Map);
  }

  Future<List<Map<String, dynamic>>> documentsOf(String driverId) async {
    final rows = await _sb
        .from('user_documents')
        .select('id, doc_type, status, storage_path, review_notes, created_at')
        .eq('user_id', driverId)
        .order('doc_type');
    return List<Map<String, dynamic>>.from(rows);
  }

  /// رابط موقّت لعرض صورة من البكت الخاص.
  ///
  /// البكت خاص فلا رابط مباشر يعمل. نطلب رابطاً موقّعاً صالحاً ساعة —
  /// كافٍ للمراجعة، وقصير بما يمنع تسريب رابط دائم لصورة بطاقة وطنية.
  Future<String> signedUrl(String storagePath) =>
      _sb.storage.from('documents').createSignedUrl(storagePath, 3600);

  /// قبول أو رفض وثيقة.
  ///
  /// **لا نلمس `drivers.verification_status` مباشرة.** المُشغّل
  /// `recompute_verification` يحسبها من حالة الوثائق، وأي كتابة يدوية
  /// عليها يمحوها أول تحديث وثيقة. نغيّر الوثيقة، وهو يتولى الباقي.
  Future<void> reviewDocument({
    required String documentId,
    required bool approve,
    String? notes,
  }) async {
    await _sb.from('user_documents').update({
      'status': approve ? 'approved' : 'rejected',
      'review_notes': notes,
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
      'reviewed_by': _sb.auth.currentUser?.id,
    }).eq('id', documentId);
  }

  /// قبول كل وثائق سائق دفعة واحدة.
  Future<void> approveAll(String driverId) async {
    await _sb.from('user_documents').update({
      'status': 'approved',
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
      'reviewed_by': _sb.auth.currentUser?.id,
    }).eq('user_id', driverId);
  }

  /// إلغاء اعتماد سائق أو إعادته.
  ///
  /// **دالة لا كتابة مباشرة.** الكتابة على `drivers.verification_status`
  /// كان يمحوها مُشغّل الوثائق عند أول تعديل على وثيقة — فيعود الموقوف
  /// معتمَداً في صمت. الدالة تثبّت القرار وتسجّله في سجلّ التدقيق.
  Future<void> setApproved(String driverId, bool approved,
          {String? reason}) =>
      _sb.rpc('admin_set_driver_approval', params: {
        'p_driver_id': driverId,
        'p_approved': approved,
        'p_reason': reason,
      });

  /// توقيف مؤقت عن استلام الطلبات — بلا مساس بالاعتماد.
  ///
  /// **الفرق عن إلغاء الاعتماد:** هذا يُخرج السائق من دائرة العروض ويبقي
  /// وثائقه معتمدة، فرفعه بضغطة ولا يعيده إلى دورة المراجعة. يصلح
  /// للشكوى قيد التحقيق، أو للدين المتراكم، أو لمن يرفض الرحلات.
  Future<void> setBlocked(String driverId, bool blocked, {String? reason}) =>
      _sb.rpc('admin_set_driver_blocked', params: {
        'p_driver_id': driverId,
        'p_blocked': blocked,
        'p_reason': reason,
      });

  /// تعبئة رصيد السائق مباشرة. تعيد الرصيد بعد التعبئة.
  ///
  /// **لا نكتب الرصيد بل نسجّل حركة.** الرصيد مشتقّ من سجلّ الحركات،
  /// وكتابته يدوياً تُنتج رقماً لا يفسّره شيء حين يسأل السائق عنه.
  /// يعدّل رصيد سائق أو راكب — إضافةً أو خصماً، فعليّاً أو هديةً.
  ///
  /// **يسأل عن النوع ولا يخمّنه.** حقنٌ بلا تحديد يجعل كل مبلغ قابلاً
  /// للسحب افتراضاً، فتخرج الهدية نقداً من الخزينة بلا أن يلاحظ أحد.
  ///
  /// `expiresDays` للهدية وحدها وللراكب وحده — وما دفع ثمنه لا ينتهي.
  ///
  /// يعيد `{real, bonus}` بعد التعديل.
  Future<({num real, num bonus})> adjustBalance({
    required String userId,
    required bool isDriver,
    required num amount,
    required bool isBonus,
    required String note,
    int? expiresDays,
  }) async {
    final v = await _sb.rpc(
      isDriver ? 'admin_adjust_balance' : 'admin_adjust_rider_balance',
      params: {
        isDriver ? 'p_driver_id' : 'p_rider_id': userId,
        'p_amount': amount,
        'p_kind': isBonus ? 'bonus' : 'real',
        'p_note': note,
        if (!isDriver) 'p_expires_days': expiresDays,
      },
    );
    final m = (v as Map).cast<String, dynamic>();
    return (
      real: (m['real'] as num?) ?? 0,
      bonus: (m['bonus'] as num?) ?? 0,
    );
  }

  /// سجلّ حركات الرصيد — الفعليّ والهدية معاً، الأحدث أولاً.
  Future<List<Map<String, dynamic>>> balanceEntries(String userId) async {
    final rows = await _sb
        .from('balance_entries')
        .select()
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .limit(100);
    return rows.cast<Map<String, dynamic>>();
  }

  /// رصيد راكب. يعيد `null` إن لم تُنشأ محفظته بعد.
  Future<Map<String, dynamic>?> riderWallet(String riderId) async {
    final row = await _sb
        .from('rider_wallets')
        .select()
        .eq('id', riderId)
        .maybeSingle();
    return row;
  }

  Future<num> topupDriver({
    required String driverId,
    required int amount,
    String? note,
  }) async {
    final v = await _sb.rpc('admin_topup_driver', params: {
      'p_driver_id': driverId,
      'p_amount': amount,
      'p_note': note,
    });
    return (v as num?) ?? 0;
  }

  // ---------------------------------------------------------------------------
  // المحفظة
  // ---------------------------------------------------------------------------
  /// تسجيل تسديد نقدي من سائق.
  ///
  /// المبلغ موجب لأنه إضافة لرصيده — يعيده نحو الصفر بعد أن راكمت
  /// العمولات ديناً عليه.
  Future<void> recordPayment({
    required String driverId,
    required double amount,
    String? note,
  }) =>
      _sb.rpc('post_wallet_transaction', params: {
        'p_driver_id': driverId,
        'p_txn_type': 'topup',
        'p_amount_iqd': amount,
        'p_description': note ?? 'تسديد نقدي',
        'p_created_by': _sb.auth.currentUser?.id,
      });

  Future<List<Map<String, dynamic>>> walletOf(String driverId) async {
    final rows = await _sb
        .from('wallet_transactions')
        .select('txn_type, amount_iqd, balance_after_iqd, description, created_at')
        .eq('driver_id', driverId)
        .order('created_at', ascending: false)
        .limit(100);
    return List<Map<String, dynamic>>.from(rows);
  }

  // ---------------------------------------------------------------------------
  // رموز التعبئة
  // ---------------------------------------------------------------------------

  /// يولّد دفعة رموز ويعيدها. القاعدة تولّدها بمصدر تعمية حقيقي —
  /// رمزٌ يُخمَّن هو مالٌ يُسرَق.
  Future<List<Map<String, dynamic>>> generateCodes({
    required int count,
    required int amount,
    String? note,
    String? transId,
  }) async {
    final rows = await _sb.rpc('generate_topup_codes', params: {
      'p_count': count,
      'p_amount': amount,
      'p_note': note,
      // **رقم عملية زين كاش** — القاعدة تطبّعه وترفض المستعمل (0102).
      'p_trans_id': transId,
    });
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// هل رقم العملية مستعمل؟ لتقول اللوحة «مستخدم» والبائع ما زال يكتب،
  /// لا بعد أن يضغط «توليد».
  Future<Map<String, dynamic>> checkTransId(String transId) async {
    final v = await _sb.rpc('check_trans_id', params: {'p_trans_id': transId});
    return Map<String, dynamic>.from(v as Map);
  }

  Future<List<Map<String, dynamic>>> topupCodes({
    bool? used,
    String query = '',
  }) async {
    // نضمّ ملف من استهلك الرمز: "استُعمل" وحدها لا تكفي حين يسأل سائق
    // عن رمز أرسلناه إليه فوجدناه مستهلَكاً.
    //
    // **قفزتان لا واحدة.** `redeemed_by` يشير إلى `drivers` لا إلى
    // `profiles`، والاسم في `profiles`. طلبُه من `profiles` مباشرةً كان
    // يردّ خطأ PGRST200 — فتبقى الصفحة على دوّارة التحميل أبداً، ويبدو
    // التوليد كأنه فشل وهو قد نجح.
    var q = _sb.from('topup_codes').select(
        'id, code, amount_iqd, batch_note, created_at, redeemed_at, '
        'redeemed_by, is_void, trans_id, '
        'redeemer:drivers!topup_codes_redeemed_by_fkey('
        'profile:profiles(full_name, phone)), '
        // **من ولّد.** الرمز مالٌ، ومن أصدره يجب أن يُعرف — خصوصاً حين
        // يولّد أكثر من موظف.
        'creator:profiles!topup_codes_created_by_fkey(full_name)');
    if (used == true) q = q.not('redeemed_by', 'is', null);
    if (used == false) q = q.filter('redeemed_by', 'is', null);

    final term = normalizePhoneQuery(query);
    if (term.isNotEmpty) {
      // أرقام عربية أو هندية، بفواصل أو بدونها: نجرّدها إلى خانات لاتينية
      // قبل المطابقة. المدير ينسخ الرمز كما عُرض له مجزّأً بمسافات.
      final digits = normalizeDigits(term).replaceAll(RegExp(r'[^0-9]'), '');
      q = digits.isEmpty
          ? q.ilike('batch_note', '%$term%')
          // ورقم عملية زين كاش — حين يسأل سائق: «هل شُحن وصلي؟».
          : q.or('code.ilike.%$digits%,trans_id.ilike.%$digits%,'
              'batch_note.ilike.%$term%');
    }

    final rows = await q.order('created_at', ascending: false).limit(300);
    return List<Map<String, dynamic>>.from(rows);
  }

  // ---------------------------------------------------------------------------
  // التقييمات
  // ---------------------------------------------------------------------------

  /// آخر تقييمات شخصٍ واحد — سائقاً كان أو راكباً.
  ///
  /// **المتوسّط وحده لا يُصلح شيئاً.** سائقٌ هبط إلى ٢.٨: لماذا؟ بلا
  /// التقييمات نفسها لا المدير يعرف فيُصلح ولا السائق يعرف فيتغيّر.
  Future<List<Map<String, dynamic>>> userRatings(String userId,
      {int limit = 30}) async {
    final rows = await _sb.rpc('admin_user_ratings',
        params: {'p_user_id': userId, 'p_limit': limit});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// الأكثر اختياراً في آخر خمسين تقييماً.
  Future<List<Map<String, dynamic>>> ratingTagSummary(String userId) async {
    final rows =
        await _sb.rpc('rating_tag_summary', params: {'p_user_id': userId});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// تقييما رحلةٍ واحدة — متقابلين.
  ///
  /// **خلافُ رحلةٍ لا يُفهم من طرف.** من يقرأ شكوى الراكب وحدها يحكم
  /// قبل أن يسمع السائق.
  Future<List<Map<String, dynamic>>> tripRatings(String tripId) async {
    final rows =
        await _sb.rpc('admin_trip_ratings', params: {'p_trip_id': tripId});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// تصفير اللوحة — نقطة صفرٍ لا حذف.
  ///
  /// **البيانات تبقى.** نضبط تاريخاً تعدّ اللوحة ما بعده وحده، فمن
  /// صفّر بالخطأ يتراجع بضغطة، وتبقى الرحلات لأصحابها والمحاسبة ممكنة.
  Future<void> resetDashboard(String code) =>
      _sb.rpc('admin_reset_dashboard', params: {'p_code': code});

  Future<void> undoDashboardReset(String code) =>
      _sb.rpc('admin_undo_dashboard_reset', params: {'p_code': code});

  /// صفوف الرحلات للتصدير — لا ملخّص.
  ///
  /// **من ينزّل الأرقام يريد أن يحسبها بنفسه.** والملخّص يعطيه ما رآه
  /// في الشاشة، فلا معنى لتنزيله.
  Future<List<Map<String, dynamic>>> exportTrips(String code) async {
    final rows = await _sb.rpc('admin_export_trips', params: {'p_code': code});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// أرقام اللوحة في نداءٍ واحد.
  ///
  /// **دالة لا استعلامات.** خمسة تجميعات من ثلاثة جداول، ولو جمعناها
  /// في الواجهة لصارت خمس رحلات شبكة تُعرض متفرّقةً كلما وصلت واحدة.
  Future<Map<String, dynamic>> dashboard() async {
    final v = await _sb.rpc('admin_dashboard');
    return (v as Map).cast<String, dynamic>();
  }

  /// **بدالة لا تعديلٍ مباشر.** الجدول لم يعد يُكتب من اللوحة (0099)،
  /// والدالة تفحص الصلاحية وتُسجّل من أبطل.
  Future<void> voidCode(String id) =>
      _sb.rpc('admin_void_topup_code', params: {'p_id': id});

  /// حذف رمزٍ مستهلك أو مُلغى.
  ///
  /// **بدالة لا حذفٍ مباشر.** السياسة تسمح للمشرف بالحذف أصلاً، لكن
  /// المباشر يمرّ بلا سجلّ — والمال لا يُمسّ بلا أثر. والدالة ترفض
  /// حذف رمزٍ ما زال صالحاً: قد يكون في هاتف سائق ينتظر أن يعبّئ به.
  Future<void> deleteCode(String id) =>
      _sb.rpc('admin_delete_topup_code', params: {'p_id': id});

  /// كنس المستهلكة والملغاة دفعةً، ويعيد كم حُذف.
  ///
  /// **لأن الحذف واحداً واحداً لا يُنجَز.** من عنده أربعمئة رمزٍ ميت
  /// لن يضغط أربعمئة مرة، فيترك الجدول كما هو.
  Future<int> purgeCodes({bool used = true, bool voided = true}) async {
    final v = await _sb.rpc('admin_purge_topup_codes',
        params: {'p_used': used, 'p_void': voided});
    return (v as num).toInt();
  }

  // ---------------------------------------------------------------------------
  // طلبات تعديل البيانات
  // ---------------------------------------------------------------------------

  /// طلبات تعديل البيانات بحالة معيّنة، مع ملف صاحبها.
  Future<List<Map<String, dynamic>>> changeRequests(String status) async {
    final rows = await _sb
        .from('profile_change_requests')
        .select('*, profile:profiles!profile_change_requests_user_id_fkey('
            'full_name, phone, role)')
        .eq('status', status)
        .order('created_at', ascending: false)
        .limit(200);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// عدد ما ينتظر المراجعة — للشارة على أيقونة القائمة.
  Future<int> pendingChangeCount() async {
    final rows = await _sb
        .from('profile_change_requests')
        .select('id')
        .eq('status', 'pending');
    return (rows as List).length;
  }

  /// **الموافقة تطبّق التغيير في القاعدة، لا في الواجهة.** الدالة تكتب
  /// على `profiles` و`drivers` وتتجاوز حارس الملف الشخصي، لأن هذا تعديل
  /// وافق عليه إنسان لا محاولة من التطبيق.
  Future<void> reviewChangeRequest({
    required String id,
    required bool approve,
    String? note,
  }) =>
      _sb.rpc('admin_review_profile_change', params: {
        'p_id': id,
        'p_approve': approve,
        'p_note': note,
      });

  // ---------------------------------------------------------------------------
  // طلبات السحب
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> payoutRequests(
    String? status, {
    String query = '',
  }) async {
    var q = _sb.from('payout_requests').select(
        '*, drivers!inner(wallet_balance_iqd, '
        'profiles!inner(full_name, phone))');
    if (status != null) q = q.eq('status', status);

    final term = normalizePhoneQuery(query);
    if (term.isNotEmpty) {
      q = q.or('full_name.ilike.%$term%,phone.ilike.%$term%',
          referencedTable: 'drivers.profiles');
    }

    final rows = await q.order('requested_at', ascending: false).limit(200);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// إعلان الدفع. **الخصم يحدث هنا لا وقت الطلب** — الطلب نيّة والدفع فعل.
  Future<void> markPayoutPaid(String id, {String? note}) =>
      _sb.rpc('mark_payout_paid', params: {'p_id': id, 'p_note': note});

  Future<void> rejectPayout(String id, String note) =>
      _sb.rpc('reject_payout_request', params: {'p_id': id, 'p_note': note});

  // ---------------------------------------------------------------------------
  // الإعدادات العامة
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> settings() async {
    final rows = await _sb.from('public_settings').select().order('key');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> saveSetting(String key, String value) =>
      _sb.from('public_settings').update({
        'value': value,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'updated_by': _sb.auth.currentUser?.id,
      }).eq('key', key);

  // ---------------------------------------------------------------------------
  // الكوبونات
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> coupons() async {
    final rows = await _sb
        .from('coupons')
        .select('*, creator:profiles!coupons_created_by_fkey(full_name)')
        .order('created_at', ascending: false)
        .limit(200);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> createCoupon({
    required String code,
    required int discountPct,
    required int maxUsesPerRider,
    DateTime? validUntil,
    String? note,
  }) =>
      _sb.from('coupons').insert({
        'code': code.trim(),
        'discount_pct': discountPct,
        'max_uses_per_rider': maxUsesPerRider,
        'valid_until': validUntil?.toUtc().toIso8601String(),
        'audience': 'all_riders',
        'note': note,
        'created_by': _sb.auth.currentUser?.id,
      });

  /// إيقاف الكوبون لا حذفه: الرحلات التي استعملته تشير إليه، وحذفه يقطع
  /// أثرها فلا نعرف لاحقاً لماذا دفع راكبٌ أقل.
  Future<void> setCouponActive(String id, bool active) =>
      _sb.from('coupons').update({'is_active': active}).eq('id', id);

  /// كم مرة استُعمل كل كوبون — للوحة وحدها.
  Future<Map<String, int>> couponUsage() async {
    final rows = await _sb.from('coupon_redemptions').select('coupon_id');
    final out = <String, int>{};
    for (final r in rows as List) {
      final k = '${r['coupon_id']}';
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // البحث والتفاصيل
  // ---------------------------------------------------------------------------

  /// السائقون مع بحث بالاسم أو الهاتف.
  ///
  /// **البحث على الجدول المرتبط لا على `drivers`:** الاسم والهاتف في
  /// `profiles`، و`!inner` تجعل الربط شرطاً لا زينة فيصحّ الفلتر عليه.
  Future<List<Map<String, dynamic>>> searchDrivers({
    String? status,
    String query = '',
  }) async {
    var q = _sb.from('drivers').select(
        'id, status, verification_status, vehicle_kind, vehicle_type, '
        'vehicle_plate, '
        'vehicle_color, wallet_balance_iqd, rating_avg, rating_count, '
        'trips_completed, trips_cancelled, created_at, '
        'profiles!inner(full_name, phone, email, address, date_of_birth, '
        'is_blocked)');

    if (status != null) q = q.eq('verification_status', status);

    final term = query.trim();
    if (term.isNotEmpty) {
      q = q.or('full_name.ilike.%$term%,phone.ilike.%$term%',
          referencedTable: 'profiles');
    }

    final rows = await q.order('created_at', ascending: false).limit(100);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> driverTrips(String driverId) async {
    final rows = await _sb
        .from('trips')
        .select()
        .eq('driver_id', driverId)
        .order('requested_at', ascending: false)
        .limit(100);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> driverPayouts(String driverId) async {
    final rows = await _sb
        .from('payout_requests')
        .select()
        .eq('driver_id', driverId)
        .order('requested_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// رموز التعبئة التي استهلكها سائق بعينه، بتواريخها.
  Future<List<Map<String, dynamic>>> driverTopups(String driverId) async {
    final rows = await _sb
        .from('topup_codes')
        .select('id, code, amount_iqd, batch_note, redeemed_at, created_at')
        .eq('redeemed_by', driverId)
        .order('redeemed_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// الرحلات: الجارية وحدها أو الكل، بصفحات وبحث.
  ///
  /// **صفحات لا قائمة واحدة.** سجل الرحلات ينمو بلا حدّ، وجلبُه كاملاً
  /// يبطئ اللوحة اليوم ويُسقطها بعد شهر.
  Future<List<Map<String, dynamic>>> trips({
    required bool liveOnly,
    String query = '',
    int page = 0,
    int pageSize = 50,
    String kind = '',
  }) async {
    // أعمدة بالاسم لا `*`: نجمة على `trips` تجرّ ثلاثة أعمدة geography
    // (الانطلاق والوجهة والمسار المخطَّط) بصيغة WKB طويلة لا تُقرأ ولا
    // تُعرض — خمسون صفاً منها على شبكة هاتف تأخير محسوس بلا مقابل.
    // صفحة التفاصيل وحدها تطلب الصف كاملاً، وهي صفٌّ واحد.
    var q = _sb.from('trips').select(
        'id, trip_number, status, pickup_address, dropoff_address, '
        'fare_final_iqd, fare_estimated_iqd, stop_count, has_stopover, '
        'coupon_id, requested_at, kind, vehicle_kind, shop_name, '
        'driver:drivers(profile:profiles(full_name, phone)), '
        'rider:profiles!trips_rider_id_fkey(full_name, phone)');

    if (liveOnly) {
      q = q.inFilter('status',
          ['searching', 'accepted', 'driver_arrived', 'in_progress']);
    }
    if (kind.isNotEmpty) q = q.eq('kind', kind);

    final term = query.trim();
    if (term.isNotEmpty) {
      // الرقم أولاً: من يكتب «10432» أو «#10432» يقصد رحلةً بعينها لا
      // عنواناً. ونجرّد الأرقام العربية قبل المحاولة.
      final n = int.tryParse(normalizeDigits(term).replaceAll('#', '').trim());
      q = n != null
          ? q.eq('trip_number', n)
          : q.or('pickup_address.ilike.%$term%,dropoff_address.ilike.%$term%');
    }

    final from = page * pageSize;
    final rows = await q
        .order('requested_at', ascending: false)
        .range(from, from + pageSize - 1);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<Map<String, dynamic>?> tripDetail(String tripId) async {
    final rows = await _sb
        .from('trips')
        .select('*, driver:drivers(profile:profiles(full_name, phone)), '
            'rider:profiles!trips_rider_id_fkey(full_name, phone), '
            'coupon:coupons(code, discount_pct)')
        .eq('id', tripId)
        .limit(1);
    return (rows as List).isEmpty
        ? null
        : Map<String, dynamic>.from(rows.first as Map);
  }

  Future<List<Map<String, dynamic>>> tripStops(String tripId) async {
    final rows = await _sb
        .from('trip_stops')
        .select()
        .eq('trip_id', tripId)
        .order('seq');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> tripChanges(String tripId) async {
    final rows = await _sb
        .from('trip_change_requests')
        .select()
        .eq('trip_id', tripId)
        .order('created_at');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> cancelTrip(String tripId, String reason) =>
      _sb.rpc('admin_cancel_trip',
          params: {'p_trip_id': tripId, 'p_reason': reason});

  // ---------------------------------------------------------------------------
  // طلب المندوب — المتاجر والمستحقات (0091)
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> stores(
      {String? status, String query = ''}) async {
    final rows = await _sb.rpc('admin_list_stores', params: {
      'p_status': status,
      'p_search': query.trim().isEmpty ? null : query.trim(),
    });
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<void> setStoreStatus(String id, String status, {String? reason}) =>
      _sb.rpc('admin_set_store_status', params: {
        'p_store_id': id,
        'p_status': status,
        'p_reason': reason,
      });

  /// اعتماد تعديل متجرٍ معتمد أو رفضه (0092).
  Future<void> reviewStoreChanges(String id, bool approve, {String? reason}) =>
      _sb.rpc('admin_review_store_changes', params: {
        'p_store_id': id,
        'p_approve': approve,
        'p_reason': reason,
      });

  /// ما ينتظر المدير في المتاجر: تسجيلٌ جديد أو تعديلٌ معلّق — للشارة.
  Future<int> storesAwaiting() async {
    final rows = await _sb
        .from('stores')
        .select('id')
        .or('status.eq.pending,pending_changes.not.is.null');
    return (rows as List).length;
  }

  Future<void> deleteStore(String id) =>
      _sb.rpc('admin_delete_store', params: {'p_store_id': id});

  Future<List<Map<String, dynamic>>> settlements({String? status}) async {
    final rows = await _sb.rpc('admin_delivery_settlements',
        params: {'p_status': status});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<void> closeSettlement(String tripId, String note) =>
      _sb.rpc('admin_close_settlement', params: {
        'p_trip_id': tripId,
        'p_note': note.isEmpty ? null : note,
      });

  // ---------------------------------------------------------------------------
  // الموظفون وسجلّ التدقيق
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // الحوافز
  // ---------------------------------------------------------------------------
  /// يعيد {max_active, items} — السقف مع الحوافز (0108).
  Future<Map<String, dynamic>> incentives() async {
    final v = await _sb.rpc('admin_incentives');
    return Map<String, dynamic>.from(v as Map);
  }

  Future<void> setIncentivesMax(int max) =>
      _sb.rpc('admin_set_incentives_max', params: {'p_max': max});

  /// ترتيب السائقين بعدد الطلبات المكتملة في مدّة (0110).
  Future<List<Map<String, dynamic>>> driverLeaderboard({
    required DateTime from,
    DateTime? to,
  }) async {
    final rows = await _sb.rpc('admin_driver_leaderboard', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': (to ?? DateTime.now()).toUtc().toIso8601String(),
    });
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// يوجّه الحافز إلى سائقين بأعيانهم — وقائمةٌ فارغة تعني «للجميع».
  /// يعيد عدد من أُشعِر جديداً.
  Future<int> setIncentiveTargets(String id, List<String> drivers) async {
    final v = await _sb.rpc('admin_set_incentive_targets',
        params: {'p_id': id, 'p_drivers': drivers});
    return (v as num?)?.toInt() ?? 0;
  }

  /// يحفظ الحافز بمستوياته دفعةً واحدة — حافزٌ بلا مستويات لا يصرف شيئاً.
  Future<String> saveIncentive(Map<String, dynamic> data) async {
    final v = await _sb.rpc('admin_save_incentive', params: {'p_data': data});
    return '$v';
  }

  Future<void> setIncentiveActive(String id, bool active) =>
      _sb.rpc('admin_set_incentive_active',
          params: {'p_id': id, 'p_active': active});

  /// يسجّل وصلاً يدوياً — لمالٍ وصل بلا رمزٍ وُلّد له (0111).
  Future<void> addReceipt({
    required String transId,
    required int amount,
    String? note,
  }) =>
      _sb.rpc('admin_add_receipt', params: {
        'p_trans_id': transId,
        'p_amount': amount,
        'p_note': note,
      });

  /// يحذف وصلاً — **يعيده قابلاً للاستعمال**، فله صلاحيته وحده.
  Future<void> deleteReceipt(String transId) =>
      _sb.rpc('admin_delete_receipt', params: {'p_trans_id': transId});

  /// وصولات زين كاش المستعملة — سجلٌّ لا يُحذف منه شيء (0102).
  Future<List<Map<String, dynamic>>> zainReceipts({String query = ''}) async {
    var q = _sb.from('topup_receipts').select(
        'trans_id, amount_iqd, code_count, created_at, note, '
        'creator:profiles!topup_receipts_created_by_fkey(full_name)');
    final term = query.trim();
    if (term.isNotEmpty) q = q.ilike('trans_id', '%$term%');
    final rows = await q.order('created_at', ascending: false).limit(300);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// يُنشئ حساب موظف ويمنحه صلاحياته دفعةً واحدة (0109 — للمالك وحده).
  Future<String> createStaff({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required List<String> permissions,
  }) async {
    final v = await _sb.rpc('admin_create_staff', params: {
      'p_email': email,
      'p_password': password,
      'p_full_name': fullName,
      'p_phone': phone,
      'p_permissions': permissions,
    });
    return '$v';
  }

  Future<bool> isOwner() async => (await _sb.rpc('is_owner')) == true;

  /// صلاحيات المستخدم الحالي. المالك يعود بها كلّها.
  Future<Set<String>> myPermissions() async {
    final v = await _sb.rpc('my_permissions');
    return {for (final c in (v as List? ?? const [])) '$c'};
  }

  Future<List<Map<String, dynamic>>> knownPermissions() async {
    final rows = await _sb.rpc('known_permissions');
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<List<Map<String, dynamic>>> staff() async {
    final rows = await _sb.rpc('staff_list');
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<void> setStaff(String email, List<String> permissions) =>
      _sb.rpc('set_staff',
          params: {'p_email': email, 'p_permissions': permissions});

  Future<void> removeStaff(String id) =>
      _sb.rpc('remove_staff', params: {'p_id': id});

  Future<List<Map<String, dynamic>>> auditLog({String query = ''}) async {
    var q = _sb.from('audit_log').select();
    final term = query.trim();
    if (term.isNotEmpty) {
      q = q.or('summary.ilike.%$term%,actor_name.ilike.%$term%');
    }
    final rows = await q.order('created_at', ascending: false).limit(200);
    return List<Map<String, dynamic>>.from(rows);
  }

  // ---------------------------------------------------------------------------
  // مناطق الخدمة
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> zones() async {
    // نستثني `boundary`: عمود geography يعود بصيغة WKB طويلة لا تُقرأ،
    // وجلبُه لثماني عشرة منطقة حِملٌ بلا فائدة.
    final rows = await _sb
        .from('pricing_zones')
        // كل أرقام الضبط: الصفحة تعرضها وتعدّلها، والاستثناء الوحيد
        // `boundary` — عمود geography يعود بصيغة طويلة لا تُقرأ.
        .select('id, city_name, city_name_ar, is_active, base_fare_iqd, '
            'per_km_iqd, minimum_fare_iqd, commission_rate, '
            'search_radius_m, max_search_radius_m, offer_timeout_s, '
            'offer_round_seconds, max_search_seconds, max_concurrent_offers, '
            'boosted_concurrent_offers, search_boost_pct, '
            'tuktuk_surcharge_pct, second_leg_discount_pct, '
            'stopover_surcharge_pct, stopover_free_minutes, arrival_radius_m, '
            'driver_free_cancels_per_day, driver_cancel_penalty_iqd, '
            'min_wallet_balance_iqd, cancellation_fee_iqd')
        .order('is_active', ascending: false)
        .order('city_name_ar');
    return List<Map<String, dynamic>>.from(rows);
  }

  /// هل وضع المراجعة مشتغل الآن؟
  Future<bool> reviewMode() async {
    final row = await _sb
        .from('public_settings')
        .select('value')
        .eq('key', 'review_mode')
        .maybeSingle();
    final v = '${row?['value'] ?? 'off'}'.trim().toLowerCase();
    return v == 'on' || v == 'true' || v == '1' || v == 'yes';
  }

  /// **مفتاح يفتح الخدمة للعالم كله.** يمرّ بدالة لا بتحديث مباشر، فيُفحص
  /// ويُسجَّل باسم من أداره — مفتاحٌ بهذا الأثر يجب أن يُعرف من تركه
  /// مشتغلاً.
  Future<void> setReviewMode(bool on) =>
      _sb.rpc('set_review_mode', params: {'p_on': on});

  /// دالة لا تحديث مباشر: التفعيل قرار له أثر تجاري، فيمرّ بفحص صلاحية
  /// ويُسجَّل في سجلّ التدقيق.
  Future<void> setZoneActive(String id, bool active) =>
      _sb.rpc('set_zone_active', params: {'p_id': id, 'p_active': active});

  /// يعدّل أرقام المنطقة. القاعدة تحرس قائمة الحقول المسموحة.
  Future<void> setZoneNumbers(String id, Map<String, num> numbers) =>
      _sb.rpc('set_zone_numbers',
          params: {'p_id': id, 'p_numbers': numbers});

  // ---------------------------------------------------------------------------
  // الركّاب
  // ---------------------------------------------------------------------------

  /// قائمة الركّاب بإحصاءاتهم.
  ///
  /// **دالة لا استعلام.** الركّاب صفوف في `profiles`، وسياسات RLS عليها
  /// تمنع أحداً من رؤية غيره. فتحُها للمشرف بسياسة جديدة يوسّع الثغرة
  /// لكل استعلام؛ والدالة تفتح ما نريد وتغلق ما عداه.
  ///
  /// والإحصاءات محسوبة في القاعدة: مئة راكب في طلب واحد بدل مئة طلب.
  Future<List<Map<String, dynamic>>> searchRiders({String query = ''}) async {
    final rows = await _sb.rpc('admin_search_riders', params: {
      'p_query': normalizePhoneQuery(query),
      'p_limit': 200,
    });
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// بطاقة راكب واحد محدَّثةً من القاعدة.
  Future<Map<String, dynamic>?> riderById(String id) async {
    final rows = await _sb.rpc('admin_rider_detail', params: {'p_id': id});
    final list = rows as List;
    return list.isEmpty ? null : Map<String, dynamic>.from(list.first as Map);
  }

  Future<List<Map<String, dynamic>>> riderTrips(String id) async {
    final rows = await _sb.rpc('admin_rider_trips', params: {
      'p_id': id,
      'p_limit': 100,
    });
    return List<Map<String, dynamic>>.from(rows as List);
  }

  // ---------------------------------------------------------------------------
  // تعديل البيانات مباشرةً
  // ---------------------------------------------------------------------------

  /// يعدّل حقول الملف الشخصي — **للراكب والسائق معاً**، فكلاهما صفّ في
  /// `profiles`.
  ///
  /// **ولماذا نسمح به وقد بنينا نظام الطلبات في 0036؟** لأن الطلب يحمي
  /// من تغيير المستخدم لهويته بعد اعتماد وثائقه، ولا يحمي من خطأ إملائي
  /// أدخله المدير نفسه. حاجتان مختلفتان:
  ///
  ///   • المستخدم يريد تغييراً ← طلب يمرّ على إنسان
  ///   • المدير يصلح خطأً     ← تعديل مباشر مسجَّل في التدقيق
  ///
  /// `null` تعني «لا تغيّر هذا الحقل» — فيمرّر النداء ما تغيّر وحده.
  Future<void> updateProfile({
    required String id,
    String? fullName,
    String? phone,
    String? address,
    DateTime? dateOfBirth,
  }) =>
      _sb.rpc('admin_update_profile', params: {
        'p_id': id,
        'p_full_name': fullName,
        'p_phone': phone,
        'p_address': address,
        'p_date_of_birth':
            dateOfBirth?.toIso8601String().split('T').first,
      });

  /// يوقف مستخدماً أو يرفع إيقافه. يعمل على الراكب والسائق.
  Future<void> setProfileBlocked(String id, bool blocked, {String? reason}) =>
      _sb.rpc('admin_set_blocked', params: {
        'p_id': id,
        'p_blocked': blocked,
        'p_reason': reason,
      });

  // ---------------------------------------------------------------------------
  // استبدال الوثائق
  // ---------------------------------------------------------------------------

  /// يرفع ملفاً إلى مجلد المستخدم ثم يسجّله وثيقةً.
  ///
  /// **الرفع ثم التسجيل، لا العكس.** لو سجّلنا الصف أولاً وفشل الرفع
  /// لظهرت في اللوحة وثيقةٌ تفتح على فراغ — وهي أسوأ من غيابها. والقاعدة
  /// تتحقق بنفسها أن الملف موجود قبل أن تقبل المسار.
  ///
  /// **واصطلاح المسار إلزامي:** `<user_id>/<doc_type>_<timestamp>.jpg`
  /// — سياسات التخزين تقارن أول جزء بمعرّف صاحب المجلد.
  Future<void> replaceDocument({
    required String userId,
    required String docType,
    required Uint8List bytes,
    required String extension,
    String? notes,
  }) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '$userId/${docType}_$stamp.$extension';

    await _sb.storage.from('documents').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            contentType: extension == 'png' ? 'image/png' : 'image/jpeg',
          ),
        );

    await _sb.rpc('admin_set_document', params: {
      'p_user_id': userId,
      'p_doc_type': docType,
      'p_storage_path': path,
      'p_notes': notes,
    });
  }

  /// يحذف وثيقة. القاعدة تمنع حذف الصورة الحية — تُستبدل ولا تُحذف،
  /// لأن حذفها يُفرغ `avatar_url` فيفقد الراكب وجه سائقه.
  Future<void> deleteDocument(String documentId) =>
      _sb.rpc('admin_delete_document', params: {'p_id': documentId});

  // ---------------------------------------------------------------------------
  // إنشاء الحسابات
  // ---------------------------------------------------------------------------

  /// يُنشئ حساباً كاملاً ببريد مؤكَّد — بلا رمز ولا انتظار.
  ///
  /// **حالتان تولّدت منهما:** مختبِرون يحتاج كلٌّ منهم حساباً مستقلاً
  /// (القيد `trips_one_active_per_rider` يمنع مشاركة حساب)، وسائق في
  /// الموقف لا يُحسن التسجيل ولا يملك بريداً — يُترك اليوم فيذهب غداً
  /// إلى منافس.
  ///
  /// **ولا تنشئ صفّ `profiles`:** مُشغّل `handle_new_user` يبنيه من
  /// بيانات التسجيل ويفرض القيود نفسها — الاسم الثلاثي وصيغة الهاتف
  /// والعمر الأدنى. مسار واحد للتحقق لا مساران يتباعدان.
  Future<String> createAccount({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required String address,
    required DateTime dateOfBirth,
    required String role,
  }) async {
    final id = await _sb.rpc('admin_create_account', params: {
      'p_email': email.trim(),
      'p_password': password,
      'p_full_name': fullName.trim(),
      'p_phone': phone.trim(),
      'p_address': address.trim(),
      'p_date_of_birth': dateOfBirth.toIso8601String().split('T').first,
      'p_role': role,
    });
    return '$id';
  }

  /// يحذف حساب راكب أو سائق.
  ///
  /// **الحذف نوعان تقرّرهما القاعدة لا الواجهة:**
  ///
  ///   • `purged` — حسابٌ لم يركب قطّ: يُمحى كلياً من نظام الدخول
  ///     ويأخذ معه ملفه ووثائقه. لا أثر يبقى ولا سبب لبقائه.
  ///
  ///   • `anonymized` — حسابٌ له رحلات: يُجهَّل فتُمحى هويته ويبقى
  ///     سجلّ رحلاته ومبالغها. `trips.rider_id` مقيَّد بـ`restrict`،
  ///     والقيد قرار لا عائق: رحلةٌ بلا راكب رقمٌ في دفتر لا يُراجَع،
  ///     ومحوُ سجلّ مالي يُغلق باب المحاسبة على من أراد الهرب.
  ///
  /// **ولا نترك المدير يختار** — الخيار الخاطئ هنا لا رجعة فيه.
  /// **الدالة أولاً ثم الملفات.** حرّاسها قد يرفضون الحذف — رحلة جارية
  /// أو دين مستحق — ولو حذفنا الملفات أولاً لخسر السائق وثائقه ثم بقي
  /// مسجَّلاً. وتعيد مساراتها لأن صفوفها تُمحى معها.
  ///
  /// **والحذف بواجهة التخزين لا بجدولها:** Supabase تمنع الحذف المباشر
  /// من `storage.objects`.
  Future<String> deleteAccount(String id, {String? reason}) async {
    final res = await _sb.rpc('admin_delete_account', params: {
      'p_id': id,
      'p_reason': reason,
    });

    final map = Map<String, dynamic>.from(res as Map);
    final paths = (map['paths'] as List?)?.map((e) => '$e').toList() ?? const [];

    if (paths.isNotEmpty) {
      try {
        await _sb.storage.from('documents').remove(paths);
      } catch (_) {
        // فشل حذف ملف لا يُعيد الحساب. الحساب مُجهَّل فعلاً، وبقاء ملفٍ
        // يتيم أهون من رسالة خطأ توهم المدير أن الحذف لم يتمّ.
      }
    }

    return '${map['result']}';
  }
}

/// محفظة راكب. **تُقرأ على حدة لا مع صفّه** — تُنشأ عند أول منحة، فأكثر
/// الركّاب بلا صفٍّ فيها، ووصلُها بالبحث يجعل كل قراءة تحمل جدولاً فارغاً.
final riderWalletProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, id) =>
        ref.watch(adminRepositoryProvider).riderWallet(id));

/// بطاقة الدعوة لمستخدم — قناة وصوله، ورمزه، ودعواته، **ومن دعاه**.
///
/// الأخيرة هي الأهم عند الشكّ في حساب: سلسلةُ حساباتٍ يدعو بعضها بعضاً
/// أوضحُ إشارةٍ على الاحتيال.
final referralInfoProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final v = await ref.watch(supabaseProvider).rpc(
        'admin_referral_info',
        params: {'p_id': id},
      );
  return (v as Map).cast<String, dynamic>();
});

/// تقرير قنوات الوصول — كم سجّل من كل قناة، **وكم منهم ركب فعلاً**.
final acquisitionReportProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows =
      await ref.watch(supabaseProvider).rpc('admin_acquisition_report');
  return (rows as List).cast<Map<String, dynamic>>();
});

// =============================================================================
// الإشعارات
// =============================================================================

/// القوالب المحفوظة — تُكتب مرة وتُرسل مراراً.
final templatesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('notification_templates')
      .select()
      .order('created_at', ascending: false);
  return rows.cast<Map<String, dynamic>>();
});

/// آخر ما أُرسل — ومعه كم وصل فعلاً.
final sentNotificationsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('notifications')
      .select()
      .order('sent_at', ascending: false)
      .limit(50);
  return rows.cast<Map<String, dynamic>>();
});

/// الجدولات المفعَّلة والمتوقّفة.
final schedulesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('notification_schedules')
      .select('*, notification_templates(title, body)')
      .order('created_at', ascending: false);
  return rows.cast<Map<String, dynamic>>();
});

/// عدد من سيستقبل — **يُقرأ قبل الإرسال لا بعده.**
///
/// رسالةٌ فيها خطأ تصل مئات الهواتف ولا تُسترد، ومن يرى الرقم يقرأ نصّه
/// مرة أخرى قبل أن يضغط.
final audienceCountProvider =
    FutureProvider.family<int, ({String audience, bool approvedOnly})>(
        (ref, a) async {
  final v = await ref.watch(supabaseProvider).rpc(
    'notification_audience_count',
    params: {'p_audience': a.audience, 'p_approved_only': a.approvedOnly},
  );
  return (v as num?)?.toInt() ?? 0;
});

extension NotificationsApi on AdminRepository {
  Future<void> sendBroadcast({
    required String title,
    required String body,
    required String audience,
    bool approvedOnly = false,
  }) =>
      _sb.rpc('send_notification', params: {
        'p_title': title,
        'p_body': body,
        'p_audience': audience,
        'p_approved_only': approvedOnly,
      });

  /// رسالةٌ لشخصٍ واحد — من داخل ملفه.
  Future<void> sendDirect({
    required String userId,
    required String title,
    required String body,
  }) =>
      _sb.rpc('send_notification', params: {
        'p_title': title,
        'p_body': body,
        'p_user_id': userId,
      });

  Future<void> saveTemplate({
    required String title,
    required String body,
    required String audience,
  }) =>
      _sb.from('notification_templates').insert({
        'title': title,
        'body': body,
        'audience': audience,
      });

  Future<void> deleteTemplate(String id) =>
      _sb.from('notification_templates').delete().eq('id', id);

  Future<void> saveSchedule({
    required String templateId,
    required String audience,
    required String frequency,
    required int hour,
    int? weekday,
  }) =>
      _sb.from('notification_schedules').insert({
        'template_id': templateId,
        'audience': audience,
        'frequency': frequency,
        'send_at_hour': hour,
        'weekday': ?weekday,
      });

  Future<void> setScheduleActive(String id, bool active) =>
      _sb.from('notification_schedules').update({'is_active': active}).eq('id', id);

  Future<void> deleteSchedule(String id) =>
      _sb.from('notification_schedules').delete().eq('id', id);
}
