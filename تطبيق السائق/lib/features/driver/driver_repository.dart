import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';

/// حالة السائق اللحظية كما تعرّفها قاعدة البيانات.
enum DriverStatus {
  offline,
  online,
  onTrip;

  static DriverStatus parse(String? raw) => switch (raw) {
        'online' => DriverStatus.online,
        'on_trip' => DriverStatus.onTrip,
        _ => DriverStatus.offline,
      };

  String get label => switch (this) {
        DriverStatus.offline => 'غير متصل',
        DriverStatus.online => 'متصل — بانتظار طلب',
        DriverStatus.onTrip => 'في رحلة',
      };
}

/// حالة اعتماد وثائق السائق.
enum VerificationStatus {
  pending,
  approved,
  rejected,
  suspended;

  static VerificationStatus parse(String? raw) => switch (raw) {
        'approved' => VerificationStatus.approved,
        'rejected' => VerificationStatus.rejected,
        'suspended' => VerificationStatus.suspended,
        _ => VerificationStatus.pending,
      };
}

/// سجل السائق كما يحتاجه التطبيق.
class DriverRecord {
  DriverRecord.fromRow(Map<String, dynamic> r)
      : status = DriverStatus.parse(r['status'] as String?),
        verification =
            VerificationStatus.parse(r['verification_status'] as String?),
        rejectionReason = r['rejection_reason'] as String?,
        walletBalance = (r['wallet_balance_iqd'] as num?)?.toDouble() ?? 0,
        bonusBalance = (r['bonus_balance_iqd'] as num?)?.toDouble() ?? 0,
        ratingAvg = (r['rating_avg'] as num?)?.toDouble() ?? 5.0,
        ratingCount = (r['rating_count'] as num?)?.toInt() ?? 0,
        tripsCompleted = (r['trips_completed'] as num?)?.toInt() ?? 0,
        vehicleKind = '${r['vehicle_kind'] ?? 'bike'}',
        acceptsBikeTrips = r['accepts_bike_trips'] != false,
        acceptsShopping = r['accepts_shopping'] == true,
        acceptsRides = r['accepts_rides'] != false,
        acceptsDelivery = r['accepts_delivery'] == true,
        acceptsBikeDeliveries = r['accepts_bike_deliveries'] == true,
        vehicleType = r['vehicle_type'] as String?,
        vehiclePlate = r['vehicle_plate'] as String?;

  final DriverStatus status;
  final VerificationStatus verification;
  final String? rejectionReason;

  /// رصيد المحفظة بالدينار. **سالب = دين عمولات على السائق.**
  ///
  /// الدفع نقدي فالسائق يقبض الأجرة كاملة بيده، ونقيّد حصة المنصة ديناً
  /// عليه. حين يبلغ الحد يُمنع من الاتصال حتى يسدّد.
  final double walletBalance;

  /// **رصيد الهدية** — مالٌ تمنحه الإدارة للسائق، تأكله عمولةُ رحلاته
  /// قبل أن تمسّ محفظته (0103). لا يُسحب نقداً ولا يُنقَل.
  ///
  /// كان يُضاف من اللوحة ولا يظهر هنا إطلاقاً، فيبدو أن الإضافة لم تحدث.
  final double bonusBalance;

  final double ratingAvg;
  final int ratingCount;
  final int tripsCompleted;
  /// 'bike' أو 'tuktuk'. يُحدَّد عند التسجيل ولا يتغيّر.
  final String vehicleKind;

  /// سائق التكتك يقبل طلبات الدراجات أيضاً. بلا معنى لسائق الدراجة.
  final bool acceptsBikeTrips;

  /// **مغلقٌ افتراضاً.** طلب التسوّق يتطلّب نقداً في الجيب.
  final bool acceptsShopping;

  /// **مفتوحٌ افتراضاً.** نقل الركّاب هو العمل الأصلي.
  final bool acceptsRides;

  /// طلبات المندوب (0091). **مغلقٌ افتراضاً** — قد يُطلب منه دفع ثمن
  /// السلعة للمتجر مقدّماً.
  final bool acceptsDelivery;

