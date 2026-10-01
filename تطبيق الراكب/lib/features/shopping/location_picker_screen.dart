import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'package:zanbour_core/zanbour_core.dart';

/// ما يعود من شاشة الاختيار.
class PickedPlace {
  const PickedPlace(this.point, this.address);

  final LatLng point;
  final String address;
}

/// اختيار نقطة على الخريطة — شاشةٌ كاملة.
///
/// **المؤشّر ثابتٌ في الوسط والخريطة تتحرّك تحته.** لا يُطلب من المستخدم
/// أن يصيب نقطةً بإصبعه على شاشةٍ صغيرة وهو واقفٌ في الشارع؛ بل يُحرّك
/// الخريطة حتى يقع المكان تحت المؤشّر. وهو ما اعتاده في كل تطبيق خرائط.
///
/// **والعنوان يُقرأ بعد أن تهدأ الحركة.** طلبُ عنوانٍ مع كل بكسل يزحف
/// يُغرق الخدمة ويُبطئ الخريطة — فننتظر نصف ثانية من السكون.
class LocationPickerScreen extends ConsumerStatefulWidget {
  const LocationPickerScreen({
    super.key,
    required this.title,
    required this.markerIcon,
    this.initial,
    this.confirmLabel = 'تأكيد الموقع',
  });

  final String title;
  final IconData markerIcon;
  final LatLng? initial;
  final String confirmLabel;

  @override
  ConsumerState<LocationPickerScreen> createState() => _PickerState();
}

class _PickerState extends ConsumerState<LocationPickerScreen> {
  final _map = MapController();

  final _query = TextEditingController();

  LatLng? _center;
  String _address = '';
  bool _reading = false;
  bool _moving = false;
  Timer? _settle;

  /// **البحث بالاسم لا بالإصبع وحده.** من يعرف اسم المحل لا يجوز أن
  /// يُطلب منه أن يجده بتحريك الخريطة من طرف المدينة إلى طرفها.
  Timer? _searchDebounce;
  List<PlaceResult> _results = const [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _center = widget.initial;
    if (_center == null) {
      _seed();
    } else {
      _readAddress(_center!);
    }
  }

  void _onQueryChanged(String q) {
    _searchDebounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }

    // نصف ثانية من السكون — كل حرفٍ يُرسل طلباً بلا هذا.
    _searchDebounce = Timer(const Duration(milliseconds: 500), () async {
      setState(() => _searching = true);
      try {
        final r = await ref
            .read(geoServiceProvider)
            .search(q, near: _center);
        if (mounted) setState(() => _results = r);
      } catch (_) {
        if (mounted) setState(() => _results = const []);
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _goTo(PlaceResult r) {
    FocusScope.of(context).unfocus();
    setState(() {
      _results = const [];
      _query.text = r.name;
      _center = r.point;
      _address = r.address;
    });
    _map.move(r.point, 17);
  }

  @override
  void dispose() {
    _query.dispose();
    _searchDebounce?.cancel();
    _settle?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _seed() async {
    final p = await ref.read(geoServiceProvider).lastKnown();
    if (p == null || !mounted) return;
    setState(() => _center = p);
    try {
      _map.move(p, 16);
    } catch (_) {
      // الخريطة لم تُبنَ بعد — `initialCenter` يلتقطه.
    }
    _readAddress(p);
  }

  /// **يتبع تحريكي أنا لا كل تحريك.** الخريطة تُطلق الحدث أثناء
  /// الرسم أيضاً، وقراءة العنوان عندها تُهدر النداءات بلا سبب.
  void _onMove(MapCamera camera, bool hasGesture) {
    if (!hasGesture) return;
    _settle?.cancel();
    setState(() => _moving = true);
    _settle = Timer(const Duration(milliseconds: 500), () {
      final c = camera.center;
      setState(() {
        _center = c;
        _moving = false;
      });
      _readAddress(c);
    });
  }

  Future<void> _readAddress(LatLng p) async {
    setState(() => _reading = true);
    try {
      final a = await ref.read(geoServiceProvider).addressOf(p);
      if (mounted) setState(() => _address = a);
    } catch (_) {
      if (mounted) setState(() => _address = '');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _goToMe() async {
    try {
      final pos = await ref.read(geoServiceProvider).currentPosition();
      final p = LatLng(pos.latitude, pos.longitude);
      _map.move(p, 16);
      setState(() => _center = p);
      _readAddress(p);
    } catch (_) {
      // إذنٌ مرفوض أو موقعٌ متعذّر — الخريطة تبقى حيث هي.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter:
                  _center ?? const LatLng(31.0439, 46.2570), // الناصرية
              initialZoom: 16,
              onPositionChanged: _onMove,
            ),
            children: [
              TileLayer(
                urlTemplate: MapEndpoints.tiles,
                // محفوظةٌ على الهاتف ثلاثين يوماً — انظر ZanbourTiles.
                tileProvider: ZanbourTiles.provider(),
                userAgentPackageName: 'iq.zanbour.rider',
              ),
            ],
          ),

          // ---- البحث ----
          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: Column(
              children: [
                Material(
                  elevation: 3,
                  borderRadius: BorderRadius.circular(12),
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'ابحث عن مكان…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.2),
                              ),
                            )
                          : (_query.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _query.clear();
                                    setState(() => _results = const []);
                                  },
                                )),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surface,
                    ),
                    onChanged: (v) {
                      setState(() {});
                      _onQueryChanged(v);
                    },
                  ),
                ),

                if (_results.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    constraints: const BoxConstraints(maxHeight: 260),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(blurRadius: 6, color: Colors.black26),
                      ],
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = _results[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.place_outlined, size: 20),
                          title: Text(r.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(r.address,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => _goTo(r),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // **المؤشّر فوق الخريطة لا فيها.** طبقةُ علاماتٍ تتحرّك مع
          // الخريطة، وهذا يجب أن يبقى في الوسط تماماً.
          IgnorePointer(
            child: Center(
              child: Padding(
                // نصف ارتفاع الأيقونة: طرفها السفليّ هو النقطة لا مركزها.
                padding: const EdgeInsets.only(bottom: 40),
                child: Icon(
                  widget.markerIcon,
                  size: 44,
                  color: theme.colorScheme.primary,
                  shadows: const [
                    Shadow(blurRadius: 8, color: Colors.black38),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            right: 16,
            bottom: 150,
            child: FloatingActionButton.small(
              heroTag: 'me',
              onPressed: _goToMe,
              child: const Icon(Icons.my_location),
            ),
          ),

          // ---- شريط التأكيد ----
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              elevation: 8,
              color: theme.colorScheme.surface,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(widget.markerIcon,
                              size: 20, color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _moving
                                  ? 'حرّك الخريطة…'
                                  : _reading
                                      ? 'جارٍ قراءة العنوان…'
                                      : (_address.isEmpty
                                          ? 'حرّك الخريطة لتحديد المكان'
                                          : _address),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      FilledButton(
                        onPressed: (_center == null || _moving)
                            ? null
                            : () => Navigator.pop(
                                  context,
                                  PickedPlace(_center!, _address),
                                ),
                        style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52)),
                        child: Text(widget.confirmLabel,
                            style: const TextStyle(fontSize: 16)),
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
