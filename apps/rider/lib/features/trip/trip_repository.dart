import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_repository.dart';

/// حالات الرحلة كما تعرّفها قاعدة البيانات.
///
/// نكرّرها هنا كنوع مُعدَّد بدل تمرير نصوص: الخطأ المطبعي في نص يمرّ
/// صامتاً حتى وقت التشغيل، والنوع المُعدَّد يكشفه وقت الترجمة.
enum TripStatus {
  searching,
  noDrivers,
  accepted,
  driverArrived,
  inProgress,
  completed,
  cancelled;

  static TripStatus parse(String raw) => switch (raw) {
        'searching' => TripStatus.searching,
        'no_drivers' => TripStatus.noDrivers,
        'accepted' => TripStatus.accepted,
        'driver_arrived' => TripStatus.driverArrived,
        'in_progress' => TripStatus.inProgress,
        'completed' => TripStatus.completed,
        'cancelled' => TripStatus.cancelled,
        _ => TripStatus.searching,
      };

  /// هل الرحلة ما زالت جارية؟ يحدد بقاء المستخدم في شاشة المتابعة.
  bool get isLive => this == searching ||
      this == accepted ||
      this == driverArrived ||
      this == inProgress;

  String get label => switch (this) {
        TripStatus.searching => 'جارٍ البحث عن سائق',
        TripStatus.noDrivers => 'لم نجد سائقاً متاحاً',
        TripStatus.accepted => 'السائق في طريقه إليك',
        TripStatus.driverArrived => 'السائق وصل وينتظرك',
        TripStatus.inProgress => 'الرحلة جارية',
        TripStatus.completed => 'وصلت',
        TripStatus.cancelled => 'أُلغيت الرحلة',
      };
}

/// صورة مبسّطة عن الرحلة كما يحتاجها التطبيق.
class Trip {
  Trip.fromRow(Map<String, dynamic> r)
      : id = r['id'] as String,
        number = (r['trip_number'] as num?)?.toInt() ?? 0,
        status = TripStatus.parse(r['status'] as String),
        driverId = r['driver_id'] as String?,
        cancelledBy = r['cancelled_by'] as String?,
        kind = '${r['kind'] ?? 'ride'}',
        fareEstimated = (r['fare_estimated_iqd'] as num?)?.toDouble() ?? 0,
        fareBoostPct = (r['fare_boost_pct'] as num?)?.toInt() ?? 0,
        fareFinal = (r['fare_final_iqd'] as num?)?.toDouble(),
        discount = (r['discount_iqd'] as num?)?.toDouble() ?? 0,
        creditUsed = (r['credit_used_iqd'] as num?)?.toDouble() ?? 0,
        cashDue = (r['cash_due_iqd'] as num?)?.toDouble(),
        goodsEstimate = (r['goods_estimate_iqd'] as num?)?.toDouble(),
        goodsActual = (r['goods_actual_iqd'] as num?)?.toDouble(),
        pickupAddress = r['pickup_address'] as String? ?? '',
        dropoffAddress = r['dropoff_address'] as String? ?? '',
        cancellationFee =
            (r['cancellation_fee_iqd'] as num?)?.toDouble() ?? 0,
        // الأعمدة المحسوبة من 0014 — الموقع الأصلي يعود بصيغة WKB
        // ثنائية لا يفهمها التطبيق.
        pickupLat = (r['pickup_lat'] as num?)?.toDouble(),
        pickupLng = (r['pickup_lng'] as num?)?.toDouble(),
        dropoffLat = (r['dropoff_lat'] as num?)?.toDouble(),
        dropoffLng = (r['dropoff_lng'] as num?)?.toDouble();

  final String id;
  final int number;
  final TripStatus status;
  final String? driverId;

  /// `ride` أو `shopping`. **مراحل التسوّق ليست مراحل الرحلة**، فنصوص
  /// الإشعارات تختلف باختلافه.
  final String kind;

  bool get isShopping => kind == 'shopping';

  /// من ضغط زرّ الإلغاء. **يُقارَن بـ`driverId` لا أكثر** — ليس في
  /// الرحلة إلا طرفان.
  final String? cancelledBy;
  final double fareEstimated;

