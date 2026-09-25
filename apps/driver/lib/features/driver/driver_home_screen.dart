import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../../core/push_service.dart';
import '../auth/auth_repository.dart';
import 'driver_repository.dart';
import 'location_tracker.dart';
import 'push_check_screen.dart';

/// شاشة السائق الرئيسية: خريطة، مفتاح اتصال، وملخّص اليوم.
///
/// **ما لم يعد من مسؤوليتها:** إرسال الموقع. كان يعيش هنا فيموت بموت
/// الشاشة — عند قفل الهاتف، وعند الانتقال إلى شاشة العرض أو الرحلة.
/// انتقل إلى [LocationTracker] على مستوى التطبيق.
class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen> {
  final _map = MapController();

  bool _busy = false;
  String? _error;

  /// آخر موقع عُرض على الخريطة — نحرّك الكاميرا عند تغيّره فقط.
  Position? _shown;

  /// مركز مؤقّت من آخر موقع يحفظه النظام، ريثما تصل أول قراءة حيّة.
  LatLng? _seed;

  @override
  void initState() {
    super.initState();
    _seedFromLastKnown();
  }

  /// زرّ القنّاص — يقرأ الموقع حيّاً ويطلب الإذن إن لزم.
  ///
  /// **كان ناقصاً عند السائق وحده.** الراكب يملكه، والسائق لا — فإن
  /// فتح التطبيق قبل أن يضغط «متصل» رأى بغداد وهو في الناصرية، ولا
  /// سبيل له إلى موقعه إلا أن يتّصل. وهو غير المتصل بعد.
  bool _locating = false;

  Future<void> _locateMe() async {
    setState(() => _locating = true);
    try {
      final geo = ref.read(geoServiceProvider);
      final p = await geo.currentPosition();
      if (!mounted) return;
      _map.move(LatLng(p.latitude, p.longitude), 16);
    } on GeoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// **لماذا لا نكتفي بالمركز الاحتياطي الثابت؟** المتتبّع لا يعمل قبل
  /// أن يضغط السائق «متصل»، فالسائق غير المتصل يفتح التطبيق فيرى بغداد
  /// وهو في الناصرية. وآخر موقع معروف يحتفظ به النظام أصلاً ويعيده
  /// فوراً — بلا تشغيل GPS ولا انتظار ولا إذن جديد.
  Future<void> _seedFromLastKnown() async {
    // **الإذن أولاً — انظر تعليق الراكب نفسه.**
    await ref.read(geoServiceProvider).ensurePermission();
    if (!mounted) return;

    final p = await ref.read(geoServiceProvider).lastKnown();

    // **ثم قراءةٌ حيّة.** الموقع المخزّن قد يكون من مدينةٍ أخرى أو
    // عمرُه ساعات؛ ومن فتح التطبيق يريد أن يرى نفسه لا أثره.
    if (mounted && _shown == null) {
      unawaited(_locateMe());
    }
    // القراءة الحيّة أسبق دائماً: إن سبقتنا فلا نُرجع الكاميرا للوراء.
    if (p == null || !mounted || _shown != null) return;
    setState(() => _seed = p);
    // الخريطة قد تكون بُنيت قبل وصولنا (سجلّ السائق يُحمَّل أولاً)،
    // وحينها لا يُعاد قراءة `initialCenter` فنحرّك الكاميرا بأنفسنا.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _shown != null) return;
      try {
        _map.move(p, _map.camera.zoom);
      } catch (_) {
        // الخريطة لم تُبنَ بعد — `initialCenter` سيلتقط `_seed`.
      }
    });
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  /// يطلب استثناء التطبيق من تقييد البطارية **قبل** الاتصال.
  ///
  /// **لماذا حاجزٌ لا اقتراح في صفحة إعدادات؟** لأن أثره لا يظهر للسائق
  /// كعطل بل كسوء حظ: يضع الهاتف في جيبه، فيجمّده النظام، فينقطع المقبس
  /// ويتوقف إرسال الموقع، فيستبعده الخادم من التوزيع بعد دقيقتين. يبقى
  /// المفتاح أخضر ساعتين بلا طلب واحد، فيظن التطبيق فارغاً من الزبائن.
  ///
  /// وطبقات المصنّعين في سوقنا — شاومي وأوبو وفيفو وهواوي — لا تحترم
  /// الخدمة الأمامية وحدها. رصدناه والخدمة تعمل بنوع `location`.
  ///
  /// **ولا نمنعه من الاتصال إن رفض.** الإذن اختيار المستخدم، ومنعُه من
  /// العمل عقوبةٌ لا تُصلح شيئاً. نُعلمه ونمضي.
  Future<void> _ensureBackgroundAllowed() async {
    // **أندرويد وحده.** لا تجميدَ بالمعنى نفسه في iOS، ولا إعدادَ
    // يُفتح — وطلبُه هناك يُظهر للسائق حواراً لا يقود إلى شيء.
    if (!Platform.isAndroid) return;
    try {
      if (await Permission.ignoreBatteryOptimizations.isGranted) return;
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {
      // أجهزة لا تدعم الفحص أصلاً. لا نُفشل الاتصال بسببها.
    }
  }

  Future<void> _toggleOnline(bool on) async {
    final tracker = ref.read(locationTrackerProvider.notifier);

    // قبل أي شيء — وقبل إظهار المؤشّر، فحوار النظام يوقف كل شيء حتى يردّ.
    if (on) await _ensureBackgroundAllowed();
    if (!mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // نبدأ التتبّع **قبل** إعلان الاتصال: سائق حالته `online` بلا موقع
      // محدَّث يُستبعد من البحث، فيبدو متصلاً ولا تصله طلبات.
      if (on) await tracker.start();
      await ref.read(driverRepositoryProvider).setOnline(on);
      if (!on) await tracker.stop();

      // الشاشة مضاءة أثناء العمل: السائق ينظر للهاتف على المقود،
      // وانطفاؤها كل ٣٠ ثانية يجعل استعماله مستحيلاً. لا يمنع هذا
      // القفل اليدوي — والخدمة الأمامية تتكفّل بما بعده.
      await (on ? WakelockPlus.enable() : WakelockPlus.disable());
    } on GeoException catch (e) {
      await tracker.stop();
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      await tracker.stop();
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final driverAsync = ref.watch(driverRecordProvider);

    // الموقع يأتي من المتتبّع على مستوى التطبيق لا من هذه الشاشة.
    final pos = ref.watch(locationTrackerProvider);
    if (pos != null && pos != _shown) {
      _shown = pos;
      // بعد الإطار: تحريك الكاميرا أثناء البناء يرمي استثناء.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _map.move(LatLng(pos.latitude, pos.longitude), _map.camera.zoom);
        }
      });
    }