  /// سائق التكتك يستقبل طلبات التوصيل بالدراجة أيضاً — **مستقلٌّ عن
  /// [acceptsBikeTrips]**: من يقبل ركّاب الدراجة قد لا يريد طرودها.
  final bool acceptsBikeDeliveries;

  /// هل يريد أيّ عمل؟ — ما يقرّر الاتصال تلقائياً.
  bool wantsWork(ServiceAvailability s) =>
      (acceptsRides && s.rides) ||
      (acceptsShopping && s.shopping) ||
      (acceptsDelivery && s.delivery);

  bool get isTuktuk => vehicleKind == 'tuktuk';

  /// **سائق الستوتة مندوب توصيلٍ لا غير.** لا ركّاب ولا تسوّق، ولا تصله
  /// إلا طلبات المتاجر التي طلبت ستوتةً بالذات (0105).
  bool get isStoota => vehicleKind == 'stoota';

  final String? vehicleType;
  final String? vehiclePlate;

  bool get canGoOnline => verification == VerificationStatus.approved;
}

/// سجل السائق الحالي، مُحدَّث لحظياً.
///
/// نستمع للتغيير بدل قراءته مرة: حين يعتمد المدير الوثائق يجب أن تتبدّل
/// شاشة الانتظار فوراً بلا أن يعيد السائق تشغيل التطبيق.
final driverRecordProvider = StreamProvider<DriverRecord?>((ref) {
  final session = ref.watch(sessionProvider);
  if (session == null) return Stream.value(null);

  return ref
      .watch(supabaseProvider)
      .from('drivers')
      .stream(primaryKey: ['id'])
      .eq('id', session.user.id)
      .map((rows) => rows.isEmpty ? null : DriverRecord.fromRow(rows.first));
});

/// كل العروض المعلّقة الموجّهة لهذا السائق، الأحدث أولاً.
///
/// **قلب تطبيق السائق.** حين ترسل حلقة المطابقة عرضاً يظهر هنا خلال جزء
/// من الثانية عبر WebSocket، فتفتح شاشة العرض تلقائياً بلا استطلاع.
///
/// **لماذا قائمة لا عرضاً واحداً؟** بعد البثّ المتوازي في 0020 صار الطلب
/// الواحد يُعرض على خمسة سائقين، وصار السائق الواحد قد تصله عروض عدة
/// رحلات في آنٍ واحد. عرض الأحدث وحده يُخفي عنه رحلة قد تكون أقرب أو
/// أعلى أجراً، ويجعل الطلب "يقفز" أمامه كلما وصل غيره.
/// **ولماذا مصدران لا مصدر واحد؟** المقبس (WebSocket) يموت صامتاً.
/// مُصنّعو الأجهزة في المنطقة — شاومي وأوبو وفيفو وهواوي — يجمّدون
/// التطبيق حين تُطفأ الشاشة فيُقطع المقبس بلا خطأ ولا إعادة اتصال؛
/// والإشعار يصل عبر خدمة النظام فيرنّ الهاتف، ولا يصل صفّ العرض إلى
/// التطبيق. فيسمع السائق المنبّه ولا يرى طلباً — وهو أسوأ عطلٍ ممكن:
/// يبدو التطبيق شغّالاً وهو أعمى.
///
/// **والإشعار نفسه ليس بديلاً.** جهازٌ بلا خدمات Google — وهي نسخٌ
/// شائعة في السوق العراقية — لا يولّد رمزاً أصلاً (`FCM Registration
/// failed`)، فلا إشعار ولا صوت.
///
/// فنستطلع كل عشر ثوانٍ عبر REST إلى جانب المقبس. الاستطلاع وحده بطيء،
/// والمقبس وحده هشّ — ومعاً لا يسقط الطلب.
const _offerPollInterval = Duration(seconds: 10);

