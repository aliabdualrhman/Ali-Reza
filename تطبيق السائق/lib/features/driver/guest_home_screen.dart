import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../../core/guest_gate.dart';
import '../auth/auth_repository.dart';

/// رئيسية السائق **الضيف** — شاشةٌ مستقلة لا رئيسية السائق نفسها.
///
/// **لماذا لا نُعيد استعمال `DriverHomeScreen`؟** كلُّ ما فيها قائمٌ على
/// سجلّ السائق: المحفظة، والحالة، والاعتماد، والمتتبّع، والتحقق من
/// الإشعارات. وتشغيلُها بلا سجلّ يعني عشرات الفحوص عن `null` مبعثرةً في
/// شاشةٍ حسّاسة — وخطأٌ واحدٌ فيها يكسر السائق الحقيقي لا الضيف.
///
/// فالضيف يرى هنا ما يحتاجه ليقرّر: الخريطة على مدينته، وكيف يعمل،
/// وما الوثائق التي سيُطلب منه رفعها. و«متصل» يدعوه إلى التسجيل.
class GuestHomeScreen extends ConsumerStatefulWidget {
  const GuestHomeScreen({super.key});

  @override
  ConsumerState<GuestHomeScreen> createState() => _GuestHomeScreenState();
}

class _GuestHomeScreenState extends ConsumerState<GuestHomeScreen> {
  final _map = MapController();
  LatLng? _here;

  @override
  void initState() {
    super.initState();
    // الإذن عند أول ظهورٍ للخريطة — كما في رئيسية السائق.
    WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
  }

  Future<void> _locate() async {
    final geo = ref.read(geoServiceProvider);
    if (!await geo.ensurePermission() || !mounted) return;

    final last = await geo.lastKnown();
    if (last != null && mounted) _moveTo(last);

    try {
      final p = await geo.currentPosition();
      if (mounted) _moveTo(LatLng(p.latitude, p.longitude));
    } catch (_) {
      // GPS مطفأ أو بطيء — يبقى آخر موقعٍ معروف.
    }
  }

  void _moveTo(LatLng p) {
    setState(() => _here = p);
    try {
      _map.move(p, 16);
    } catch (_) {
      // الخريطة لم تُبنَ بعد — `initialCenter` يلتقط `_here`.
    }
  }

  Future<void> _gate([String? reason]) => requireAccountHere(
        context,
        ref,
        reason: reason ?? 'سجّل كسائق لتبدأ استقبال الطلبات.',
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('كابتن زنبور'),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(guestModeProvider.notifier).exit();
              context.go('/login');
            },
            child: const Text('تسجيل الدخول'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter:
                        _here ?? const LatLng(31.0439, 46.2575), // الناصرية
                    initialZoom: 14,
                    minZoom: 5,
                    maxZoom: 18,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: MapEndpoints.tiles,
                      tileProvider: ZanbourTiles.provider(),
                      userAgentPackageName: 'com.zanbour.driver',
                      maxZoom: 19,
                    ),
                    if (_here != null)
                      MarkerLayer(markers: [
                        Marker(
                          point: _here!,
                          width: 48,
                          height: 48,
                          child: Icon(Icons.two_wheeler,
                              size: 38, color: theme.colorScheme.primary),
                        ),
                      ]),
                    const RichAttributionWidget(attributions: [
                      TextSourceAttribution(MapEndpoints.attribution),
                    ]),
                  ],
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: GuestBanner(onSignIn: () => _gate()),
                ),
                Positioned(
                  bottom: 12,
                  left: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'guest-locate',
                    tooltip: 'موقعي',
                    onPressed: _locate,
                    child: const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 6,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                // **الزرّ الذي يبحث عنه كلُّ سائق** — في مكانه المعتاد،
                // ويقود إلى التسجيل بدل أن يختفي.
                FilledButton.icon(
                  onPressed: () => _gate(),
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('اتصل وابدأ استقبال الطلبات'),
                ),
                const SizedBox(height: 20),
                Text('كيف تعمل مع زنبور',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const _Step(
                    n: 1,
                    text: 'سجّل حسابك وارفع وثائقك من داخل التطبيق.'),
                const _Step(
                    n: 2, text: 'تراجع الإدارة وثائقك وتعتمد حسابك.'),
                const _Step(
                    n: 3,
                    text: 'اضغط «متصل» فتصلك طلبات الركّاب والتسوّق القريبة.'),
                const _Step(
                    n: 4, text: 'اقبض أجرتك نقداً من الراكب عند الوصول.'),
                const SizedBox(height: 20),
                Text('الوثائق المطلوبة',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                // **من المصدر نفسه الذي تقرؤه شاشة الوثائق.** قائمةٌ
                // مكتوبة هنا تتخلّف عنه يوم تُضاف وثيقة.
                for (final d in DriverDocument.values)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      d.required
                          ? Icons.check_circle_outline
                          : Icons.radio_button_unchecked,
                      color: d.required
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                    title: Text(d.label),
                    trailing: d.required
                        ? null
                        : Text('اختيارية',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                  ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    ref.read(guestModeProvider.notifier).exit();
                    context.go('/signup');
                  },
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50)),
                  child: const Text('سجّل كسائق الآن'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});

  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text('$n',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
