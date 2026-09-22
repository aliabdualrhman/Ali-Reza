import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';
import 'trip_repository.dart';
import '../../core/guest_gate.dart';

/// مراحل اختيار الرحلة.
enum _Stage {
  /// تأكيد نقطة الانطلاق
  pickup,

  /// اختيار الوجهة
  dropoff,

  /// اختيار وجهة ثانية — رحلة متعددة المحطات
  dropoff2,

  /// عرض الأجرة وتأكيد الطلب
  confirm,
}

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _map = MapController();
  final _searchCtrl = TextEditingController();

  /// بغداد — **ملاذ أخير** لجهاز لم يحدّد موقعه قطّ. الترتيب المقصود:
  /// نقطة انطلاق محدَّدة، فآخر موقع معروف، فهذه.
  static const _fallbackCenter = LatLng(33.3152, 44.3661);

  /// آخر موقع معروف — يُركّز الخريطة لحظة فتحها، قبل أن تثبت قراءة GPS.
  LatLng? _seed;

  _Stage _stage = _Stage.pickup;

  LatLng? _pickup;
  String _pickupAddress = '';
  LatLng? _dropoff;
  String _dropoffAddress = '';

  /// الوجهة الثانية ومسارها من الأولى. `null` = رحلة بمحطة واحدة.
  LatLng? _dropoff2;
  String _dropoff2Address = '';
  RouteResult? _leg2;

  /// توقف في الطريق — زيادة على الأجرة مقابل انتظار السائق.
  var _stopover = false;

  /// نوع المركبة المطلوبة: 'bike' أو 'tuktuk'.
  var _vehicleKind = 'bike';

  RouteResult? _route;
  Map<String, dynamic>? _fare;

  /// الكوبون المطبَّق، كما ردّته القاعدة. `null` = لا كوبون.
  Map<String, dynamic>? _coupon;
  final _couponCtl = TextEditingController();
  bool _couponBusy = false;
  String? _couponError;

  bool _locating = true;
  bool _working = false;
  String? _error;

  List<PlaceResult> _results = const [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // نؤجّل لما بعد أول إطار: طلب الإذن يفتح حواراً نظامياً، وفتحه
    // أثناء بناء الشجرة يسبب وميضاً وأحياناً تعليقاً.
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateMe());
    // وبالتوازي: نركّز الخريطة على آخر موقع معروف فوراً. تثبيت قراءة
    // GPS يأخذ ثوانيَ يرى فيها الراكب مدينة ليست مدينته.
    _seedFromLastKnown();
  }

  Future<void> _seedFromLastKnown() async {
    // **الإذن أولاً.** `lastKnown` تقرأ موقعاً مخزّناً ولا تطلب إذناً،
    // فعلى تثبيتٍ جديد تعود فارغةً أبداً — وتبقى الخريطة على نقطةٍ
    // مكتوبة في الكود حتى يضغط المستخدم زرّ القنّاص بنفسه.
    await ref.read(geoServiceProvider).ensurePermission();
    if (!mounted) return;

    final p = await ref.read(geoServiceProvider).lastKnown();
    // `_locateMe` قد تكون سبقتنا بقراءة حقيقية — لا نُرجع الكاميرا للوراء.
    if (p == null || !mounted || _pickup != null) return;
    setState(() => _seed = p);
    try {
      _map.move(p, 16);
    } catch (_) {
      // الخريطة لم تُبنَ بعد — `initialCenter` سيلتقط `_seed`.
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _couponCtl.dispose();
    _map.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // الموقع
  // ---------------------------------------------------------------------------
  Future<void> _locateMe() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final pos = await ref.read(geoServiceProvider).currentPosition();
      final here = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      _map.move(here, 16);
      setState(() => _pickup = here);
      await _refreshCenterAddress(here);
    } on GeoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// يحدّث نص العنوان تحت الدبوس المركزي.
  Future<void> _refreshCenterAddress(LatLng p) async {
    final addr = await ref.read(geoServiceProvider).addressOf(p);
    if (!mounted) return;
    setState(() {
      if (_stage == _Stage.pickup) {
        _pickup = p;
        _pickupAddress = addr;
      } else if (_stage == _Stage.dropoff) {
        _dropoff = p;
        _dropoffAddress = addr;
      } else if (_stage == _Stage.dropoff2) {
        _dropoff2 = p;
        _dropoff2Address = addr;
      }
    });
  }

  /// يُستدعى بعد أن يتوقف المستخدم عن تحريك الخريطة.
  void _onMapIdle(MapCamera cam) {
    if (_stage == _Stage.confirm) return;
    // تأخير قصير يمنع نداء عكس-الترميز مع كل بكسل حركة. الحدّ عند
    // Geoapify خمسة طلبات في الثانية، وكل نداء يستهلك رصيداً — فالتأخير
    // يحمي الحصّة قبل أن يحمي الحدّ.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600),
        () => _refreshCenterAddress(cam.center));
  }

  // ---------------------------------------------------------------------------
  // البحث
  // ---------------------------------------------------------------------------
  void _onSearchChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        // نقيّد البحث بمنطقة الخدمة التي يقف فيها الراكب: بلا هذا يبحث
        // عن «الكرادة» في الناصرية فتأتيه بغداد، فيطلب رحلة إلى مدينة
        // أخرى بحسن نية. الحدود من `pricing_zones` — أي مما يفعّله
        // المدير من اللوحة.
        final here = _pickup ?? _seed;
        final area = here == null
            ? null
            : await ref.read(serviceAreaProvider(here).future);
        final r = await ref
            .read(geoServiceProvider)
            .search(q, area: area, near: here);
        if (mounted) setState(() => _results = r);
      } catch (_) {
        if (mounted) setState(() => _results = const []);
      }
    });
  }

  void _pickResult(PlaceResult r) {
    FocusScope.of(context).unfocus();
    _searchCtrl.clear();
    setState(() => _results = const []);
    _map.move(r.point, 16);
    setState(() {
      if (_stage == _Stage.pickup) {
        _pickup = r.point;
        _pickupAddress = r.name;
      } else {
        _dropoff = r.point;
        _dropoffAddress = r.name;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // الانتقال بين المراحل
  // ---------------------------------------------------------------------------
  /// **تثبيت النقطة فوراً عند الضغط.**
  ///
  /// النقطة كانت تُسجَّل بعد ٦٠٠ ميلي ثانية من سكون الخريطة، **ثم** بعد
  /// أن يعود العنوان من الشبكة. فمن حرّك الخريطة وضغط في الحال وجد
  /// `_estimate` ترجع صامتةً لأن الوجهة ما زالت فارغة — فيضغط ثانيةً
  /// وثالثة حتى يلحق النداءُ ضغطتَه.
  ///
  /// فنأخذ مركز الخريطة في اللحظة نفسها، ونترك العنوان يصل متى وصل:
  /// الحساب يحتاج الإحداثيات وحدها، والعنوان نصٌّ للعرض.
  void _commitCenter() {
    _debounce?.cancel();
    final c = _map.camera.center;

    setState(() {
      if (_stage == _Stage.pickup) {
        _pickup = c;
      } else if (_stage == _Stage.dropoff) {
        _dropoff = c;
      } else if (_stage == _Stage.dropoff2) {
        _dropoff2 = c;
      }
    });

    // العنوان يلحق بعدها بلا أن يوقف شيئاً.
    _refreshCenterAddress(c);
  }

  Future<void> _next() async {
    _commitCenter();

    if (_stage == _Stage.pickup) {
      setState(() {
        _stage = _Stage.dropoff;
        _dropoff = null;
        _dropoffAddress = '';
      });
      return;
    }

    if (_stage == _Stage.dropoff || _stage == _Stage.dropoff2) {
      await _estimate();
    }
  }

  void _back() {
    setState(() {
      _error = null;
      if (_stage == _Stage.dropoff2) {
        _stage = _Stage.dropoff;
        _dropoff2 = null;
        _dropoff2Address = '';
      } else if (_stage == _Stage.confirm) {
        _stage = _Stage.dropoff;
        _route = null;
        _fare = null;
        _coupon = null;   // مسار جديد يعني أجرة جديدة، والخصم محسوب عليها
      } else if (_stage == _Stage.dropoff) {
        _stage = _Stage.pickup;
        if (_pickup != null) _map.move(_pickup!, 16);
      }
    });
  }

  /// يحسب المسار ثم يسأل قاعدة البيانات عن الأجرة.
  ///
  /// **لماذا لا نحسب الأجرة في التطبيق؟** لأنه يعمل على جهاز المستخدم.
  /// من يفكك ملف APK يستطيع تعديل الحساب وطلب رحلة بأجرة صفر. القاعدة
  /// هي مصدر السعر الوحيد، والتطبيق يعرض ما تقوله.
  Future<void> _estimate() async {
    if (_pickup == null || _dropoff == null) return;

    setState(() {
      _working = true;
      _error = null;
    });

    try {
      final route =
          await ref.read(geoServiceProvider).route(_pickup!, _dropoff!);

      // المرحلة الثانية تُقاس **من الوجهة الأولى** لا من نقطة الانطلاق:
      // السائق يواصل من حيث وقف، والمسافة من الانطلاق تحسبها مرتين.
      RouteResult? leg2;
      if (_dropoff2 != null) {
        leg2 = await ref.read(geoServiceProvider).route(_dropoff!, _dropoff2!);
      }

      final fare = await ref
          .read(supabaseProvider)
          .rpc('estimate_multi_trip', params: {
        'p_pickup_lat': _pickup!.latitude,
        'p_pickup_lng': _pickup!.longitude,
        'p_leg1_m': route.distanceMeters,
        'p_leg1_s': route.durationSeconds,
        'p_leg2_m': leg2?.distanceMeters,
        'p_leg2_s': leg2?.durationSeconds,
        'p_stopover': _stopover,
        'p_kind': _vehicleKind,
      }) as Map<String, dynamic>;

      if (!mounted) return;

      if (fare['available'] != true) {
        setState(() => _error =
            (fare['message'] as String?) ?? 'الخدمة غير متوفرة هنا');
        return;
      }

      setState(() {
        _route = route;
        _leg2 = leg2;
        _fare = fare;
        _stage = _Stage.confirm;
      });

      _fitRoute(route.polyline);
    } on GeoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// يضبط الخريطة لتُظهر المسار كاملاً.
  void _fitRoute(List<LatLng> line) {
    if (line.isEmpty) return;
    _map.fitCamera(
      CameraFit.coordinates(
        coordinates: line,
        padding: const EdgeInsets.fromLTRB(48, 120, 48, 280),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // البناء
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showCenterPin = _stage != _Stage.confirm;

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _pickup ?? _seed ?? _fallbackCenter,
              initialZoom: 15,
              minZoom: 5,
              maxZoom: 18,
              onPositionChanged: (cam, hasGesture) {
                if (hasGesture) _onMapIdle(cam);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: MapEndpoints.tiles,
                // محفوظةٌ على الهاتف ثلاثين يوماً — انظر ZanbourTiles.
                tileProvider: ZanbourTiles.provider(),
                // إلزامي بسياسة استخدام خوادم OSM — الطلب المجهول يُحظر
                userAgentPackageName: 'com.zanbour.rider',
                maxZoom: 19,
              ),
              if (_route != null)
                PolylineLayer(polylines: [
                  Polyline(
                    points: _route!.polyline,
                    strokeWidth: 5,
                    color: theme.colorScheme.primary,
                  ),
                ]),
              MarkerLayer(markers: [
                if (_pickup != null && _stage != _Stage.pickup)
                  _marker(_pickup!, Icons.trip_origin, theme.colorScheme.primary),
                if (_dropoff != null && _stage == _Stage.confirm)
                  _marker(_dropoff!, Icons.location_on, theme.colorScheme.error),
                if (_dropoff2 != null && _stage == _Stage.confirm)
                  _marker(_dropoff2!, Icons.flag, theme.colorScheme.tertiary),
              ]),
              // شعار المصدر — شرط ترخيص OpenStreetMap، لا خيار تجميلي
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(MapEndpoints.attribution),
                ],
              ),
            ],
          ),

          // الدبوس الثابت في المنتصف.
          //
          // نحرّك الخريطة تحت دبوس ثابت بدل سحب دبوس فوق خريطة ثابتة:
          // أدق بيد واحدة، ولا يحجب الإصبعُ الهدفَ أثناء التحديد.
          if (showCenterPin)
            IgnorePointer(
              child: Center(
                child: Transform.translate(
                  offset: const Offset(0, -18),
                  child: Icon(
                    _stage == _Stage.pickup
                        ? Icons.my_location
                        : Icons.location_on,
                    size: 44,
                    color: _stage == _Stage.pickup
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                    shadows: const [
                      Shadow(blurRadius: 6, color: Colors.black38),
                    ],
                  ),
                ),
              ),
            ),

          _topBar(theme),
          if (_results.isNotEmpty) _resultsList(theme),
          _bottomPanel(theme),

          if (_locating)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Marker _marker(LatLng p, IconData icon, Color color) => Marker(
        point: p,
        width: 44,
        height: 44,
        child: Icon(icon, color: color, size: 34),
      );

  // ---------------------------------------------------------------------------
  Widget _topBar(ThemeData theme) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      right: 12,
      child: Row(
        children: [
          if (_stage != _Stage.pickup)
            _circleButton(Icons.arrow_forward, _back, theme),
          if (_stage != _Stage.pickup) const SizedBox(width: 8),
          Expanded(
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(14),
              color: theme.colorScheme.surface,
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearchChanged,
                enabled: _stage != _Stage.confirm,
                decoration: InputDecoration(
                  hintText: _stage == _Stage.pickup
                      ? 'ابحث عن نقطة انطلاقك'
                      : 'إلى أين تريد الذهاب؟',
                  prefixIcon: const Icon(Icons.search),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback onTap, ThemeData theme) {
    return Material(
      elevation: 3,
      shape: const CircleBorder(),
      color: theme.colorScheme.surface,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(12), child: Icon(icon)),
      ),
    );
  }

  Widget _resultsList(ThemeData theme) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 68,
      left: 12,
      right: 12,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(14),
        color: theme.colorScheme.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _results.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = _results[i];
              return ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: r.address.isEmpty
                    ? null
                    : Text(r.address,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _pickResult(r),
              );
            },
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  Widget _bottomPanel(ThemeData theme) {
    return Positioned(
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
                if (_stage != _Stage.confirm) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _stage == _Stage.pickup
                                  ? 'من أين تنطلق؟'
                                  : 'إلى أين؟',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _stage == _Stage.pickup
                                  ? (_pickupAddress.isEmpty
                                      ? 'حرّك الخريطة لتحديد الموقع'
                                      : _pickupAddress)
                                  : (_dropoffAddress.isEmpty
                                      ? 'حرّك الخريطة لتحديد الوجهة'
                                      : _dropoffAddress),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: _locating ? null : _locateMe,
                        icon: const Icon(Icons.my_location),
                        tooltip: 'موقعي الحالي',
                      ),
                    ],
                  ),
                ] else
                  _fareCard(theme),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            size: 18,
                            color: theme.colorScheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_error!,
                              style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer)),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _working ? null : (_stage == _Stage.confirm
                      ? _requestTrip
                      : _next),
                  child: _working
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4))
                      : Text(switch (_stage) {
                          _Stage.pickup => 'تأكيد نقطة الانطلاق',
                          _Stage.dropoff => 'حساب الأجرة',
                          _Stage.dropoff2 => 'حساب الأجرة',
                          _Stage.confirm => 'اطلب الرحلة',
                        }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// نسبة زيادة التكتك كما تعيدها القاعدة — لا رقم مكتوب هنا يتقادم
  /// يوم نغيّرها في `pricing_zones`.
  int get _tuktukPct =>
      ((_fare?['tuktuk_pct'] as num?) ?? 45).round();

  Widget _fareCard(ThemeData theme) {
    final f = _fare!;
    final total = (f['total'] as num).toDouble();
    final km = (_route!.distanceMeters / 1000);
    final min = (_route!.durationSeconds / 60).round();
    final drivers = (f['nearby_drivers'] as num?)?.toInt() ?? 0;
    final surge = (f['surge_multiplier'] as num?)?.toDouble() ?? 1.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // **المُنتقي فوق السعر لا في "خيارات أخرى".** التكتك ليس تفصيلاً
        // متقدماً بل اختياراً أساسياً — من يريده يريده قبل أن ينظر إلى
        // الرقم، وإخفاؤه في قائمة مطوية يعني أن أحداً لن يجده.
        SegmentedButton<String>(
          segments: [
            const ButtonSegment(
              value: 'bike',
              icon: Icon(Icons.two_wheeler),
              label: Text('دراجة'),
            ),
            ButtonSegment(
              value: 'tuktuk',
              icon: const Icon(Icons.electric_rickshaw),
              label: Text('تكتك +$_tuktukPct٪'),
            ),
          ],
          selected: {_vehicleKind},
          onSelectionChanged: (v) {
            setState(() => _vehicleKind = v.first);
            _estimate();
          },
        ),
        const SizedBox(height: 16),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${total.round()} دينار',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text('${km.toStringAsFixed(1)} كم · $min دقيقة',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (surge > 1.0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('ذروة ×$surge',
                    style: TextStyle(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(Icons.two_wheeler,
                size: 18,
                color: drivers > 0
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error),
            const SizedBox(width: 6),
            Text(
              drivers > 0
                  ? '$drivers سائق قريب منك'
                  : 'لا يوجد سائقون متاحون الآن',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'الدفع نقداً للسائق عند الوصول',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),

        const Divider(height: 28),
        _optionsPanel(theme),
        const SizedBox(height: 12),
        _couponBox(theme, total),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // خيارات أخرى للرحلة
  // ---------------------------------------------------------------------------
  /// **مطوية افتراضياً.** أكثر الرحلات نقطتان بلا توقف، وعرضُ الخيارات
  /// مفتوحةً يزاحم الأجرة وزر الطلب — وهما ما جاء الراكب من أجله.
  Widget _optionsPanel(ThemeData theme) {
    final f = _fare!;
    final leg2 = (f['leg2_fare'] as num?)?.round() ?? 0;
    final stopAdd = (f['stopover_add'] as num?)?.round() ?? 0;
    final freeMin = (f['stopover_free_minutes'] as num?)?.round() ?? 10;

    return Theme(
      // إزالة الخطوط الفاصلة التي يرسمها ExpansionTile افتراضياً —
      // البطاقة لها حدودها وهي تكفي.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: _dropoff2 != null || _stopover,
        leading: const Icon(Icons.tune),
        title: const Text('خيارات أخرى للرحلة'),
        subtitle: (_dropoff2 == null && !_stopover)
            ? null
            : Text(
                [
                  if (_dropoff2 != null) 'وجهة ثانية (+$leg2)',
                  if (_stopover) 'توقف (+$stopAdd)',
                ].join(' · '),
                style: TextStyle(color: theme.colorScheme.primary),
              ),
        children: [
          // ---- وجهة ثانية ----
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.add_location_alt_outlined),
            title: const Text('وجهة ثانية'),
            subtitle: Text(
              _dropoff2 == null
                  ? 'المرحلة الثانية بخصم ١٠٪ — بلا أجرة بداية جديدة'
                  : _dropoff2Address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _dropoff2 == null
                ? TextButton(
                    onPressed: () => setState(() {
                      _stage = _Stage.dropoff2;
                      _dropoff2 = null;
                      _dropoff2Address = '';
                    }),
                    child: const Text('إضافة'),
                  )
                : IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'إزالة',
                    onPressed: () {
                      setState(() {
                        _dropoff2 = null;
                        _dropoff2Address = '';
                        _leg2 = null;
                      });
                      _estimate();
                    },
                  ),
          ),

          // ---- التوقف في الطريق ----
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _stopover,
            onChanged: (v) {
              setState(() => _stopover = v);
              _estimate();
            },
            secondary: const Icon(Icons.pause_circle_outline),
            title: const Text('التوقف في الطريق'),
            subtitle: Text('زيادة ١٥٪ — ينتظرك السائق حتى $freeMin دقائق'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // الكوبون
  // ---------------------------------------------------------------------------
  /// صندوق الكوبون — بعد الأجرة وقبل زر الطلب.
  ///
  /// **موضعه مقصود:** الخصم نسبة من الأجرة، فلا معنى له قبل حسابها. ووضعه
  /// بعد زر الطلب يجعل الراكب يطلب ثم يكتشف أنه نسي كوبونه.
  Widget _couponBox(ThemeData theme, double total) {
    final applied = _coupon;

    if (applied != null) {
      final pct = (applied['discount_pct'] as num).round();
      final disc = (applied['discount_iqd'] as num).round();
      final after = (applied['fare_after'] as num).round();

      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.local_offer, color: theme.colorScheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('خصم $pct٪ — وفّرت $disc دينار',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text('تدفع $after دينار بدل ${total.round()}',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                _coupon = null;
                _couponCtl.clear();
                _couponError = null;
              }),
              child: const Text('إزالة'),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _couponCtl,
                enabled: !_couponBusy,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'كوبون خصم',
                  prefixIcon: Icon(Icons.local_offer_outlined),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _applyCoupon(total),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _couponBusy ? null : () => _applyCoupon(total),
              style: FilledButton.styleFrom(
                  minimumSize: const Size(88, 48)),
              child: _couponBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2))
                  : const Text('تطبيق'),
            ),
          ],
        ),
        if (_couponError != null) ...[
          const SizedBox(height: 8),
          Text(_couponError!,
              style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  Future<void> _applyCoupon(double total) async {
    final code = _couponCtl.text.trim();
    if (code.isEmpty) return;
    // الكوبون مربوطٌ بحسابٍ يُستعمل مرةً فيه — لا معنى له لضيف.
    if (!await requireAccountHere(context, ref,
        reason: 'سجّل الدخول لتستعمل رمز الخصم.')) {
      return;
    }

    setState(() {
      _couponBusy = true;
      _couponError = null;
    });
    try {
      final res = await ref
          .read(supabaseProvider)
          .rpc('check_coupon', params: {'p_code': code, 'p_fare': total});
      if (mounted) {
        setState(() => _coupon = Map<String, dynamic>.from(res as Map));
      }
    } catch (e) {
      if (mounted) setState(() => _couponError = AppError.message(e));
    } finally {
      if (mounted) setState(() => _couponBusy = false);
    }
  }

  Future<void> _requestTrip() async {
    if (_pickup == null || _dropoff == null || _route == null) return;

    // **الضيف يصل إلى هنا بكامل اختياره** — نقطتان وأجرةٌ محسوبة —
    // ويُسأل التسجيل عند الزرّ الأخير وحده. من رأى أجرته قبل أن يُسأل
    // يسجّل؛ ومن سُئل قبلها ينصرف.
    if (!await requireAccountHere(context, ref,
        reason: 'أنشئ حساباً مجانياً لتطلب رحلتك.')) {
      return;
    }

    setState(() {
      _working = true;
      _error = null;
    });

    try {
      await ref.read(tripRepositoryProvider).request(
            pickup: _pickup!,
            pickupAddress: _pickupAddress,
            dropoff: _dropoff!,
            dropoffAddress: _dropoffAddress,
            distanceMeters: _route!.distanceMeters,
            durationSeconds: _route!.durationSeconds,
            // نرسل الرمز لا الخصم المحسوب: القاعدة تعيد التحقق وتحسبه
            // بنفسها، فتطبيقٌ معدَّل لا يستطيع منح نفسه خصماً.
            couponCode: _coupon?['code'] as String?,
            stop2: _dropoff2,
            stop2Address: _dropoff2Address,
            leg2Meters: _leg2?.distanceMeters,
            leg2Seconds: _leg2?.durationSeconds,
            stopover: _stopover,
            vehicleKind: _vehicleKind,
          );

      if (!mounted) return;
      // pushReplacement لا push: الرجوع لشاشة اختيار الوجهة بعد الطلب
      // يسمح بطلب رحلة ثانية بينما الأولى تبحث، والقاعدة سترفضها
      // برسالة "لديك رحلة نشطة" وهو ارتباك بلا سبب.
      context.pushReplacement('/searching');
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}