final pendingOffersProvider =
    StreamProvider<List<Map<String, dynamic>>>((ref) {
  final session = ref.watch(sessionProvider);
  if (session == null) return Stream.value(const []);

  final sb = ref.watch(supabaseProvider);
  final uid = session.user.id;

  List<Map<String, dynamic>> live(List<Map<String, dynamic>> rows) {
    final now = DateTime.now().toUtc();
    final open = rows.where((o) {
      if (o['status'] != 'pending') return false;

      // نتحقق من المهلة محلياً أيضاً: العامل الدوري في القاعدة قد
      // يتأخر ثانية أو ثانيتين، ولا نريد عرض طلب منتهٍ على السائق
      // فيقبله ويُرفض.
      final expires = DateTime.tryParse('${o['expires_at']}');
      return expires == null || expires.isAfter(now);
    }).toList();
    open.sort((a, b) => '${b['sent_at']}'.compareTo('${a['sent_at']}'));
    return open;
  }

  final out = StreamController<List<Map<String, dynamic>>>();

  // **بصمة لا قائمة.** المصدران يسلّمان الصفوف نفسها، وإرسال كل وصول
  // يُعيد بناء الشاشة مرتين في الثانية بلا تغيّر — ومع مؤقّت العدّ
  // التنازلي في شاشة العرض يظهر ارتجافاً. نُصدر عند التغيّر وحده.
  String? last;
  void emit(List<Map<String, dynamic>> rows) {
    if (out.isClosed) return;
    final fingerprint = rows.map((o) => '${o['id']}').join(',');
    if (fingerprint == last) return;
    last = fingerprint;
    out.add(rows);
  }

  final socket = sb
      .from('trip_offers')
      .stream(primaryKey: ['id'])
      .eq('driver_id', uid)
      .listen((rows) => emit(live(rows)), onError: (_) {
        // **لا نُسقط المجرى.** خطأ المقبس ليس نهاية العروض ما دام
        // الاستطلاع حيّاً؛ ورميُ الخطأ هنا يُفرغ الشاشة ويطرد السائق
        // من عرضٍ قائم.
      });

  Future<void> poll() async {
    try {
      final rows = await sb
          .from('trip_offers')
          .select()
          .eq('driver_id', uid)
          .eq('status', 'pending')
          .gt('expires_at', DateTime.now().toUtc().toIso8601String());
      emit(live(rows.cast<Map<String, dynamic>>()));
    } catch (_) {
      // الشبكة تتقطّع في الشارع. المحاولة القادمة بعد عشر ثوانٍ.
    }
  }

  poll();
  final timer = Timer.periodic(_offerPollInterval, (_) => poll());

  ref.onDispose(() {
    timer.cancel();
    socket.cancel();
    out.close();
  });

  return out.stream;
});

/// العروض مرتّبة: المرفوع سعره أولاً ثم الأحدث.
///
/// **الترتيب هو نصف معنى الرفع.** الراكب الذي دفع أكثر ليصل أسرع لا
/// يستفيد شيئاً إن كان طلبه آخر ما يمرّر إليه السائق — وقد ينتهي قبل
/// أن يصله. المزوّد لا يستطيع فرزه في الاستعلام لأن نسبة الرفع في
/// جدول الرحلات لا العروض، فنفرز هنا بعد جلب الرحلات.
final sortedOffersProvider =
    Provider<List<Map<String, dynamic>>>((ref) {
  final offers = [...?ref.watch(pendingOffersProvider).value];

  int boostOf(Map<String, dynamic> o) {
    final trip = ref.watch(offeredTripProvider(o['trip_id'] as String)).value;
    return ((trip?['fare_boost_pct'] as num?) ?? 0).toInt();
  }

  offers.sort((a, b) {
    final byBoost = boostOf(b).compareTo(boostOf(a));
    if (byBoost != 0) return byBoost;
    return '${b['sent_at']}'.compareTo('${a['sent_at']}');
  });
  return offers;
});

