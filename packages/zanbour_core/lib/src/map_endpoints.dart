/// عناوين خدمات الخرائط ومفتاحها — في مكان واحد.
///
/// **لماذا ملف مستقل؟** كانت هذه العناوين مكتوبة يدوياً في ستة ملفات،
/// فتغييرُ المزوّد يعني مطاردتها واحداً واحداً، ونسيانُ ملف واحد يعني
/// أن يستمر جزء من التطبيق يقصد خادماً لا يحقّ لنا استعماله.
///
/// **لماذا Geoapify؟** كنّا نقصد خوادم OpenStreetMap وOSRM العامة، وهي
/// تمنع الاستخدام الإنتاجي صراحةً وتحجب بلا إنذار. وGeoapify تقدّم
/// الثلاث — بلاطات وعناوين ومسارات — برخصة تجارية، وتدعم وضع
/// `motorcycle`. وهذا الأخير ليس تفصيلاً: OSRM العام لا يعرف إلا
/// السيارة، فكان يقدّر ١.٥ كم بعشر دقائق (٩ كم/س) والزمن يدخل في
/// معادلة الأجرة — أي أننا كنّا نحاسب الركّاب بأكثر من الحق.
///
/// **المفتاح لا يُخزَّن في المستودع.** يُمرَّر عند البناء:
///
/// ```
/// flutter build appbundle --release --dart-define=GEOAPIFY_KEY=xxxxxxxx
/// ```
class MapEndpoints {
  const MapEndpoints._();

  /// مفتاح Geoapify. فارغ = لم يُمرَّر عند البناء.
  static const key = String.fromEnvironment('GEOAPIFY_KEY');

  /// هل التطبيق مهيّأ للعمل؟ نفحصه عند الإقلاع بدل أن نكتشف الغياب
  /// من شاشة خريطة رمادية عند أول راكب.
  static bool get configured => key.isNotEmpty;

  static const _api = 'https://api.geoapify.com/v1';

  /// بلاطات الخريطة. `osm-bright` أوضح الأنماط للشوارع الضيقة.
  static const tileStyle =
      String.fromEnvironment('TILE_STYLE', defaultValue: 'osm-bright');

  static String get tiles =>
      'https://maps.geoapify.com/v1/tile/$tileStyle/{z}/{x}/{y}.png?apiKey=$key';

  /// البحث عن العناوين أثناء الكتابة.
  static String get autocomplete => '$_api/geocode/autocomplete';

  /// تحويل الإحداثيات إلى عنوان مقروء.
  static String get reverse => '$_api/geocode/reverse';

  /// حساب المسافة والزمن والخط.
  static String get routing => '$_api/routing';

  /// وضع التوجيه.
  ///
  /// **`scooter` لا `motorcycle`** — رغم أن الاسم الثاني أدقّ وصفاً.
  /// قِسنا ثلاثة مسارات في الناصرية وبغداد فوجدنا `motorcycle` يعيد
  /// نتيجةً مطابقةً لـ`drive` حرفاً بحرف: نفس المسافة ونفس الزمن ونفس
  /// عدد نقاط الخط. أي أنه اسم موجود في التوثيق بلا أثر في الحساب.
  ///
  /// أما `scooter` فيتصرّف كمركبة ذات عجلتين فعلاً: في بغداد وجد مساراً
  /// أقصر بـ٤٧٧ متراً عبر شوارع تمنع السيارة، وسرعاته أكثر تحفظاً
  /// (~٣٨ كم/س مقابل ~٥٠).
  ///
  /// **ويبقى تقديراً يحتاج معايرة على رحلات حقيقية** — ازدحام الناصرية
  /// ليس ازدحام أوروبا، والزمن يدخل في معادلة الأجرة.
  static const travelMode =
      String.fromEnvironment('TRAVEL_MODE', defaultValue: 'scooter');

  /// الخطة المجانية تشترط ذكر المصدر. تُعرض تحت كل خريطة.
  static const attribution = 'Powered by Geoapify — OpenStreetMap contributors';
}
