import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'trip_repository.dart';

/// تغيير وجهة رحلة جارية.
///
/// **يحتاج موافقة السائق، ولهذا سبب.** السائق قبل رحلة بمسافة وأجرة
/// معلومتين وخطّط يومه عليها. وجهةٌ جديدة تُفرض عليه قد تخرجه من منطقته
/// أو تضاعف مشواره — والقبول المسبق لا يشمل ما لم يره.
///
/// **والمستحق حتى نقطة التغيير يُحسب كرحلة كاملة:** السائق أتى وانتظر
/// وحمل الراكب، وكل ذلك حدث فعلاً ولا يُلغيه تغيير الوجهة.
class ChangeDestinationScreen extends ConsumerStatefulWidget {
  const ChangeDestinationScreen({super.key, required this.trip});

  final Trip trip;

  @override
  ConsumerState<ChangeDestinationScreen> createState() =>
      _ChangeDestinationScreenState();
}

class _ChangeDestinationScreenState
    extends ConsumerState<ChangeDestinationScreen> {
  final _map = MapController();
  LatLng? _target;
  String _address = '';
  bool _busy = false;
  String? _error;

  /// آخر موقع معروف — يُستعمل حين لا تحمل الرحلة وجهة مسجّلة.
  LatLng? _seed;

  @override
  void initState() {
    super.initState();
    // الرحلة بلا وجهة حالة نادرة، لكنها كانت تفتح على مدينة مكتوبة في
    // الكود. موقع الراكب نفسه أصدق مبتدأ لاختيار وجهة جديدة.
    if (widget.trip.dropoffLat == null || widget.trip.dropoffLng == null) {
      _seedFromLastKnown();
    }
  }

  Future<void> _seedFromLastKnown() async {
    final p = await ref.read(geoServiceProvider).lastKnown();
    if (p == null || !mounted || _target != null) return;
    setState(() => _seed = p);
    try {
      _map.move(p, 15);
    } catch (_) {
      // الخريطة لم تُبنَ بعد — `initialCenter` سيلتقط `_seed`.
    }
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  Future<void> _refreshAddress(LatLng p) async {
    final addr = await ref.read(geoServiceProvider).addressOf(p);
    if (!mounted) return;
    setState(() {
      _target = p;
      _address = addr;
    });
  }

  Future<void> _submit() async {
    final target = _target;
    final trip = widget.trip;
    if (target == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final geo = ref.read(geoServiceProvider);
      final pos = await geo.currentPosition();
      final here = LatLng(pos.latitude, pos.longitude);

      final pickup = (trip.pickupLat != null && trip.pickupLng != null)
          ? LatLng(trip.pickupLat!, trip.pickupLng!)
          : here;

      // نداءان لـ OSRM: ما قُطع فعلاً، والمسار الجديد من هنا. الأول هو
      // ما يجعل التسعير عادلاً بدل تخمينه من خط مستقيم.
      final travelled = await geo.route(pickup, here);
      final ahead = await geo.route(here, target);

      final res = await ref.read(tripRepositoryProvider).requestDestinationChange(
            tripId: trip.id,
            newDestination: target,
            newAddress: _address,
            travelledMeters: travelled.distanceMeters,
            newLegMeters: ahead.distanceMeters,
            newLegSeconds: ahead.durationSeconds,
          );

      if (!mounted) return;
      final quoted = (res['quoted_fare_iqd'] as num?)?.round() ?? 0;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('أُرسل الطلب للسائق — الأجرة تصير $quoted دينار'),
          duration: const Duration(seconds: 5),
        ),
      );
    } on GeoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = (widget.trip.dropoffLat != null &&
            widget.trip.dropoffLng != null)
        ? LatLng(widget.trip.dropoffLat!, widget.trip.dropoffLng!)
        // وجهة الرحلة، فآخر موقع معروف، فالناصرية كملاذ أخير.
        : _seed ?? const LatLng(31.0439, 46.2575);

    return Scaffold(
      appBar: AppBar(title: const Text('تغيير الوجهة')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: start,
              initialZoom: 15,
              minZoom: 5,
              maxZoom: 18,
              onPositionChanged: (cam, hasGesture) {
                if (hasGesture) _refreshAddress(cam.center);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: MapEndpoints.tiles,
                // محفوظةٌ على الهاتف ثلاثين يوماً — انظر ZanbourTiles.
                tileProvider: ZanbourTiles.provider(),
                userAgentPackageName: 'iq.zanbour.rider',
                maxZoom: 19,
              ),
            ],
          ),

          // الدبوس ثابت في المركز والخريطة تتحرك تحته — أدق من السحب
          // بالإصبع على شاشة صغيرة.
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: Icon(Icons.location_on,
                    size: 44, color: theme.colorScheme.error),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Card(
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _address.isEmpty
                            ? 'حرّك الخريطة لاختيار الوجهة الجديدة'
                            : _address,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'يجب أن يوافق السائق. تُحسب الأجرة على ما قطعتماه '
                        'حتى الآن زائداً المسار الجديد.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Text(_error!,
                            style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 14),
                      FilledButton(
                        onPressed:
                            (_busy || _target == null) ? null : _submit,
                        style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52)),
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.4))
                            : const Text('أرسل الطلب للسائق'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