  /// كم رفع الراكب أجرته لتسريع البحث. صفر = لم يرفع.
  final int fareBoostPct;
  final double? fareFinal;

  /// خصم الكوبون. **على الأجرة وحدها لا على البضاعة** — البضاعة مالُ
  /// السائق من جيبه، ولا نُهديه من ماله.
  final double discount;

  /// ما استُهلك من رصيد الراكب. يُملأ عند الإكمال لا قبله.
  final double creditUsed;

  /// **ما يدفعه الراكب نقداً للسائق فعلاً** — بعد الخصم والرصيد، وشاملاً
  /// البضاعة. تُحسبه القاعدة عند الإكمال؛ `null` قبله.
  final double? cashDue;

  /// سعر البضاعة كما قدّره الراكب عند الطلب.
  final double? goodsEstimate;

  /// سعر البضاعة كما دفعه السائق فعلاً في السوق. `null` = لم يشترِ بعد.
  final double? goodsActual;

  /// السعر المعتمد للبضاعة الآن: الفعلي إن وُجد، وإلا التقديري.
  double get goods => goodsActual ?? goodsEstimate ?? 0;

  /// هل أبلغ السائق بالسعر الحقيقي؟
  bool get goodsPriced => goodsActual != null;

  /// أجرة التوصيل المعتمدة الآن.
  double get fare => fareFinal ?? fareEstimated;

  /// المجموع المطلوب من الراكب. **`cashDue` أولاً** — هي وحدها تعرف
  /// الرصيد المستهلك، والحساب اليدوي يخالفها فيرى الراكب رقمين.
  double get totalDue => cashDue ?? (fare - discount + goods);

  final String pickupAddress;
  final String dropoffAddress;
  final double cancellationFee;

  final double? pickupLat;
  final double? pickupLng;
  final double? dropoffLat;
  final double? dropoffLng;
}

final tripRepositoryProvider = Provider<TripRepository>(
  (ref) => TripRepository(ref.watch(supabaseProvider)),
);

/// الرحلة النشطة للراكب الحالي، مُحدَّثة لحظياً.
///
/// **لماذا Realtime لا استطلاع دوري؟** لأن الراكب ينتظر رداً قد يأتي خلال
/// ثوانٍ. الاستطلاع كل ٥ ثوانٍ يعني تأخيراً محسوساً واستهلاك بطارية بلا
/// طائل. Supabase يبثّ التغيير عبر WebSocket فور حدوثه.
///
/// سياسات RLS تُطبَّق على البث أيضاً — لا يصل الراكب إلا ما يحق له رؤيته.
/// آخر رحلةٍ للراكب **مهما كانت حالتها** — منتهيةً أو جارية.
///
/// **ولماذا مزوّدٌ ثانٍ؟** لأن `activeTripProvider` يردّ `null` لكل
/// رحلةٍ منتهية — وهو صحيحٌ للشاشة: من انتهت رحلته يخرج من شاشة
/// المتابعة. لكنّ **مُشعِر الرحلة كان يقرأ منه**، فيرى `null` عند
/// الإلغاء والإكمال فيصمت — ولم يصل الراكب إشعارٌ بإلغاء السائق قطّ.
///
/// فالشاشة تحتاج «هل من رحلةٍ جارية؟» والمُشعِر يحتاج «ما آخر ما جرى؟»
/// — سؤالان مختلفان لا يصلح لهما مزوّدٌ واحد.
final lastTripProvider = StreamProvider<Trip?>((ref) {
  final session = ref.watch(sessionProvider);
  if (session == null) return Stream.value(null);

  return ref
      .watch(supabaseProvider)
      .from('trips')
      .stream(primaryKey: ['id'])
      .eq('rider_id', session.user.id)
      .order('requested_at', ascending: false)
      .limit(1)
      .map((rows) => rows.isEmpty ? null : Trip.fromRow(rows.first));
});

