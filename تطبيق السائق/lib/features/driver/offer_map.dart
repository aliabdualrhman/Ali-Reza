import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

/// خريطة مصغّرة في بطاقة العرض: نقطة الانطلاق والوجهة والمحطات.
///
/// **لماذا خريطة والعناوين مكتوبة؟** لأن العنوان النصّي لا يقول للسائق
/// ما يحتاج أن يعرفه في خمس عشرة ثانية: هل الرحلة في اتجاهه أم عكسه؟
/// وهل تعبر الجسر؟ وهل الوجهة في حيٍّ يعرفه؟
///
/// «چا كافية، حي الاسكان القديم» و«مركز السموم، شارع السراي» اسمان لا
/// يرسمان خطاً في الذهن — والخريطة ترسمه في لمحة.
///
/// **ولا نرسم المسار الفعلي.** حسابه نداءٌ إلى Geoapify لكل عرض، وخمسة
/// عروض متزامنة تعني خمسة نداءات في ثوانٍ — بفاتورةٍ وتأخيرٍ لا يستحقّان.
/// الخط المستقيم يكفي لفهم الاتجاه، وهو كل المطلوب هنا.
class OfferMap extends StatelessWidget {
  const OfferMap({
    super.key,
    required this.pickup,
    required this.dropoff,
    this.stops = const [],
    this.height = 200,
  });

  final (double, double)? pickup;
  final (double, double)? dropoff;

  /// المحطات الوسيطة مرتّبةً — لرحلةٍ بأكثر من وجهة.
  final List<(double, double)> stops;

  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // **بلا إحداثيات لا خريطة.** ورسمُ خريطةٍ فارغة يوهم السائق أن
    // الرحلة في مكانٍ ما ثم لا يجد عليها شيئاً.
    if (pickup == null && dropoff == null) return const SizedBox.shrink();

    final points = <LatLng>[
      if (pickup != null) LatLng(pickup!.$1, pickup!.$2),
      for (final s in stops) LatLng(s.$1, s.$2),
      if (dropoff != null) LatLng(dropoff!.$1, dropoff!.$2),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                // **الحدود لا المركز.** حساب مركزٍ وتقريبٍ يدوياً يقطع
                // إحدى النقطتين حين تتباعدان؛ و`fitCamera` تضمن ظهورهما
                // معاً مهما بعدتا.
                initialCameraFit: points.length > 1
                    ? CameraFit.coordinates(
                        coordinates: points,
                        padding: const EdgeInsets.all(44),
                        maxZoom: 15,
                      )
                    : null,
                initialCenter: points.first,
                initialZoom: 14,

                // **معطّلة عمداً.** السائق أمامه عدّاد ينفد، وخريطةٌ
                // يحرّكها بإصبعه سهواً تُضيّع ثانيتين وتُخفي النقطتين.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: MapEndpoints.tiles,
                  // محفوظةٌ على الهاتف ثلاثين يوماً — انظر ZanbourTiles.
                  tileProvider: ZanbourTiles.provider(),
                  userAgentPackageName: 'iq.zanbour.driver',
                  // بلاطات أقل تفصيلاً تكفي لخريطةٍ بهذا الحجم، وتصل أسرع
                  // على شبكة الشارع.
                  maxNativeZoom: 18,
                ),

                if (points.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: points,
                        strokeWidth: 3,
                        color: theme.colorScheme.primary.withValues(alpha: 0.7),
                        // متقطّع ليقول إنه اتجاهٌ لا طريقٌ فعلي.
                        pattern: StrokePattern.dashed(segments: const [8, 6]),
                      ),
                    ],
                  ),

                MarkerLayer(
                  markers: [
                    if (pickup != null)
                      Marker(
                        point: LatLng(pickup!.$1, pickup!.$2),
                        width: 34,
                        height: 34,
                        child: _Pin(
                          icon: Icons.trip_origin,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    for (var i = 0; i < stops.length; i++)
                      Marker(
                        point: LatLng(stops[i].$1, stops[i].$2),
                        width: 28,
                        height: 28,
                        child: _Pin(
                          icon: Icons.pin_drop,
                          color: theme.colorScheme.secondary,
                          small: true,
                        ),
                      ),
                    if (dropoff != null)
                      Marker(
                        point: LatLng(dropoff!.$1, dropoff!.$2),
                        width: 34,
                        height: 34,
                        child: _Pin(
                          icon: Icons.location_on,
                          color: theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ],
            ),

            // **مفتاحٌ صغير.** لونان بلا تفسير يجعلان السائق يخمّن أيّهما
            // البداية — وهو يخمّن تحت عدّاد.
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.trip_origin,
                        size: 13, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Text('الانطلاق', style: theme.textTheme.labelSmall),
                    const SizedBox(width: 10),
                    Icon(Icons.location_on,
                        size: 13, color: theme.colorScheme.error),
                    const SizedBox(width: 4),
                    Text('الوجهة', style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.icon, required this.color, this.small = false});

  final IconData icon;
  final Color color;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: small ? 14 : 18),
    );
  }
}
