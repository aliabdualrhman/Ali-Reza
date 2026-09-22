import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'map_endpoints.dart';

/// نتيجة بحث عن مكان.
class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.address,
    required this.point,
  });

  /// الاسم المختصر المعروض في القائمة — "مستشفى الكرامة"
  final String name;

  /// العنوان الكامل — "شارع مستشفى الكرامة، محلة 214، الشيخ معروف"
  final String address;

  final LatLng point;
}

/// مسار محسوب بين نقطتين.
class RouteResult {
  const RouteResult({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.polyline,
  });

  final int distanceMeters;
  final int durationSeconds;

  /// نقاط الخط لرسمه على الخريطة
  final List<LatLng> polyline;
}

/// حدود منطقة الخدمة التي يقف فيها المستخدم — لتقييد البحث بها.
class ServiceArea {
  const ServiceArea({
    this.minLon,
    this.minLat,
    this.maxLon,
    this.maxLat,
    this.cityAr = '',
    this.unrestricted = false,
  });

  final double? minLon;
  final double? minLat;
  final double? maxLon;
  final double? maxLat;

  /// اسم المدينة — نعرضه في حقل البحث ليعرف صاحبه أين يبحث.
  final String cityAr;

  /// **العالم كله.** خارج كل تغطية ووضع المراجعة مشتغل: نبحث بلا قيد.
  ///
  /// بدون هذا يُقيَّد بحث مراجع المتجر في كاليفورنيا بحدود المنطقة
  /// الاحتياطية في العراق، فلا يجد مكاناً واحداً قربه — نفتح له العالم
  /// في التسعير ونغلقه في البحث.
  final bool unrestricted;

  /// هل نملك مستطيلاً صالحاً نقيّد به؟
  bool get hasBox =>
      minLon != null && minLat != null && maxLon != null && maxLat != null;

  static ServiceArea? fromRow(Map<String, dynamic>? r) {
    if (r == null) return null;
    if (r['unrestricted'] == true) {
      return const ServiceArea(unrestricted: true);
    }
    final a = r['min_lon'] as num?;
    final b = r['min_lat'] as num?;
    final c = r['max_lon'] as num?;
    final d = r['max_lat'] as num?;
    if (a == null || b == null || c == null || d == null) return null;
    return ServiceArea(
      minLon: a.toDouble(),
      minLat: b.toDouble(),
      maxLon: c.toDouble(),
      maxLat: d.toDouble(),
      cityAr: (r['city_name_ar'] as String?) ?? '',
    );
  }
}

/// حدود المنطقة عند نقطة. `null` = خارج كل تغطية — لا خطأ، بل يعود
/// البحث حينها إلى التقييد بالدولة وحدها فيبحث ولا يُمنع.
final serviceAreaProvider =
    FutureProvider.family<ServiceArea?, LatLng>((ref, p) async {
  try {
    final rows = await Supabase.instance.client.rpc('zone_bbox', params: {
      'p_point': 'SRID=4326;POINT(${p.longitude} ${p.latitude})',
    });
    final list = rows as List?;
    if (list == null || list.isEmpty) return null;
    return ServiceArea.fromRow(Map<String, dynamic>.from(list.first as Map));
  } catch (_) {
    // فشل الشبكة لا يمنع البحث — نعود إلى التقييد بالدولة.
    return null;
  }
});

final geoServiceProvider = Provider<GeoService>((ref) => GeoService());

/// خدمات الموقع والخرائط، مبنية على OpenStreetMap.
///
/// **لماذا لا خرائط جوجل؟** حسابات فوترة Google Cloud غير متاحة في العراق،
/// وبدونها لا يمكن إنشاء مفتاح خرائط إطلاقاً. فحصنا البديل المفتوح على
/// بيانات حقيقية قبل اعتماده: ١٧٬٥٦٧ نقطة مسمّاة في بغداد، و٨ من ٨ معالم
/// وُجدت بالبحث العربي في بغداد والناصرية معاً.
class GeoService {
  /// تعريف التطبيق — عادة حسنة تُبقي طلباتنا مميّزة في سجلات المزوّد.
  static const _userAgent = 'Zanbour/1.0 (iq.zanbour)';

  Map<String, String> get _headers => const {'User-Agent': _userAgent};

  // ---------------------------------------------------------------------------
  // الموقع الحالي
  // ---------------------------------------------------------------------------
  /// يطلب الإذن ثم يعيد الموقع الحالي.
  ///
  /// نطلب الإذن **عند الحاجة** لا عند إقلاع التطبيق: المستخدم الذي يُسأل
  /// قبل أن يفهم السبب يرفض غالباً، ورفضه الدائم يصعب التراجع عنه.
  Future<Position> currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const GeoException('خدمة الموقع مغلقة. فعّلها من إعدادات هاتفك.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw const GeoException('نحتاج إذن الموقع لتحديد نقطة انطلاقك.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw const GeoException(
        'إذن الموقع مرفوض نهائياً. فعّله من إعدادات التطبيق.',
      );
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
  }