final activeTripProvider = StreamProvider<Trip?>((ref) {
  final session = ref.watch(sessionProvider);
  if (session == null) return Stream.value(null);

  final sb = ref.watch(supabaseProvider);

  return sb
      .from('trips')
      .stream(primaryKey: ['id'])
      .eq('rider_id', session.user.id)
      .order('requested_at', ascending: false)
      // **عشرون لا واحد، ثم نتخطّى طلبات المندوب.** التاجر قد يطلب
      // مندوباً بعد رحلته؛ وآخر صفٍّ حينها طردٌ لا رحلة — فيُحبس في شاشة
      // البحث عن سائقٍ لطردٍ له شاشته. والبثّ اللحظي لا يقبل إلا مرشّحاً
      // واحداً، فالتخطّي هنا.
      .limit(20)
      .map((all) {
        final rows = all.where((r) => r['kind'] != 'delivery').toList();
        if (rows.isEmpty) return null;
        final t = Trip.fromRow(rows.first);
        // الرحلات المنتهية لا تعني "رحلة نشطة" — نعيد null فيخرج
        // المستخدم من شاشة المتابعة تلقائياً.
        return t.status.isLive || t.status == TripStatus.noDrivers ? t : null;
      });
});

/// تقدّم البحث عن سائق: كم سائقاً وصله الطلب حتى الآن.
///
/// نعرضه للراكب ليعرف أن النظام يعمل فعلاً بدل دوّارة صامتة. الانتظار
/// المجهول يبدو أطول من الانتظار المُفسَّر.
///
/// **نعدّ السائقين لا العروض.** الطلب يُعاد عرضه على السائق نفسه كل
/// دقيقة، فعدّ الصفوف يجعل سائقاً واحداً يظهر «سائقَين» ثم «ثلاثة».
final offerProgressProvider =
    StreamProvider.family<int, String>((ref, tripId) {
  final sb = ref.watch(supabaseProvider);
  return sb
      .from('trip_offers')
      .stream(primaryKey: ['id'])
      .eq('trip_id', tripId)
      .map((rows) => rows.map((r) => r['driver_id']).toSet().length);
});

/// بيانات السائق المرافق للرحلة — الحقول الآمنة فقط.
final tripDriverProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, tripId) async {
  final sb = ref.watch(supabaseProvider);
  final rows = await sb
      .from('trip_party_info')
      .select()
      .eq('trip_id', tripId)
      .eq('party', 'driver');
  return rows.isEmpty ? null : rows.first;
});

class TripRepository {
  TripRepository(this._sb);

  final SupabaseClient _sb;

  /// يطلب رحلة جديدة.
  ///
  /// نمرّر المسافة والزمن المحسوبين من OSRM، لكن **الأجرة تُحسب في القاعدة**
  /// ولا نرسلها. لو أرسلناها لاستطاع تطبيق معدَّل طلب رحلة بأجرة صفر.
  Future<Trip> request({
    required LatLng pickup,
    required String pickupAddress,
    required LatLng dropoff,
    required String dropoffAddress,
    required int distanceMeters,
    required int durationSeconds,
    String? note,
    String? couponCode,
    LatLng? stop2,
    String? stop2Address,
    int? leg2Meters,
    int? leg2Seconds,
    bool stopover = false,
    String vehicleKind = 'bike',
  }) async {
    final row = await _sb.rpc('request_trip', params: {
      'p_pickup_lat': pickup.latitude,
      'p_pickup_lng': pickup.longitude,
      'p_dropoff_lat': dropoff.latitude,
      'p_dropoff_lng': dropoff.longitude,
      'p_pickup_address': pickupAddress,
      'p_dropoff_address': dropoffAddress,
      'p_distance_m': distanceMeters,
      'p_duration_s': durationSeconds,
      'p_payment_method': 'cash',
      'p_note': note,
      // الرمز لا الخصم: القاعدة تعيد التحقق وتحسب الخصم بنفسها، فتطبيقٌ
      // معدَّل لا يستطيع منح نفسه خصماً لم يستحقه.
      'p_coupon_code': couponCode,
      'p_stop2_lat': stop2?.latitude,
      'p_stop2_lng': stop2?.longitude,
      'p_stop2_address': stop2Address,
      'p_leg2_m': leg2Meters,
      'p_leg2_s': leg2Seconds,
      'p_stopover': stopover,
      'p_vehicle_kind': vehicleKind,
    }) as Map<String, dynamic>;

    return Trip.fromRow(row);
  }

