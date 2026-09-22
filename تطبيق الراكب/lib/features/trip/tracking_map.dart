import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';

/// موقع السائق المرافق للرحلة، مُحدَّث لحظياً.
///
/// **لماذا نتابع صف السائق لا جدول المواقع؟** لأن `trip_locations` سجل
/// تاريخي ينمو بسرعة (نقطة كل ٥ ثوانٍ)، والاشتراك عليه يعني استقبال كل
/// نقطة سابقة. صف `drivers` يحمل آخر موقع فقط — وهو ما نحتاجه.
///
/// سياسة RLS "drivers: راكب الرحلة النشطة" تسمح بهذه القراءة أثناء
/// الرحلة النشطة وحدها. بعد انتهائها يتوقف التدفّق تلقائياً.
final driverLocationProvider =
    StreamProvider.family<LatLng?, String>((ref, driverId) {
  return ref
      .watch(supabaseProvider)
      .from('drivers')
      .stream(primaryKey: ['id'])
      .eq('id', driverId)
      .map((rows) {
        if (rows.isEmpty) return null;
        final lat = rows.first['current_lat'];
        final lng = rows.first['current_lng'];
        if (lat is! num || lng is! num) return null;
        return LatLng(lat.toDouble(), lng.toDouble());
      });
});

/// خريطة تتبّع السائق أثناء اقترابه من الراكب.
///
/// تحلّ محل نص "السائق في طريقه إليك" الذي لا يخبر الراكب متى يصل —
/// فيتصل بالسائق كل دقيقتين. رؤية الدراجة تتحرك تغني عن الاتصال.
class TrackingMap extends ConsumerStatefulWidget {
  const TrackingMap({
    super.key,
    required this.driverId,
    required this.pickup,
    this.dropoff,
    this.showDropoff = false,
  });

  final String driverId;
  final LatLng pickup;
  final LatLng? dropoff;

  /// أثناء الرحلة نُظهر الوجهة بدل نقطة الانطلاق.
  final bool showDropoff;

  @override
  ConsumerState<TrackingMap> createState() => _TrackingMapState();
}

class _TrackingMapState extends ConsumerState<TrackingMap> {
  final _map = MapController();
  bool _followedOnce = false;

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  /// يضبط الخريطة لتُظهر السائق وهدفه معاً.
  void _fit(LatLng driver, LatLng target) {
    _map.fitCamera(
      CameraFit.coordinates(
        coordinates: [driver, target],
        padding: const EdgeInsets.all(56),
        maxZoom: 16,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final driverLoc = ref.watch(driverLocationProvider(widget.driverId));
    final target =
        widget.showDropoff ? (widget.dropoff ?? widget.pickup) : widget.pickup;

    // نضبط الإطار مرة واحدة عند أول موقع يصل، ثم نترك المستخدم يحرّك
    // الخريطة بحرية. إعادة الضبط مع كل تحديث تسرق منه التحكم كل ٥ ثوانٍ.
    final d = driverLoc.value;
    if (d != null && !_followedOnce) {
      _followedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit(d, target);
      });
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: d ?? target,
            initialZoom: 15,
            minZoom: 5,
            maxZoom: 18,
          ),
          children: [
            TileLayer(
              urlTemplate: MapEndpoints.tiles,
              // محفوظةٌ على الهاتف ثلاثين يوماً — انظر ZanbourTiles.
              tileProvider: ZanbourTiles.provider(),
              userAgentPackageName: 'com.zanbour.rider',
              maxZoom: 19,
            ),
            MarkerLayer(markers: [
              Marker(
                point: target,
                width: 44,
                height: 44,
                child: Icon(
                  widget.showDropoff ? Icons.location_on : Icons.trip_origin,
                  size: 34,
                  color: widget.showDropoff
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
              if (d != null)
                Marker(
                  point: d,
                  width: 52,
                  height: 52,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                      boxShadow: const [
                        BoxShadow(blurRadius: 8, color: Colors.black26),
                      ],
                    ),
                    child: Icon(Icons.two_wheeler,
                        size: 30,
                        color: theme.colorScheme.onPrimaryContainer),
                  ),
                ),
            ]),
            const RichAttributionWidget(attributions: [
              TextSourceAttribution(MapEndpoints.attribution),
            ]),
          ],
        ),

        // زر إعادة التأطير — يستعيد الرؤية بعد أن يحرّك المستخدم الخريطة
        if (d != null)
          Positioned(
            bottom: 12,
            left: 12,
            child: FloatingActionButton.small(
              heroTag: 'fit_tracking',
              onPressed: () => _fit(d, target),
              tooltip: 'إظهار السائق والوجهة',
              child: const Icon(Icons.center_focus_strong),
            ),
          ),

        // حين لا يصل موقع بعد — نشرح بدل ترك الخريطة فارغة محيّرة
        if (d == null)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(10),
              color: theme.colorScheme.surface,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Expanded(child: Text('بانتظار موقع السائق…')),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
