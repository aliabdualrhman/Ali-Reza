import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';

/// صور الخريطة محفوظةً على الهاتف — أندرويد وآيفون بالشيفرة نفسها.
///
/// **لماذا؟** كانت كل فتحةٍ للتطبيق تُنزّل صور الخريطة من جديد، وشوارع
/// الناصرية لم تتغيّر منذ الأمس. سائقٌ يفتح التطبيق عشر مرات يدفع ثمن
/// الصور نفسها عشر مرات من حصة Geoapify اليومية (٣٠٠٠ وحدة، وكل ٤ صور
/// وحدة). وهي أكثر من نصف استهلاك الرحلة الواحدة.
///
/// الناصرية صغيرة، وكل مستخدمٍ يرى تقريباً الصور نفسها كل يوم. فبعد أيام
/// يعرض الهاتف الخريطة من ذاكرته، ولا يطلب إلا ما لم يره.
///
/// **والحفظ مسموح:** Geoapify تسمح بتخزين صورها بشرط ذكر اسمها تحت
/// الخريطة — وهو في كل خريطة عندنا.
class ZanbourTiles {
  ZanbourTiles._();

  /// **ثلاثون يوماً، وأربعة آلاف صورة على الأكثر** (نحو ٦٠–٨٠ ميغا).
  /// الشوارع تتغيّر في سنوات لا أيام؛ والحدّ يمنع تطبيقاً يتضخّم على
  /// هاتفٍ مساحته قليلة — الأقدم استعمالاً يُحذف أولاً.
  static final CacheManager cache = CacheManager(
    Config(
      'zanbour_map_tiles',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 4000,
      fileService: _LongLivedFileService(),
    ),
  );

  /// المزوّد الذي يُمرَّر إلى كل `TileLayer`.
  static TileProvider provider() => _CachedTileProvider();
}

class _CachedTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      CachedNetworkImageProvider(
        getTileUrl(coordinates, options),
        cacheManager: ZanbourTiles.cache,
        headers: headers,
      );
}

/// **الصلاحية ثلاثون يوماً أيّاً كان ما يقوله الخادم.**
///
/// مدير الحفظ يأخذ مدة الصلاحية من ترويسة `Cache-Control` في ردّ الخادم؛
/// فإن كانت يوماً واحداً أعاد الهاتف طلب الصورة غداً — وكل طلبٍ يُحسب من
/// الحصة ولو جاء بالصورة نفسها. فنثبّت المدة هنا.
class _LongLivedFileService extends HttpFileService {
  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final r = await super.get(url, headers: headers);
    return _LongLived(r);
  }
}

class _LongLived implements FileServiceResponse {
  _LongLived(this._r);
  final FileServiceResponse _r;

  @override
  Stream<List<int>> get content => _r.content;
  @override
  int? get contentLength => _r.contentLength;
  @override
  int get statusCode => _r.statusCode;
  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 30));
  @override
  String? get eTag => _r.eTag;
  @override
  String get fileExtension => _r.fileExtension;
}