/// عرضٌ فُتح إشعاره بعد فوات أوانه.
///
/// **لماذا نحتاج علماً منفصلاً؟** الموجّه يقرأ الحالة ويعيد السائق إلى
/// الشاشة الرئيسية حين لا يجد عرضاً معلّقاً — سلوك صحيح، لكنه صامت.
/// السائق الذي ضغط إشعاراً ووجد نفسه في الخريطة يظن التطبيق معطّلاً،
/// بينما الحقيقة أن الطلب انتقل إلى سائق آخر. هذا العلم يجعلنا نقول له
/// ذلك صراحةً.
/// (‏Riverpod 3 أزال StateProvider، فنستعمل Notifier مباشرة.)
class MissedOffer extends Notifier<bool> {
  @override
  bool build() => false;

  void flag() => state = true;
  void clear() => state = false;
}

final missedOfferProvider =
    NotifierProvider<MissedOffer, bool>(MissedOffer.new);

/// تفاصيل الرحلة المعروضة — يقرؤها السائق قبل القبول.
final offeredTripProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, tripId) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('trips')
      .select()
      .eq('id', tripId)
      .limit(1);
  return rows.isEmpty ? null : rows.first;
});

/// محطات رحلة معروضة — يقرؤها السائق **قبل** أن يقبل.
///
/// **بلا هذا يقبل رحلة لا يعرف شكلها.** `dropoff_address` يحمل الوجهة
/// الأخيرة وحدها، فرحلة بمحطتين تبدو له رحلة عادية إلى مكان بعيد —
/// ثم يكتشف بعد القبول أن عليه التوقف في الطريق.
final offeredStopsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
        (ref, tripId) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('trip_stops')
      .select()
      .eq('trip_id', tripId)
      .order('seq');
  return List<Map<String, dynamic>>.from(rows);
});

/// الرحلة النشطة الحالية للسائق.
final activeDriverTripProvider = StreamProvider<Map<String, dynamic>?>((ref) {
  final session = ref.watch(sessionProvider);
  if (session == null) return Stream.value(null);

  const live = {'accepted', 'driver_arrived', 'in_progress'};

  return ref
      .watch(supabaseProvider)
      .from('trips')
      .stream(primaryKey: ['id'])
      .eq('driver_id', session.user.id)
      .order('requested_at', ascending: false)
      .limit(1)
      .map((rows) {
        if (rows.isEmpty) return null;
        final t = rows.first;
        return live.contains(t['status']) ? t : null;
      });
});

final driverRepositoryProvider = Provider<DriverRepository>(
  (ref) => DriverRepository(ref.watch(supabaseProvider)),
);

class DriverRepository {
  DriverRepository(this._sb);

  final SupabaseClient _sb;

  /// تبديل الاتصال.
  ///
  /// القاعدة ترفض الاتصال إذا لم تُعتمد الوثائق أو تجاوز الدين الحد،
  /// وترسل رسالة عربية جاهزة للعرض. لا نكرر الفحص هنا — مصدر واحد للقرار.
  Future<void> setOnline(bool online) =>
      _sb.rpc('set_driver_online', params: {'p_online': online});

  /// سائق التكتك يفتح طلبات الدراجات أو يغلقها.
  ///
  /// **الزيادة تتبع نوع الطلب لا مركبته:** إن قبل طلب دراجة أخذ سعر
  /// الدراجة كاملاً بلا زيادة التكتك — الراكب طلب دراجة ودفع سعرها.
  Future<void> setAcceptsBikeTrips(bool value) =>
      _sb.rpc('set_accepts_bike_trips', params: {'p_value': value});

  /// يرسل الموقع الحالي. يُستدعى كل بضع ثوانٍ أثناء الاتصال.
  Future<void> pushLocation({
    required double lat,
    required double lng,
    int? heading,
    int? speedKmh,
  }) =>
      _sb.rpc('update_driver_location', params: {
        'p_lat': lat,
        'p_lng': lng,
        'p_heading': heading,
        'p_speed_kmh': speedKmh,
      });

  /// قبول عرض. القاعدة تحسم التسابق: أول من يصل يفوز والباقي يُرفض
  /// برسالة "سبقك سائق آخر".
  Future<void> acceptOffer(String offerId) =>
      _sb.rpc('accept_trip_offer', params: {'p_offer_id': offerId});