  /// آخر موقع يحتفظ به النظام — **لتركيز الخريطة لحظة فتحها**.
  ///
  /// `currentPosition` تحتاج ثوانيَ لتثبيت قراءة GPS، وحتى ذلك الحين
  /// تفتح الخريطة على مركز ثابت — مدينةٍ مكتوبة في الكود ليست مدينة
  /// صاحبها. أما هذه فتعيد آخر موقع سجّله الجهاز بلا تشغيل GPS ولا
  /// انتظار: قيمة محفوظة تُقرأ فوراً.
  ///
  /// **لا ترمي ولا تطلب إذناً.** غرضها التجميل لا القرار، وفشلُها يعني
  /// أن نبقى على المركز الاحتياطي — لا أن نُزعج المستخدم بحوار إذن
  /// لم يطلبه بعد. لذا تعيد `null` صامتة عند أي تعذّر.
  ///
  /// ولا تُستعمل قطّ لتحديد نقطة انطلاق أو لإرسال موقع للخادم: القيمة
  /// قد تكون قديمة بساعات أو من مدينة أخرى.
  /// يطلب إذن الموقع **بنافذة النظام** إن لم يُطلب بعد.
  ///
  /// **تُنادى عند الإقلاع لا عند أول حاجة.** كانت الشاشات تكتفي بـ
  /// `getLastKnownPosition` — وهي تقرأ موقعاً مخزّناً **ولا تطلب إذناً
  /// أبداً**. فعلى تثبيتٍ جديد لا موقعَ مخزّناً ولا نافذةَ إذن، فتفتح
  /// الخريطة على النقطة المكتوبة في الكود ويظنّ المستخدم التطبيق
  /// معطوباً — وهو لم يُسأل أصلاً.
  ///
  /// يعيد `true` إن صار الإذن ممنوحاً.
  Future<bool> ensurePermission() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      return p == LocationPermission.always ||
          p == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  Future<LatLng?> lastKnown() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      return p == null ? null : LatLng(p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // البحث عن مكان
  // ---------------------------------------------------------------------------
  /// بحث نصي مقيّد بمنطقة الخدمة، أو بالعراق حين لا تُعرف.
  ///
  /// `countrycode:iq` وحدها لم تعد تكفي: راكب في الناصرية يبحث عن
  /// «الكرادة» فتأتيه بغداد، فيطلب رحلة إلى مدينة أخرى بحسن نية.
  ///
  /// [area] حدود المنطقة التي يقف فيها — تأتي من `pricing_zones` أي من
  /// المناطق التي يفعّلها المدير. فإن أطفأ محافظةً توقّف البحث فيها كما
  /// توقّفت الرحلات، بلا قائمة مدن ثانية في الكود تُنسى.
  ///
  /// و[near] يرتّب الأقرب أولاً داخل المستطيل: المستطيل يحوي مدينةً
  /// كاملة، و«صيدلية» فيه عشرات. الأقرب إلى صاحبه أرجح أن يكون مقصده.
  Future<List<PlaceResult>> search(
    String query, {
    ServiceArea? area,
    LatLng? near,
  }) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    _requireKey();

    // ثلاث حالات مقصودة:
    //   • مستطيل منطقته      ← راكب بغداد يبحث في بغداد
    //   • بلا قيد إطلاقاً    ← وضع المراجعة وصاحبه خارج التغطية
    //   • العراق             ← لا منطقة ولا وضع مراجعة
    final filter = area?.unrestricted == true
        ? null
        : (area != null && area.hasBox)
            ? 'rect:${area.minLon},${area.minLat},${area.maxLon},${area.maxLat}'
            : 'countrycode:iq';

    final uri = Uri.parse(MapEndpoints.autocomplete).replace(queryParameters: {
      'text': q,
      'filter': ?filter,
      if (near != null) 'bias': 'proximity:${near.longitude},${near.latitude}',
      'lang': 'ar',
      'limit': '8',
      'apiKey': MapEndpoints.key,
    });

    final res = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw const GeoException('تعذّر البحث. تحقق من اتصالك.');
    }

    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final features = (j['features'] as List?) ?? const [];

