import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// أيّ الخدمات مفتوحة الآن، ورسالة المغلقة منها.
///
/// **تُقرأ من الخادم لا من الكود.** إطلاق خدمةٍ أو إيقافها يجب أن يكون
/// نقرةً في اللوحة، لا بناءً ونشراً ومراجعةَ متجرٍ تستغرق يوماً.
/// **الاسم `ServiceAvailability` لا `ServiceStatus`.** الثاني يصدّره
/// `geolocator` لحالة خدمة الموقع، وتصادمُهما يكسر كل ملفٍّ يستورد
/// الاثنين — وشاشة السائق تستوردهما معاً.
class ServiceAvailability {
  const ServiceAvailability({
    required this.rides,
    required this.shopping,
    required this.ridesMessage,
    required this.shoppingMessage,
    this.delivery = false,
    this.deliveryMessage = '',
  });

  /// **الافتراض: مفتوحة.** تعذّرت القراءة — شبكةٌ أو قاعدةٌ لم تُرحَّل —
  /// فلا نُغلق العمل على الناس بسبب نداءٍ فشل.
  const ServiceAvailability.open()
      : rides = true,
        shopping = true,
        delivery = true,
        ridesMessage = '',
        shoppingMessage = '',
        deliveryMessage = '';

  final bool rides;
  final bool shopping;
  final String ridesMessage;
  final String shoppingMessage;

  /// طلب المندوب (0091).
  final bool delivery;
  final String deliveryMessage;

  factory ServiceAvailability.fromMap(Map<String, dynamic> m) =>
      ServiceAvailability(
        rides: m['rides'] != false,
        shopping: m['shopping'] != false,
        ridesMessage: '${m['rides_msg'] ?? ''}',
        shoppingMessage: '${m['shopping_msg'] ?? ''}',
        // **غيابُ المفتاح إغلاق، بخلاف أخويه.** قاعدةٌ لم يُطبَّق عليها
        // 0091 لا تعرف التوصيل أصلاً؛ وعرضُ زرّه حينها يقود إلى طلبٍ
        // يفشل بخطأ «دالة غير موجودة».
        delivery: m['delivery'] == true,
        deliveryMessage: '${m['delivery_msg'] ?? ''}',
      );
}

final serviceStatusProvider =
    FutureProvider<ServiceAvailability>((ref) async {
  try {
    final v = await Supabase.instance.client.rpc('service_status');
    return ServiceAvailability.fromMap((v as Map).cast<String, dynamic>());
  } catch (_) {
    return const ServiceAvailability.open();
  }
});