  Future<void> rejectOffer(String offerId) =>
      _sb.rpc('reject_trip_offer', params: {'p_offer_id': offerId});

  /// تقدّم الرحلة: وصلتُ، ثم بدأت.
  Future<void> advance(String tripId, String toStatus) =>
      _sb.rpc('advance_trip', params: {
        'p_trip_id': tripId,
        'p_to': toStatus,
      });

  /// إنهاء الرحلة. القاعدة تحسب الأجرة النهائية وتقيّد العمولة.
  Future<void> complete(String tripId, {int? distanceM, int? durationS}) =>
      _sb.rpc('complete_trip', params: {
        'p_trip_id': tripId,
        'p_actual_distance_m': distanceM,
        'p_actual_duration_s': durationS,
      });

  /// حدّ التحذير من منطقة انطلاق الرحلة.
  ///
  /// **كان مكتوباً في التطبيق ثابتاً (`400`)، وفي القاعدة إعداداً.**
  /// والقيمتان تفترقان لحظة تغيير إحداهما: يحذّر التطبيق عند رقمٍ
  /// وتحكم القاعدة بآخر، فرحلتان بنفس التحذير إحداهما تُحتسب والأخرى
  /// لا — بلا ما يفسّر الفرق. نسأل بنفس المفتاح الذي يحكم به (0059).
  Future<int> dropoffWarnRadius(String tripId) async {
    final v = await _sb.rpc('trip_dropoff_warn_radius',
        params: {'p_trip_id': tripId});
    return (v as num?)?.toInt() ?? 400;
  }

  /// يبلّغ القاعدة ببُعد السائق عن الوجهة لحظة الإنهاء.
  ///
  /// **نرسل المسافة لا الحكم.** القاعدة تقارنها بحدّ المنطقة وتقرّر —
  /// ولو أرسلنا `completed_far` جاهزةً لأمكن تزويرها بتعديل الحزمة، ومن
  /// يحتال على مكافأة دعوة يحتال على هذا.
  ///
  /// وفشلُه لا يُفشل إنهاء الرحلة: قياسٌ ضائع أهون من رحلةٍ عالقة.
  Future<void> reportCompletionDistance(String tripId, int meters) =>
      _sb.rpc('mark_completion_distance', params: {
        'p_trip_id': tripId,
        'p_distance_m': meters,
      });

  Future<void> cancel(String tripId, {String? reason}) =>
      _sb.rpc('cancel_trip', params: {
        'p_trip_id': tripId,
        'p_reason': reason,
      });

  // ---------------------------------------------------------------------------
  // الرصيد: تعبئة وسحب
  // ---------------------------------------------------------------------------

  /// يستهلك رمز تعبئة ويعيد الرصيد بعده.
  ///
  /// **الدين يُسدَّد أولاً بلا منطق خاص:** المحفظة رقم واحد بإشارة، فمن
  /// عليه ٢٠٠٠ وعبّأ ٥٠٠٠ يصير رصيده ٣٠٠٠ موجباً بالجمع وحده.
  Future<double> redeemTopupCode(String code) async {
    final v = await _sb.rpc('redeem_topup_code', params: {'p_code': code});
    return (v as num).toDouble();
  }

  Future<void> requestPayout(int amountIqd) =>
      _sb.rpc('request_payout', params: {'p_amount': amountIqd});

  Future<void> cancelPayout(String id) =>
      _sb.rpc('cancel_payout_request', params: {'p_id': id});

  Future<List<Map<String, dynamic>>> payoutRequests() async {
    final rows = await _sb
        .from('payout_requests')
        .select()
        .order('requested_at', ascending: false)
        .limit(30);
    return List<Map<String, dynamic>>.from(rows);
  }