    return features
        .map((f) => _place((f as Map<String, dynamic>)['properties']))
        .whereType<PlaceResult>()
        .toList();
  }

  /// يحوّل خصائص معلَم GeoJSON إلى نتيجة معروضة.
  ///
  /// Geoapify تعطي `name` للمعالم المسمّاة فقط — الشوارع والعناوين
  /// تأتي بلا اسم. فنشتقّ الاسم حينها من أول جزء في `formatted`،
  /// ونحذفه من العنوان لئلا يتكرر السطر مرتين تحت بعضه.
  PlaceResult? _place(Object? props) {
    if (props is! Map<String, dynamic>) return null;
    final lat = props['lat'] as num?;
    final lon = props['lon'] as num?;
    if (lat == null || lon == null) return null;

    final formatted = (props['formatted'] as String? ?? '').trim();
    var name = (props['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      name = formatted.split(RegExp('[,،]')).first.trim();
    }
    if (name.isEmpty) return null;

    var address = formatted;
    if (address.startsWith(name)) {
      address = address.substring(name.length);
    }
    address = address.replaceFirst(RegExp(r'^[،,\s]+'), '').trim();

    return PlaceResult(
      name: name,
      // نكتفي بثلاثة أجزاء — التسلسل الكامل ينتهي بـ"العراق" الذي لا
      // يفيد المستخدم بشيء ويزاحم ما يفيده.
      address: address
          .split(RegExp('[,،]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .take(3)
          .join('، '),
      point: LatLng(lat.toDouble(), lon.toDouble()),
    );
  }

  /// تحويل إحداثيات إلى عنوان مقروء — يُستدعى بعد سحب الدبوس.
  Future<String> addressOf(LatLng p) async {
    final uri = Uri.parse(MapEndpoints.reverse).replace(queryParameters: {
      'lat': p.latitude.toString(),
      'lon': p.longitude.toString(),
      'lang': 'ar',
      'limit': '1',
      'apiKey': MapEndpoints.key,
    });

    try {
      final res = await http.get(uri, headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 'موقع محدد على الخريطة';

      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final features = (j['features'] as List?) ?? const [];
      if (features.isEmpty) return 'موقع محدد على الخريطة';

      final props =
          (features.first as Map<String, dynamic>)['properties'] as Map?;
      final full = (props?['formatted'] as String? ?? '').trim();
      if (full.isEmpty) return 'موقع محدد على الخريطة';

      // نكتفي بأول ثلاثة أجزاء — التسلسل الكامل يصل لعشرة مستويات
      // وينتهي بـ"العراق" الذي لا يفيد المستخدم بشيء.
      final parts = full.split(RegExp('[,،]')).map((s) => s.trim()).toList();
      return parts.take(3).join('، ');
    } catch (_) {
      // فشل العنوان لا يعطّل الرحلة — الإحداثيات هي ما يهم فعلاً
      return 'موقع محدد على الخريطة';
    }
  }

  // ---------------------------------------------------------------------------
  // حساب المسار
  // ---------------------------------------------------------------------------
  /// يحسب المسافة والزمن والخط بين نقطتين.
  ///
  /// **مهم:** هذه القيم هي أساس الأجرة. لا نحسب المسافة بخط مستقيم لأن
  /// شوارع بغداد تجعل ٤ كم هوائية تساوي ٧.٥ كم فعلية — فرق يكاد يضاعف
  /// الأجرة ويظلم أحد الطرفين.
  Future<RouteResult> route(LatLng from, LatLng to) async {
    _requireKey();

    final uri = Uri.parse(MapEndpoints.routing).replace(queryParameters: {
      // ترتيب Geoapify `lat,lon` والفاصل `|` — عكس ترتيب OSRM تماماً.
      'waypoints': '${from.latitude},${from.longitude}'
          '|${to.latitude},${to.longitude}',
      'mode': MapEndpoints.travelMode,
      // **لا `lang` هنا.** واجهة التوجيه ترفض `ar` وتردّ خطأً يُفشل
      // الطلب كله — والعربية مدعومة في البحث وعكس الترميز وحدهما.
      // ولا نخسر شيئاً: لا نعرض تعليمات انعطاف، بل المسافة والزمن والخط.
      'apiKey': MapEndpoints.key,
    });

    final res = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw const GeoException('تعذّر حساب المسار. حاول مرة أخرى.');
    }

    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final features = (j['features'] as List?) ?? const [];
    if (features.isEmpty) {
      throw const GeoException('لا يوجد طريق بين النقطتين.');
    }

    final f = features.first as Map<String, dynamic>;
    final props = f['properties'] as Map<String, dynamic>;

    // **الهندسة `MultiLineString` لا `LineString`.** Geoapify تقسّم
    // المسار مرحلةً لكل زوج نقاط، فالإحداثيات مصفوفة من مصفوفات.
    // معاملتها كخط واحد تُسقط كل مرحلة بعد الأولى.
    final legs = (f['geometry']?['coordinates'] as List?) ?? const [];
    final line = <LatLng>[
      for (final leg in legs)
        for (final c in (leg as List))
          // GeoJSON يعطي [lng, lat] — معكوس عن LatLng، ومصدر أخطاء متكرر
          LatLng(((c as List)[1] as num).toDouble(), (c[0] as num).toDouble()),
    ];

    return RouteResult(
      distanceMeters: (props['distance'] as num).round(),
      // `time` بالثواني كما في OSRM — لكن محسوبة بوضع الدراجة النارية.
      durationSeconds: (props['time'] as num).round(),
      polyline: line,
    );
  }

  /// بناءٌ بلا مفتاح يعني خرائط ميتة. نفشل برسالة تقول السبب بدل
  /// «تعذّر الاتصال» التي تُرسل المستخدم يفحص شبكته بلا طائل.
  void _requireKey() {
    if (!MapEndpoints.configured) {
      throw const GeoException(
        'مفتاح الخرائط غير مضبوط في هذا الإصدار. راجع المطوّر.',
      );
    }
  }
}

/// خطأ بخدمات الموقع برسالة عربية جاهزة للعرض.
class GeoException implements Exception {
  const GeoException(this.message);
  final String message;

  @override
  String toString() => message;
}