  /// يطلب تغيير وجهة رحلة جارية. يحتاج موافقة السائق.
  ///
  /// نمرّر المسافة المقطوعة والمسار الجديد محسوبين من OSRM: القاعدة لا
  /// تعرف الطرق، وحسابُ المسافة بخط مستقيم يظلم أحد الطرفين عند الجسور
  /// والشوارع الملتوية.
  Future<Map<String, dynamic>> requestDestinationChange({
    required String tripId,
    required LatLng newDestination,
    required String newAddress,
    required int travelledMeters,
    required int newLegMeters,
    required int newLegSeconds,
  }) async {
    final row = await _sb.rpc('request_destination_change', params: {
      'p_trip_id': tripId,
      'p_new_lat': newDestination.latitude,
      'p_new_lng': newDestination.longitude,
      'p_new_address': newAddress,
      'p_travelled_m': travelledMeters,
      'p_new_leg_m': newLegMeters,
      'p_new_leg_s': newLegSeconds,
    });
    return Map<String, dynamic>.from(row as Map);
  }

  /// يرفع أجرة رحلة تبحث عن سائق، مرة واحدة.
  ///
  /// **القاعدة تُبطل العروض المعلّقة وتُعيد الإرسال فوراً:** السائق الذي
  /// يقرأ عرضاً الآن يرى السعر القديم، وقبولُه به يظلمه.
  Future<void> boostFare(String tripId) =>
      _sb.rpc('boost_trip_fare', params: {'p_trip_id': tripId});

  /// تقييم السائق بعد الرحلة.
  ///
  /// سياسة RLS تشترط رحلة **مكتملة** وأن يكون المُقيَّم هو الطرف الآخر
  /// فيها — فلا يمكن تقييم سائق لم يوصّلك، ولا تقييم نفسك.
  Future<void> rateDriver({
    required String tripId,
    required String driverId,
    required int stars,
    String? comment,
    List<String> tags = const [],
    num? reportedAmount,
  }) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) throw StateError('لا توجد جلسة');

    await _sb.from('ratings').insert({
      'trip_id': tripId,
      'rater_id': uid,
      'ratee_id': driverId,
      'stars': stars,
      'comment': (comment ?? '').trim().isEmpty ? null : comment!.trim(),
      'tags': tags,
      'reported_change_iqd': ?reportedAmount,
    });
  }

  /// طلب تسوّق — المحل نقطة الانطلاق والتسليم هو الوجهة.
  ///
  /// **التسعير في القاعدة لا هنا.** التطبيق يرسل المسافة والزمن،
  /// والقاعدة تحسب وتفرض الحدّ الأدنى — فلا يستطيع تطبيقٌ معدَّل أن
  /// يطلب بأجرةٍ يختارها.
  Future<Map<String, dynamic>> requestShopping({
    required LatLng shop,
    required String shopAddress,
    required LatLng dropoff,
    required String dropoffAddress,
    required int distanceMeters,
    required int durationSeconds,
    required List<Map<String, String>> items,
    required num goodsEstimate,
    String? note,
    String? couponCode,
    String? shopName,
  }) async {
    final row = await _sb.rpc('request_shopping', params: {
      'p_shop_lat': shop.latitude,
      'p_shop_lng': shop.longitude,
      'p_shop_address': shopAddress,
      'p_drop_lat': dropoff.latitude,
      'p_drop_lng': dropoff.longitude,
      'p_drop_address': dropoffAddress,
      'p_distance_m': distanceMeters,
      'p_duration_s': durationSeconds,
      'p_items': items,
      'p_goods_estimate': goodsEstimate,
      'p_note': ?note,
      'p_coupon_code': ?couponCode,
      'p_shop_name': ?shopName,
    });
    return Map<String, dynamic>.from(row as Map);
  }

  /// سجل رحلات الراكب.
  Future<List<Map<String, dynamic>>> history({int limit = 50}) async {
    final rows = await _sb
        .from('trips')
        .select('id, trip_number, status, pickup_address, dropoff_address, '
            'fare_final_iqd, fare_estimated_iqd, actual_distance_m, '
            'estimated_distance_m, requested_at, completed_at, driver_id')
        // طلبات المندوب في «طلبات المندوب» لا هنا
        .neq('kind', 'delivery')
        .order('requested_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> cancel(String tripId, {String? reason}) async {
    await _sb.rpc('cancel_trip', params: {
      'p_trip_id': tripId,
      'p_reason': reason,
    });
  }

  /// أسباب الإلغاء الجاهزة للراكب — لتوحيد التقارير بدل نص حر.
  Future<List<Map<String, dynamic>>> cancellationReasons() async {
    final rows = await _sb
        .from('cancellation_reasons')
        .select('code, label_ar')
        .eq('for_role', 'rider')
        .order('sort_order');
    return List<Map<String, dynamic>>.from(rows);
  }
}