  // ---------------------------------------------------------------------------
  // رحلاتي وتقييمي
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> tripHistory({int limit = 50}) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _sb
        .from('trips')
        .select()
        .eq('driver_id', uid)
        .order('requested_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// أرباحي بين تاريخين — الجمع في القاعدة (0088) لا هنا، لأن الواجهة
  /// لا تعيد أكثر من ألف صف فيخرج مجموع الفترة الطويلة ناقصاً.
  Future<Earnings> earnings(DateTime from, DateTime to) async {
    final rows = await _sb.rpc('my_earnings', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    }) as List;
    if (rows.isEmpty) return const Earnings(0, 0, 0, 0);
    final r = rows.first as Map<String, dynamic>;
    num n(String k) => (r[k] as num?) ?? 0;
    return Earnings(
      n('trip_count').toInt(),
      n('gross_iqd'),
      n('commission_total'),
      n('net_iqd'),
    );
  }

  /// تقييماتي بلا هويات — الدالة في القاعدة لا تعيد `rater_id` إطلاقاً،
  /// فلا يعرف السائق من أعطاه نجمة واحدة ولا ينتقم.
  Future<List<Map<String, dynamic>>> myRatings() async {
    final rows = await _sb.rpc('my_ratings', params: {'p_limit': 100});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// سعر البضاعة الحقيقي في طلب التسوّق.
  Future<num> setGoodsPrice({
    required String tripId,
    required num amount,
  }) async {
    final v = await _sb.rpc('set_goods_price', params: {
      'p_trip_id': tripId,
      'p_amount': amount,
    });
    return (v as num?) ?? 0;
  }

  /// يستقبل طلبات التسوّق أم لا.
  Future<void> setAcceptsShopping(bool value) =>
      _sb.rpc('set_accepts_shopping', params: {'p_value': value});

  /// يستقبل طلبات نقل الركّاب أم لا.
  Future<void> setAcceptsRides(bool value) =>
      _sb.rpc('set_accepts_rides', params: {'p_value': value});

  // ---------------------------------------------------------------------------
  // طلب المندوب (0091)
  // ---------------------------------------------------------------------------

  Future<void> setAcceptsDelivery(bool value) =>
      _sb.rpc('set_accepts_delivery', params: {'p_value': value});

  Future<void> setAcceptsBikeDeliveries(bool value) =>
      _sb.rpc('set_accepts_bike_deliveries', params: {'p_value': value});

  /// اختيار طريقة الدفع عند المتجر: `prepay` أو `after`. لا يبدأ التوصيل
  /// حتى يختار التاجر الخيار نفسه — القاعدة تفرضه.
  Future<void> chooseDeliveryPayment(String tripId, String mode) =>
      _sb.rpc('choose_delivery_payment',
          params: {'p_trip_id': tripId, 'p_mode': mode});

  Future<void> reportDeliveryFailed(String tripId, String reason) =>
      _sb.rpc('report_delivery_failed',
          params: {'p_trip_id': tripId, 'p_reason': reason});

  /// تسليمٌ أو إعادة — القاعدة تعرف أيّهما من `delivery_failed_at`.
  Future<void> completeDelivery(String tripId, {int? distanceM}) =>
      _sb.rpc('complete_delivery', params: {
        'p_trip_id': tripId,
        'p_distance_m': distanceM,
      });

  /// «تم إغلاق المستحقات» — يصل التاجرَ سؤالٌ يؤكّده أو ينفيه.
  Future<void> claimDeliverySettled(String tripId) =>
      _sb.rpc('claim_delivery_settled', params: {'p_trip_id': tripId});

  /// طلبات المندوب التي عليها مستحقات للمتاجر — مفتوحةً ومغلقة.
  Future<List<Map<String, dynamic>>> storeDues() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _sb
        .from('trips')
        .select('id, trip_number, completed_at, shop_name, store_phone, '
            'goods_actual_iqd, settle_status, settle_claimed_at, '
            'settle_closed_at, dropoff_address')
        .eq('driver_id', uid)
        .eq('kind', 'delivery')
        .not('settle_status', 'is', null)
        .order('completed_at', ascending: false)
        .limit(200);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// تسوية النقد: ما زاد عن المستحقّ يعود إلى محفظة الراكب.
  ///
  /// **الحساب في القاعدة لا هنا.** التطبيق يقول كم استلم، والقاعدة
  /// تطرح وتفحص الحدّ وتنقل وتُشعر — فلا يستطيع تطبيقٌ معدَّل أن ينقل
  /// مالاً بمقدارٍ يختاره.
  Future<num> settleCashChange({
    required String tripId,
    required num received,
  }) async {
    final v = await _sb.rpc('settle_cash_change', params: {
      'p_trip_id': tripId,
      'p_received': received,
    });
    return ((v as Map)['change'] as num?) ?? 0;
  }

  /// تقييم السائق للراكب بعد انتهاء الرحلة.
  Future<void> rateRider({
    required String tripId,
    required String riderId,
    required int stars,
    String? comment,
    List<String> tags = const [],
    num? reportedAmount,
  }) =>
      _sb.from('ratings').insert({
        'trip_id': tripId,
        // السياسة تشترط `rater_id = auth.uid()` صراحةً، فلا تكفي القيمة
        // الافتراضية — إغفاله يجعل الإدراج يُرفض بلا رسالة مفهومة.
        'rater_id': _sb.auth.currentUser?.id,
        'ratee_id': riderId,
        'stars': stars,
        'comment': (comment ?? '').trim().isEmpty ? null : comment!.trim(),
        'tags': tags,
        'reported_change_iqd': ?reportedAmount,
      });

  /// كم إلغاءً استعمله السائق اليوم، وكم مجانياً له، وكم العقوبة.
  ///
  /// نقرؤه قبل أن نسأله عن الإلغاء: من يعرف العاقبة قبل الضغط لا يشعر
  /// أنه خُدع بعده.
  Future<(int, int, int)> cancelsToday() async {
    final rows = await _sb.rpc('my_cancels_today');
    final r = (rows as List).first as Map<String, dynamic>;
    return (
      (r['used'] as num).toInt(),
      (r['free'] as num).toInt(),
      (r['penalty'] as num).round(),
    );
  }

  /// الوصول إلى محطة وسيطة — لا إنهاء.
  ///
  /// **زر مستقل عمداً:** لو ترك للسائق زر الإنهاء وحده لضغطه عند الوجهة
  /// الأولى بحكم العادة، فتُقفل الرحلة وتضيع المرحلة الثانية وأجرتها.
  Future<void> arriveAtStop(String tripId) =>
      _sb.rpc('arrive_at_stop', params: {'p_trip_id': tripId});

  /// محطات الرحلة مرتّبة، لتعرف الشاشة إلى أين تُوجّه الملاحة.
  Future<List<Map<String, dynamic>>> tripStops(String tripId) async {
    final rows = await _sb
        .from('trip_stops')
        .select()
        .eq('trip_id', tripId)
        .order('seq');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> respondToChange(String id, bool accept) =>
      _sb.rpc('respond_destination_change',
          params: {'p_id': id, 'p_accept': accept});

  Future<List<Map<String, dynamic>>> cancellationReasons() async {
    final rows = await _sb
        .from('cancellation_reasons')
        .select('code, label_ar')
        .eq('for_role', 'driver')
        .order('sort_order');
    return List<Map<String, dynamic>>.from(rows);
  }

  /// كشف حركات المحفظة.
  Future<List<Map<String, dynamic>>> walletHistory({int limit = 50}) async {
    final rows = await _sb
        .from('wallet_transactions')
        .select('txn_type, amount_iqd, balance_after_iqd, description, created_at')
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(rows);
  }
}

/// آخر رحلة أنجزها السائق، مُبثَّة لحظياً.
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
      .eq('driver_id', session.user.id)
      .order('requested_at', ascending: false)
      .limit(1)
      .map((rows) {
        if (rows.isEmpty) return null;
        final t = rows.first;
        return t['status'] == 'completed' ? t : null;
      });
});

