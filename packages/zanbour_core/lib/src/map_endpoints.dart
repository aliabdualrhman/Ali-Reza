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

  /// مفتاح البناء — `--dart-define=GEOAPIFY_KEY=...`.
  ///
  /// **لم يعد المصدر الوحيد، وبقي آخر خطّ دفاع.** من بنى بلا هذه الراية
  /// كان يخرج بتطبيق خرائطه ميتة ولا علاج إلا بناءٌ جديد — أي أن المفتاح
  /// رهينةٌ عند من يبني. صار يُقرأ من اللوحة أوّلاً (0119)، وهذا يبقى
  /// لمن لم يضبط الصفّ بعد، ولمن لم تصله شبكةٌ عند الإقلاع.
  static const _buildKey = String.fromEnvironment('GEOAPIFY_KEY');

  static String? _remoteKey;
  static String? _remoteStyle;

  /// المفتاح العامل: ما ضبطه المدير إن وُجد، وإلا مفتاح البناء.
  static String get key =>
      (_remoteKey != null && _remoteKey!.isNotEmpty) ? _remoteKey! : _buildKey;

  /// يتبنّى ما جاء من `public_settings`.
  ///
  /// **الفارغ يُتجاهَل ولا يمحو.** الصفّ يُدرَج فارغاً في الترحيل، ولو
  /// تبنّينا الفراغ لأطفأنا خرائط بناءٍ كان يعمل — عطلٌ نصنعه بأيدينا
  /// وهو أسوأ من الذي جئنا نعالجه.
  static void adopt({String? key, String? style}) {
    if (key != null && key.trim().isNotEmpty) _remoteKey = key.trim();
    if (style != null && style.trim().isNotEmpty) _remoteStyle = style.trim();
  }

  /// هل التطبيق مهيّأ للعمل؟ نفحصه عند الإقلاع بدل أن نكتشف الغياب
  /// من شاشة خريطة رمادية عند أول راكب.
  static bool get configured => key.isNotEmpty;

  static const _api = 'https://api.geoapify.com/v1';

  /// بلاطات الخريطة. `osm-bright` أوضح الأنماط للشوارع الضيقة.
  static const _buildTileStyle =
      String.fromEnvironment('TILE_STYLE', defaultValue: 'osm-bright');

  static String get tileStyle => _remoteStyle ?? _buildTileStyle;

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
