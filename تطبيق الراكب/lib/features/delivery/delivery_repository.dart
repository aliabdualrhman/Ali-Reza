import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';

/// طلب المندوب من جهة التاجر — المواصفات في docs/features/delivery.md.
class DeliveryRepository {
  DeliveryRepository(this._sb);
  final SupabaseClient _sb;

  Future<Map<String, dynamic>?> myStore() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return null;
    return _sb.from('stores').select().eq('owner_id', uid).maybeSingle();
  }

  /// تسجيل المتجر أو تعديله. **الاعتماد عند المدير لا هنا** — المتجر
  /// الجديد يبدأ «بانتظار المراجعة»، والمرفوض يعود إليها حين يُعدَّل.
  Future<void> saveStore({
    required String name,
    required String phone,
    required String address,
    required double lat,
    required double lng,
  }) =>
      _sb.rpc('save_my_store', params: {
        'p_name': name,
        'p_phone': iraqiE164(phone),
        'p_address': address,
        'p_lat': lat,
        'p_lng': lng,
      });

  Future<void> requestDelivery({
    required String recipientPhone,
    required String recipientAddress,
    String? landmark,
    required num goodsPrice,
    required num fee,
    required String vehicle,
    double? dropLat,
    double? dropLng,
    int? distanceM,
    int? durationS,
    String? note,
  }) =>
      _sb.rpc('request_delivery', params: {
        'p_recipient_phone': iraqiE164(recipientPhone),
        'p_recipient_address': recipientAddress,
        'p_landmark': landmark,
        'p_goods_price': goodsPrice,
        'p_fee': fee,
        'p_vehicle': vehicle,
        'p_drop_lat': dropLat,
        'p_drop_lng': dropLng,
        'p_distance_m': distanceM,
        'p_duration_s': durationS,
        'p_note': note,
      });

  Future<void> choosePayment(String tripId, String mode) =>
      _sb.rpc('choose_delivery_payment',
          params: {'p_trip_id': tripId, 'p_mode': mode});

  /// ردّ التاجر على «يقول المندوب إنه أعاد لك الثمن».
  Future<void> confirmSettled(String tripId, bool received) =>
      _sb.rpc('confirm_delivery_settled',
          params: {'p_trip_id': tripId, 'p_received': received});

  Future<void> cancel(String tripId) => _sb.rpc('cancel_trip',
      params: {'p_trip_id': tripId, 'p_reason': 'ألغاه المتجر'});
}

final deliveryRepositoryProvider = Provider<DeliveryRepository>(
  (ref) => DeliveryRepository(ref.watch(supabaseProvider)),
);

final myStoreProvider = FutureProvider.autoDispose<Map<String, dynamic>?>(
  (ref) {
    ref.watch(sessionProvider);
    return ref.watch(deliveryRepositoryProvider).myStore();
  },
);

/// طلبات المندوب للتاجر، لحظياً — النشطة والمنتهية معاً.
///
/// **بثٌّ لا جلب.** التاجر يتابع خمسة طرود في آن، وكل واحدٍ يتقدّم
/// مرحلةً بلا أن يلمس شاشته.
final myDeliveriesProvider =
    StreamProvider<List<Map<String, dynamic>>>((ref) {
  final session = ref.watch(sessionProvider);
  if (session == null) return Stream.value(const []);

  return ref
      .watch(supabaseProvider)
      .from('trips')
      .stream(primaryKey: ['id'])
      .eq('rider_id', session.user.id)
      .order('requested_at', ascending: false)
      .limit(300)
      // البثّ لا يقبل إلا مرشّحاً واحداً؛ النوع يُرشَّح هنا.
      .map((rows) => rows.where((r) => r['kind'] == 'delivery').toList());
});

/// طلبٌ واحد من البثّ نفسه — لا اشتراك ثانٍ لكل شاشة تفاصيل.
final deliveryProvider =
    Provider.family<Map<String, dynamic>?, String>((ref, id) {
  final all = ref.watch(myDeliveriesProvider).value ?? const [];
  return all.where((r) => r['id'] == id).firstOrNull;
});

/// مندوب الطلب — الاسم والصورة والهاتف أثناء الطلب النشط وحده.
final deliveryDriverProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>?, String>(
        (ref, tripId) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('trip_party_info')
      .select()
      .eq('trip_id', tripId)
      .eq('party', 'driver');
  return rows.isEmpty ? null : rows.first;
});

/// طلباتٌ ينتظر فيها المندوب تأكيد التاجر أنه أعاد الثمن.
final pendingSettleConfirmsProvider =
    Provider<List<Map<String, dynamic>>>((ref) {
  final all = ref.watch(myDeliveriesProvider).value ?? const [];
  return all.where((r) => r['settle_status'] == 'claimed').toList();
});

const kLiveDeliveryStatuses = {
  'searching',
  'accepted',
  'driver_arrived',
  'in_progress',
};

/// اسم المرحلة كما يقرؤه التاجر.
String deliveryStageLabel(Map<String, dynamic> t) {
  final failed = t['delivery_failed_at'] != null;
  return switch ('${t['status']}') {
    'searching' => 'نبحث عن مندوب',
    'accepted' => 'المندوب في طريقه إليك',
    'driver_arrived' => 'المندوب عندك',
    'in_progress' =>
      failed ? 'تعذّر التسليم — يعيده إليك' : 'في الطريق إلى المستلم',
    'completed' =>
      t['delivery_outcome'] == 'returned' ? 'أُعيد إليك' : 'تم التوصيل',
    'no_drivers' => 'لم نجد مندوباً',
    'cancelled' => 'أُلغي',
    _ => '${t['status']}',
  };
}