/// رحلة مكتملة لم يُقيّمها السائق بعد، إن وُجدت.
final unratedTripProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return null;

  // الاعتماد على البثّ لا على جلب لمرة واحدة: هنا تُولد إعادة الحساب.
  final trip = await ref.watch(lastCompletedTripProvider.future);
  if (trip == null) return null;
  if (trip['rider_id'] == null) return null;

  // **لا تقييم إلزامياً بعد طلب المندوب.** المندوب قد يُنجز عشرة طرودٍ
  // لمتجرٍ واحد في يوم؛ شاشةٌ تحبسه بعد كل طرد تعطّله عن الذي يليه.
  if (trip['kind'] == 'delivery') return null;

  final rated = await ref
      .watch(supabaseProvider)
      .from('ratings')
      .select('id')
      .eq('trip_id', trip['id'] as String)
      .eq('rater_id', session.user.id)
      .maybeSingle();

  return rated == null ? Map<String, dynamic>.from(trip) : null;
});

/// رحلةٌ مكتملة لم يُسجَّل فيها المبلغ المستلَم بعد.
///
/// **تسبق التقييم.** المال أولاً: من قيّم ثم أُغلق التطبيق نسي الباقي،
/// والراكب ينتظره. والتقييم يحتمل التأجيل، والمال لا.
final pendingCashProvider = Provider<Map<String, dynamic>?>((ref) {
  final trip = ref.watch(lastCompletedTripProvider).value;
  if (trip == null) return null;

  // **لا لطلب المندوب.** الباقي هنا يعود إلى محفظة «الراكب» — وهو في
  // التوصيل تاجرٌ لم يدفع شيئاً؛ الدافع مستلمٌ بلا حسابٍ عندنا.
  if (trip['kind'] == 'delivery') return null;

  // نقداً فقط، وسُئل مرةً واحدة، وله مستحقٌّ نقديّ فعلاً.
  if (trip['payment_method'] != 'cash') return null;
  if (trip['cash_received_iqd'] != null) return null;

  // **البضاعة جزءٌ من المستحقّ.** `cash_due_iqd` يحسبها مُشغّل القاعدة
  // عند الإكمال، لكنه يصل بعد لحظة — وحتى تصل، كان الاحتياطيّ يحسب
  // الأجرة وحدها. فيرى السائق ١٥٠٠ والمستحقّ ٢٥٠٠، ويُرجع ألفاً
  // زائداً من جيبه.
  final goods = (trip['goods_actual_iqd'] as num?) ??
      (trip['goods_estimate_iqd'] as num?) ??
      0;

  final due = (trip['cash_due_iqd'] as num?) ??
      (((trip['fare_final_iqd'] as num?) ?? 0) -
          ((trip['discount_iqd'] as num?) ?? 0) +
          goods);
  if (due <= 0) return null;

  return {...Map<String, dynamic>.from(trip), '_due': due};
});