/// سجل رحلات الراكب.
final tripHistoryProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(sessionProvider);
  return ref.watch(tripRepositoryProvider).history();
});

/// آخر رحلة للراكب، مُبثَّة لحظياً.
///
/// **مصدر ردّ الفعل، وهو ما كان ناقصاً.** `FutureProvider` وحده يُحسب
/// مرة ويُخزَّن إلى الأبد: يبدأ التطبيق بلا رحلة غير مقيَّمة فيخزّن
/// `null`، ثم تنتهي رحلة ولا شيء يُبطل التخزين — فلا تظهر شاشة التقييم
/// أبداً. ربطُه ببثّ يجعله يُعاد حسابه لحظة تتبدّل حالة الرحلة.
final lastCompletedTripProvider =
    StreamProvider<Map<String, dynamic>?>((ref) {
  final session = ref.watch(sessionProvider);
  if (session == null) return Stream.value(null);

  return ref
      .watch(supabaseProvider)
      .from('trips')
      .stream(primaryKey: ['id'])
      .eq('rider_id', session.user.id)
      .order('requested_at', ascending: false)
      // طلبات المندوب لها كشفها ولا تُقيَّم إلزامياً — انظر أعلاه.
      .limit(20)
      .map((all) {
        final rows = all.where((r) => r['kind'] != 'delivery').toList();
        if (rows.isEmpty) return null;
        final t = rows.first;
        return t['status'] == 'completed' ? t : null;
      });
});

/// رحلة مكتملة لم يُقيّمها الراكب بعد، إن وُجدت.
final unratedTripProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return null;

  final trip = await ref.watch(lastCompletedTripProvider.future);
  if (trip == null) return null;
  if (trip['driver_id'] == null) return null;

  final rated = await ref
      .watch(supabaseProvider)
      .from('ratings')
      .select('id')
      .eq('trip_id', trip['id'] as String)
      .eq('rater_id', session.user.id)
      .maybeSingle();

  return rated == null ? Map<String, dynamic>.from(trip) : null;
});

/// الرحلات التي اختار الراكب تأجيل تقييمها بـ"لاحقاً".
///
/// **في الذاكرة لا في القاعدة عمداً.** التأجيل تفضيل للجلسة الحالية لا
/// حقيقة دائمة: من فتح التطبيق غداً يستحق أن يُسأل مرة أخرى، ومن ضغط
/// "لاحقاً" الآن يستحق ألا يُحبس في الشاشة.
class SkippedRatings extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void skip(String tripId) => state = {...state, tripId};
}

final skippedRatingsProvider =
    NotifierProvider<SkippedRatings, Set<String>>(SkippedRatings.new);

/// الرحلة التي يجب أن تُعرض شاشة تقييمها الآن — أو `null`.
final pendingRatingProvider = Provider<Map<String, dynamic>?>((ref) {
  final trip = ref.watch(unratedTripProvider).value;
  if (trip == null) return null;
  return ref.watch(skippedRatingsProvider).contains(trip['id']) ? null : trip;
});


/// آخر طلب تغيير وجهة لرحلة، مُبثّاً.
///
/// الراكب يراقبه ليعرف هل وافق السائق أم اعتذر — بلا هذا يبقى ينتظر
/// شاشةً لا تتبدّل ولا يدري إن وصل طلبه أصلاً.
final myChangeRequestProvider =
    StreamProvider.family<Map<String, dynamic>?, String>((ref, tripId) {
  return ref
      .watch(supabaseProvider)
      .from('trip_change_requests')
      .stream(primaryKey: ['id'])
      .eq('trip_id', tripId)
      .order('created_at', ascending: false)
      .limit(1)
      .map((rows) => rows.isEmpty ? null : rows.first);
});