    // لا تنقّل يدوي هنا: **الموجّه** يتولّى التوجيه للعرض والرحلة.
    //
    // كان التنقّل من هنا يعمل في حالة واحدة فقط — التطبيق مفتوح على هذه
    // الشاشة. أما فتح إشعار أو إقلاع بارد فلا يمرّ بها إطلاقاً.

    // إشعار فُتح بعد فوات أوانه: الموجّه أعادنا إلى هنا، فنقول السبب بدل
    // أن يظن السائق أن الضغط لم يفعل شيئاً.
    ref.listen<bool>(missedOfferProvider, (_, missed) {
      if (!missed || !mounted) return;
      ref.read(missedOfferProvider.notifier).clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('انتهت مهلة هذا الطلب وانتقل إلى سائق آخر'),
          duration: Duration(seconds: 4),
        ),
      );
    });

    // **تحذير دائم حين تكون الإشعارات معطّلة.** سائق بلا إشعارات لا تصله
    // طلبات وهو يظن نفسه يعمل — ويكتشف بعد ساعات أن المشكلة إذنٌ رفضه
    // مرة. الفشل الصامت يجب أن يُرى.
    final push = ref.watch(pushDiagnosticsProvider).value;
    final pushBroken = push != null && !push.healthy;

    return Scaffold(
      body: driverAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppError.message(e))),
        data: (d) {
          if (d == null) {
            return const Center(child: Text('لا يوجد سجل سائق'));
          }
          final online = d.status != DriverStatus.offline;

          return Stack(
            children: [
              // تنبيه الإشعارات المعطّلة — فوق كل شيء وفي أعلى الشاشة.
              // موضعه مقصود: سائق لا تصله طلبات يجب أن يعرف السبب قبل
              // أن يظنّ التطبيق معطّلاً أو المدينة خالية من الركّاب.
              FlutterMap(
                mapController: _map,
                options: MapOptions(
                  // الترتيب: قراءة حيّة، فآخر موقع معروف، فبغداد أخيراً
                  // كملاذ لجهاز لم يحدّد موقعه قطّ.
                  initialCenter: pos != null
                      ? LatLng(pos.latitude, pos.longitude)
                      : _seed ?? const LatLng(33.3152, 44.3661),
                  initialZoom: 16,
                  minZoom: 5,
                  maxZoom: 18,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        MapEndpoints.tiles,
                    // محفوظةٌ على الهاتف ثلاثين يوماً — انظر ZanbourTiles.
                    tileProvider: ZanbourTiles.provider(),
                    userAgentPackageName: 'com.zanbour.driver',
                    maxZoom: 19,
                  ),
                  if (pos != null)
                    MarkerLayer(markers: [
                      Marker(
                        point: LatLng(pos.latitude, pos.longitude),
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

              _topBar(theme, d),

              // **زرّ القنّاص.** فوق اللوحة السفلية بمسافةٍ كافية.
              Positioned(
                bottom: 240,
                left: 16,
                child: FloatingActionButton.small(
                  heroTag: 'locate',
                  onPressed: _locating ? null : _locateMe,
                  backgroundColor: theme.colorScheme.surface,
                  child: _locating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : Icon(Icons.my_location,
                          color: theme.colorScheme.primary),
                ),
              ),
              // **بطاقةٌ عائمة تحت الشريط لا شريطٌ فوقه.** كان
              // التنبيه ملتصقاً بأعلى الشاشة يغطّي شريط التطبيق نفسه،
              // فيبدو عطلاً في الواجهة لا تنبيهاً مقصوداً — ويُتجاهَل
              // لأنه يشبه خطأً عابراً.
              if (pushBroken)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 74,
                  left: 0,
                  right: 0,
                  child: PushAlertCard(
                    notificationsOk: push.permissionGranted == true,
                    backgroundOk: push.batteryUnrestricted,
                    onFix: () => _openPushSetup(push),
                  ),
                ),

              _bottomPanel(theme, d, online),
            ],
          );
        },
      ),
    );
  }

  /// ورقة الإصلاح — ثلاث خطواتٍ مرقّمة بلا مصطلحات.
  ///
  /// **«إعادة مزامنة الرمز» جملةٌ لا يفهمها سائق.** لا يعرف ما «الرمز»
  /// ولا ما «المزامنة»، فيترك الزرّ ولا يضغطه — والعطل الذي يُصلحه هو
  /// أشيعها: رمزٌ في الجهاز يخالف المخزّن في الخادم، فتُرسل الطلبات
  /// إلى جهازٍ لم يعد موجوداً.
  /// سطرٌ واحد يُلخّص الحالة الفعلية — لنا لا للسائق.
  ///
  /// **الرمزان مقصوصان عمداً.** طولهما يتجاوز ١٥٠ حرفاً ولا يُقرأ منهما
  /// شيء، والمهمّ اختلافهما لا نصّهما.
  static String _diagnosticOf(PushDiagnostics d) {
    String cut(String? t) =>
        t == null ? 'null' : (t.length > 12 ? '${t.substring(0, 12)}…' : t);
    final parts = <String>[
      'permission=${d.permissionGranted}',
      'battery=${d.batteryUnrestricted}',
      'signedIn=${d.signedIn}',
      'device=${cut(d.deviceToken)}',
      'stored=${cut(d.storedToken)}',
      'match=${d.deviceToken != null && d.deviceToken == d.storedToken}',
    ];
    if (d.error != null) parts.add('error=${d.error}');
    return parts.join('\n');
  }

  Future<void> _openPushSetup(PushDiagnostics? d) async {
    await showPushSetupSheet(
      context,
      title: 'حتى تصلك الطلبات',
      diagnostic: d == null ? null : _diagnosticOf(d),
      steps: [
        // **ثلاثٌ على أندرويد واثنتان على iOS.** خطوةٌ لا يملك النظام
        // إعدادها تبقى بلا علامة مهما ضُغطت — والسائق يظنّ الخلل فيه.
        if (Platform.isAndroid)
          PushStep(
            title: 'فعّل العمل في الخلفية',
            detail: 'حتى لا يوقف الهاتف التطبيق وأنت لا تنظر إليه',
            done: d?.batteryUnrestricted != false,
            action: 'فتح',
            onTap: () async {
              await Permission.ignoreBatteryOptimizations.request();
              ref.invalidate(pushDiagnosticsProvider);
            },
          ),
        PushStep(
          title: 'فعّل الإشعارات',
          detail: 'حتى يرنّ هاتفك حين يصلك طلب',
          done: d?.permissionGranted == true,
          action: 'فتح',
          onTap: () async {
            await requestNotificationPermission();
            ref.invalidate(pushDiagnosticsProvider);
          },
        ),
        PushStep(
          title: 'اضغط هنا للتطبيق',
          detail: 'الخطوة الأخيرة — بعدها تصلك الطلبات',
          done: d?.healthy == true,
          action: 'تطبيق',
          onTap: () async {
            await ref.read(pushServiceProvider).resync();
            // نفحص قبل أن نقول «تمّ» — لا طمأنةَ على جهازٍ ما زال أصمّ.
            final now = await ref.refresh(pushDiagnosticsProvider.future);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(now.healthy
                      ? 'تمّ — جهازك جاهز الآن'
                      : 'لم يكتمل بعد — راجع الخطوات غير المعلَّمة بالأخضر'),
                ),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _topBar(ThemeData theme, DriverRecord d) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      right: 12,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(14),
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  color: d.walletBalance < 0
                      ? ZanbourTheme.warning
                      : theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.walletBalance < 0
                          ? 'عليك ${d.walletBalance.abs().round()} دينار'
                          : '${d.walletBalance.round()} دينار',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      d.bonusBalance > 0
                          ? 'هدية ${d.bonusBalance.round()} دينار'
                          : d.walletBalance < 0
                              ? 'عمولات مستحقة'
                              : 'رصيد المحفظة',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.account_balance_wallet_outlined),
                tooltip: 'الرصيد',
                onPressed: () => context.push('/wallet'),
              ),
              // **جرسٌ يقرأ من القاعدة لا من فايربيز.** الدفع يسقط عن
              // جزءٍ من سائقينا — أجهزةٌ بلا خدمات Google — والقائمة هي
              // ما يصل الجميع فعلاً.
              const NotificationsBell(),
              // قائمة بدل أزرار متجاورة: الشريط ضيق، وثلاث أيقونات
              // إضافية تزاحم الرصيد وهو أهم ما فيه.
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (v) async {
                  if (v == 'logout') {
                    // إيقاف التتبّع قبل الخروج: الخدمة الأمامية تبقى
                    // تعمل وإشعارها الدائم معلّقاً لو تركناها.
                    await ref.read(locationTrackerProvider.notifier).stop();
                    await WakelockPlus.disable();
                    await ref.read(authRepositoryProvider).signOut();
                  } else if (v == 'push-setup') {
                    // الورقة نفسها التي تفتحها البطاقة الحمراء — لا
                    // شاشةً تقنية تعرض «تطابق الرمزين».
                    await _openPushSetup(ref.read(pushDiagnosticsProvider).value);
                  } else if (context.mounted) {
                    context.push(v);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: '/account',
                    child: ListTile(
                      leading: Icon(Icons.person_outline),
                      title: Text('حسابي'),
                    ),
                  ),
                  PopupMenuItem(
                    value: '/my-trips',
                    child: ListTile(
                      leading: Icon(Icons.route),
                      title: Text('رحلاتي'),
                    ),
                  ),
                  // **الحوافز بعد «رحلاتي» مباشرةً.** كلاهما يجيب سؤال
                  // «ماذا كسبتُ؟»، والحافز هو ما يدفعه إلى رحلةٍ أخرى.
                  PopupMenuItem(
                    value: '/incentives',
                    child: ListTile(
                      leading: Icon(Icons.emoji_events_outlined),
                      title: Text('الحوافز'),
                    ),
                  ),
                  PopupMenuItem(
                    value: '/store-dues',
                    child: ListTile(
                      leading: Icon(Icons.storefront_outlined),
                      title: Text('مستحقات المتاجر'),
                    ),
                  ),
                  PopupMenuItem(
                    value: '/my-ratings',
                    child: ListTile(
                      leading: Icon(Icons.star_outline),
                      title: Text('تقييمي'),
                    ),
                  ),
                  PopupMenuItem(
                    value: '/documents',
                    child: ListTile(
                      leading: Icon(Icons.folder_outlined),
                      title: Text('وثائقي'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'push-setup',
                    child: ListTile(
                      leading: Icon(Icons.notifications_active_outlined),
                      title: Text('إعدادات الإشعارات'),
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'logout',
                    child: ListTile(
                      leading: Icon(Icons.logout),
                      title: Text('خروج'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// خيار سائق التكتك: يستقبل طلبات الدراجات أيضاً.
  ///
  /// **غير متماثل عمداً:** طلب التكتك لا يصل سائق دراجة مهما فعل —
  /// لا يستطيع خدمته مادياً. أما سائق التكتك فيستطيع خدمة الاثنين،
  /// فنترك له القرار.
  /// لوحةٌ تشرح لسائق الستوتة لماذا لا يرى مفاتيح الآخرين.
  Widget _stootaNotice(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.local_shipping_outlined,
              color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('مندوب ستوتة',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 3),
                Text(
                  'تصلك طلبات المتاجر التي تطلب ستوتة وحدها — '
                  'لا ركّاب ولا تسوّق.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tuktukOption(ThemeData theme, DriverRecord d) {
    if (!d.isTuktuk) return const SizedBox.shrink();

    return SwitchListTile(
      value: d.acceptsBikeTrips,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      secondary: const Icon(Icons.two_wheeler),
      title: const Text('أقبل طلبات الدراجات أيضاً'),
      subtitle: Text(
        d.acceptsBikeTrips
            ? 'تصلك طلبات التكتك والدراجات — وطلب الدراجة بسعر الدراجة'
            : 'تصلك طلبات التكتك وحدها',
        style: theme.textTheme.bodySmall,
      ),
      onChanged: (v) async {
        try {
          await ref.read(driverRepositoryProvider).setAcceptsBikeTrips(v);
          ref.invalidate(driverRecordProvider);
        } catch (e) {
          if (mounted) setState(() => _error = AppError.message(e));
        }
      },
    );
  }

  /// سائق التكتك يستقبل طرود الدراجة أيضاً — بسعر الدراجة الذي كتبه التاجر.
  Widget _tuktukDeliveryOption(ThemeData theme, DriverRecord d) {
    return SwitchListTile(
      value: d.acceptsBikeDeliveries,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      secondary: const Icon(Icons.two_wheeler),
      title: const Text('أقبل طلبات التوصيل بالدراجة أيضاً'),
      subtitle: Text(
        d.acceptsBikeDeliveries
            ? 'تصلك طرود التكتك والدراجة — وطرد الدراجة بسعره'
            : 'تصلك طرود التكتك وحدها',
        style: theme.textTheme.bodySmall,
      ),
      onChanged: (v) async {
        try {
          await ref.read(driverRepositoryProvider).setAcceptsBikeDeliveries(v);
          ref.invalidate(driverRecordProvider);
        } catch (e) {
          if (mounted) setState(() => _error = AppError.message(e));
        }
      },
    );
  }

  /// رسالة الإدارة مكان المفتاح المغلق.
  Widget _closedNotice(ThemeData theme, IconData icon, String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 24, color: theme.colorScheme.outline),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              message.isEmpty ? 'هذه الخدمة متوقّفة مؤقّتاً.' : message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// مفتاحا الخدمة — متساويان في الحجم وفي الوزن.
  ///
  /// **الاتصال نتيجتهما لا سببهما.** كان زرٌّ كبير مكتوبٌ عليه «ابدأ
  /// الاستقبال» لا يقول أيّ استقبال، ومفتاحٌ صغير للتسوّق تحته — فيظنّ
  /// السائق أن الكبير يحكم الصغير. فمن فتح واحداً فهو متصل، ومن أغلق
  /// الاثنين فهو غير متصل. ولا زرَّ ثالثاً يحكمهما.
  Widget _serviceSwitch({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required String on,
    required String off,
    required bool value,
    required Future<void> Function(bool) apply,
  }) {
    final busy = _busy;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: value
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SwitchListTile(
        value: value,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        secondary: Icon(icon,
            size: 26,
            color: value
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant),
        title: Text(title,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Text(value ? on : off, style: theme.textTheme.bodySmall),
        onChanged: busy ? null : (v) => _setService(apply, v),
      ),
    );
  }

  /// **يبدّل المفتاح ثم يُصحّح الاتصال.** فتحُ أيّ خدمة يُدخله الشبكة،
  /// وإغلاق الاثنين يُخرجه منها — بلا أن يبحث عن زرٍّ ثالث.
  ///
  /// **ويمرّ بـ`_toggleOnline` لا بـ`setOnline`.** الأولى تُشغّل تتبّع
  /// الموقع وتطلب إعفاء البطارية وتُبقي الشاشة مضاءة؛ والثانية تكتب
  /// حالةً في القاعدة وحدها. وسائقٌ حالته `online` بلا موقعٍ محدَّث
  /// يُستبعد من البحث — فيبدو متصلاً ولا تصله طلبات.
  Future<void> _setService(
      Future<void> Function(bool) apply, bool value) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    bool? target;
    try {
      await apply(value);

      final d = await ref.refresh(driverRecordProvider.future);
      final services = ref.read(serviceStatusProvider).value ??
          const ServiceAvailability.open();
      final any = d?.wantsWork(services) ?? false;

      // **لا نلمس الاتصال أثناء رحلة.** قطعُ التتبّع وسائقٌ في الطريق
      // يُفقد الراكب موقعه.
      if (d?.status != DriverStatus.onTrip &&
          any != (d?.status == DriverStatus.online)) {
        target = any;
      }
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (target != null && mounted) await _toggleOnline(target);
  }

  Widget _bottomPanel(ThemeData theme, DriverRecord d, bool online) {
    final services = ref.watch(serviceStatusProvider).value ??
        const ServiceAvailability.open();

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
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online
                            ? ZanbourTheme.success
                            : theme.colorScheme.outline,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(d.status.label,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.star, size: 16, color: Colors.amber),
                        const SizedBox(width: 4),
                        Text(d.ratingAvg.toStringAsFixed(1)),
                        const SizedBox(width: 12),
                        Text('${d.tripsCompleted} رحلة',
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // **المغلقة تُخفى ومكانها رسالة الإدارة.** مفتاحٌ
                // رماديّ سؤالٌ بلا جواب: يضغطه السائق فلا يقع شيء،
                // فيظنّ التطبيق معطوباً ويتصل بالدعم.
                // **سائق الستوتة لا يرى مفتاحَي الركّاب والتسوّق.**
                // القاعدة تثبّتهما مغلقَين (0105)، ومفتاحٌ لا يعمل أسوأ من
                // مفتاحٍ غائب: يضغطه فلا يقع شيء فيظنّ التطبيق معطوباً.
                if (d.isStoota)
                  _stootaNotice(theme)
                else if (!services.rides)
                  _closedNotice(theme, Icons.person_outline,
                      services.ridesMessage)
                else
                _serviceSwitch(
                  theme: theme,
                  icon: Icons.person_outline,
                  title: 'طلبات الركّاب',
                  on: 'تصلك طلبات نقل الركّاب',
                  off: 'لا تصلك طلبات ركّاب',
                  value: d.acceptsRides,
                  apply: ref.read(driverRepositoryProvider).setAcceptsRides,
                ),

                if (!d.isStoota && !services.shopping)
                  _closedNotice(theme, Icons.shopping_basket_outlined,
                      services.shoppingMessage)
                else if (!d.isStoota)
                _serviceSwitch(
                  theme: theme,
                  icon: Icons.shopping_basket_outlined,
                  title: 'طلبات التسوّق',
                  on: d.isTuktuk
                      ? 'تشتري بمالك وتستردّه نقداً — بأجرة الدراجة'
                      : 'تشتري بمالك وتستردّه نقداً عند التسليم',
                  off: 'لا تصلك طلبات تسوّق',
                  value: d.acceptsShopping,
                  apply: ref.read(driverRepositoryProvider).setAcceptsShopping,
                ),

                // خيار التكتك يتبع «طلبات الركّاب» لا التسوّق.
                if (d.isTuktuk && d.acceptsRides) _tuktukOption(theme, d),

                if (!services.delivery)
                  _closedNotice(theme, Icons.local_shipping_outlined,
                      services.deliveryMessage)
                else
                _serviceSwitch(
                  theme: theme,
                  icon: Icons.local_shipping_outlined,
                  title: 'طلبات التوصيل',
                  on: 'طرودٌ من المتاجر — قد تدفع ثمن السلعة مقدّماً',
                  off: 'لا تصلك طلبات توصيل',
                  value: d.acceptsDelivery,
                  apply: ref.read(driverRepositoryProvider).setAcceptsDelivery,
                ),

                // **داخل قسم التوصيل، مستقلاً عن خيار الرحلات أعلاه.**
                // طلب التكتك يصله دائماً؛ وهذا يفتح له طرود الدراجة.
                if (d.isTuktuk && d.acceptsDelivery && services.delivery)
                  _tuktukDeliveryOption(theme, d),

                if (_error != null) ...[
                  const SizedBox(height: 14),
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

                // **لا زرَّ اتصالٍ منفصل.** كان يقول «ابدأ الاستقبال»
                // بلا أن يقول أيّ استقبال، ويبدو حاكماً للمفتاحين تحته
                // وليس كذلك. فصار الاتصال نتيجتهما وحدهما.
              ],
            ),
          ),
        ),
      ),
    );
  }
}