/// الرحلات التي اختار السائق تأجيل تقييمها بـ"لاحقاً".
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


/// محطات الرحلة الجارية، مرتّبة.
final tripStopsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, tripId) => ref.watch(driverRepositoryProvider).tripStops(tripId),
);

/// طلب تغيير وجهة ينتظر ردّ السائق.
///
/// **بثّ لا جلب:** الراكب يطلبه فجأة أثناء القيادة، والسائق يجب أن يراه
/// في ثوانٍ لا حين يحدّث الشاشة بيده.
final pendingChangeProvider =
    StreamProvider.family<Map<String, dynamic>?, String>((ref, tripId) {
  return ref
      .watch(supabaseProvider)
      .from('trip_change_requests')
      .stream(primaryKey: ['id'])
      .eq('trip_id', tripId)
      .order('created_at', ascending: false)
      .limit(1)
      .map((rows) {
        if (rows.isEmpty) return null;
        final r = rows.first;
        return r['status'] == 'pending' ? r : null;
      });
});

/// مجاميع أرباح السائق لفترة.
class Earnings {
  const Earnings(this.trips, this.gross, this.commission, this.net);

  final int trips;

  /// مجموع أجور الرحلات المكتملة كما دفعها الركّاب
  final num gross;

  /// حصة الشركة منها
  final num commission;

  /// ما بقي للسائق
  final num net;
}
