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
import 'earnings_card.dart';
import 'incentives_screen.dart' show myIncentivesProvider;
import 'store_dues_screen.dart' show storeDuesProvider, orderBlocksProvider;
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

  /// فحصٌ دوريّ ما دام عليه دَينٌ أو إيقاف — انظر [_watchBlocks].
  Timer? _blockPoll;

  /// هل كانت طلباته موقوفةً في الفحص السابق؟ — لنعرف لحظة رفع الإيقاف.
  bool _wasBlocked = false;

  /// يحرّك الخريطة بلا أن يرمي إن لم تُبنَ بعد (iPad / إقلاع سريع).
  void _safeMove(LatLng point, [double? zoom]) {
    try {
      _map.move(point, zoom ?? _map.camera.zoom);
    } catch (_) {
      // MapController بلا كاميرا بعد — initialCenter يلتقط لاحقاً.
    }
  }

  Future<void> _locateMe({bool silent = false}) async {
    setState(() => _locating = true);
    try {
      final geo = ref.read(geoServiceProvider);
      final p = await geo.currentPosition();
      if (!mounted) return;
      _safeMove(LatLng(p.latitude, p.longitude), 16);
    } on GeoException catch (e) {
      // **صامت عند فتح الشاشة.** قراءة الموقع التلقائية بعد الدخول
      // تفشل كثيراً على أجهزة المراجعة (iPad بلا GPS ثابت) — وإظهار
      // شريط خطأ أحمر فوراً هو ما رفضته آبل بـ 2.1.
      // الخطأ يبقى ظاهراً حين يضغط السائق زرّ الموقع أو «متصل».
      if (!silent && mounted) setState(() => _error = e.message);
    } catch (e) {
      if (!silent && mounted) setState(() => _error = AppError.message(e));
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

    // **ثم قراءةٌ حيّة بصمت.** لا نعرض خطأً إن فشلت — الخريطة تعمل
    // بالمركز الاحتياطي، والسائق يصحّح بضغط زرّ الموقع.
    if (mounted && _shown == null) {
      unawaited(_locateMe(silent: true));
    }
    // القراءة الحيّة أسبق دائماً: إن سبقتنا فلا نُرجع الكاميرا للوراء.
    if (p == null || !mounted || _shown != null) return;
    setState(() => _seed = p);
    // الخريطة قد تكون بُنيت قبل وصولنا (سجلّ السائق يُحمَّل أولاً)،
    // وحينها لا يُعاد قراءة `initialCenter` فنحرّك الكاميرا بأنفسنا.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _shown != null) return;
      _safeMove(p, 16);
    });
  }

  @override
  void dispose() {
    _blockPoll?.cancel();
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

  /// **يعيد الفحص كلّ ١٥ ثانية ما دامت البطاقة الحمراء ظاهرة.**
  ///
  /// وجده علي: أرجع المال، وأكّد صاحب المحلّ الاستلام — والبطاقة الحمراء
  /// باقية والطلبات لا تعود حتى يفتح السائق «المستحقات» ويحدّثها بيده.
  /// التأكيد يقع في جوال التاجر، فلا شيء في جوال السائق يعرف به. فالفحص
  /// يدور ما دام شيءٌ معلّقاً، ويقف حين لا يبقى شيء.
  ///
  /// **وحين يُرفع الإيقاف يعود متّصلاً وحده** إن كانت خدماته مفتوحة: من حاول
  /// الاتصال وهو موقوف رُفض فبقي غير متّصل، ولن يعرف أن يضغط ثانية. ويمرّ
  /// بـ`_toggleOnline` كالمربّعات — فيعود تتبّع الموقع معه.
  void _watchBlocks() {
    final b = ref.read(orderBlocksProvider).value;
    final dues = ref.read(storeDuesProvider).value ?? const [];
    final blocked = b != null &&
        (b['dues_blocked'] == true || b['wallet_blocked'] == true);
    final owes = dues.any((r) => r['settle_status'] != 'closed');

    if ((blocked || owes) && _blockPoll == null) {
      _blockPoll = Timer.periodic(const Duration(seconds: 15), (_) {
        ref.invalidate(orderBlocksProvider);
        ref.invalidate(storeDuesProvider);
      });
    } else if (!blocked && !owes) {
      _blockPoll?.cancel();
      _blockPoll = null;
    }

    if (_wasBlocked && b != null && !blocked) {
      final d = ref.read(driverRecordProvider).value;
      final services = ref.read(serviceStatusProvider).value ??
          const ServiceAvailability.open();
      if (d != null &&
          d.status == DriverStatus.offline &&
          d.wantsWork(services)) {
        _toggleOnline(true);
      }
    }
    if (b != null) _wasBlocked = blocked;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final driverAsync = ref.watch(driverRecordProvider);
    ref.listen(orderBlocksProvider, (_, _) => _watchBlocks());
    ref.listen(storeDuesProvider, (_, _) => _watchBlocks());

    // الموقع يأتي من المتتبّع على مستوى التطبيق لا من هذه الشاشة.
    final pos = ref.watch(locationTrackerProvider);
    if (pos != null && pos != _shown) {
      _shown = pos;
      // بعد الإطار: تحريك الكاميرا أثناء البناء يرمي استثناء.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _safeMove(LatLng(pos.latitude, pos.longitude));
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

    // **تحذير حين تُرفض الإشعارات صراحةً — لا قبل السؤال.**
    //
    // كان `!healthy` يكفي لإظهار البطاقة الحمراء: رمزٌ لم يُسجَّل بعد،
    // أو إذنٌ `notDetermined` أثناء حوار النظام، فيظهر «مهم — إعدادات
    // ناقصة» فور الدخول — وهو ما وصفته آبل بـ«خطأ بعد تسجيل الدخول».
    final push = ref.watch(pushDiagnosticsProvider).value;
    final pushBroken = push?.showHomeAlert == true;

    return Scaffold(
      body: driverAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppError.message(e))),
        data: (d) {
          if (d == null) {
            // **لا نعرض «لا يوجد سجل» فور الدخول.** البثّ قد يصل فارغاً
            // لحظةً قبل الصفّ، وحساب مراجعة بلا صفّ في `drivers` كان
            // يظهر رسالةً تشبه العطل. نُمهل ثم نوضح مع خروج.
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      'جاري تجهيز حسابك…',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: () =>
                          ref.read(authRepositoryProvider).signOut(),
                      child: const Text('خروج'),
                    ),
                  ],
                ),
              ),
            );
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
                    urlTemplate: MapEndpoints.tiles,
                    // محفوظةٌ على الهاتف ثلاثين يوماً — انظر ZanbourTiles.
                    tileProvider: ZanbourTiles.provider(),
                    userAgentPackageName: 'com.zanbour.driver',
                    maxZoom: 19,
                  ),
                  ..._hotspotLayers(),
                  if (pos != null)
                    MarkerLayer(
                      markers: [
                        // **مركبته هو على الخريطة.** سائق التكتك يرى تكتكاً
                        // والستوتة ستوتة — من `vehicle_kind` في سجلّه.
                        Marker(
                          point: LatLng(pos.latitude, pos.longitude),
                          width: 54,
                          height: 54,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: context.z.amber,
                              border: Border.all(
                                color: context.z.surface,
                                width: 3,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: context.z.amber.withValues(
                                    alpha: 0.35,
                                  ),
                                  blurRadius: 12,
                                  spreadRadius: 3,
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: ZVehicleArt(
                              kind: d.vehicleKind,
                              width: 36,
                              color: context.z.onAmber,
                              background: context.z.amber,
                            ),
                          ),
                        ),
                      ],
                    ),
                  const RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution(MapEndpoints.attribution),
                    ],
                  ),
                ],
              ),

              _topBar(theme, d),

              // **بطاقةٌ عائمة تحت الشريط لا شريطٌ فوقه.** كان
              // التنبيه ملتصقاً بأعلى الشاشة يغطّي شريط التطبيق نفسه،
              // فيبدو عطلاً في الواجهة لا تنبيهاً مقصوداً — ويُتجاهَل
              // لأنه يشبه خطأً عابراً.
              if (pushBroken && push != null)
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
                  content: Text(
                    now.healthy
                        ? 'تمّ — جهازك جاهز الآن'
                        : 'لم يكتمل بعد — راجع الخطوات غير المعلَّمة بالأخضر',
                  ),
                ),
              );
            }
          },
        ),
      ],
    );
  }

  /// الاسم الأول وحده — «محمد» لا «محمد أيوب علي»: الشريط ضيّق، والرصيد
  /// بجانبه أهمّ من اللقب.
  static String _firstName(String? full) {
    final t = (full ?? '').trim();
    if (t.isEmpty) return 'كابتن زنبور';
    return t.split(RegExp(r'\s+')).first;
  }

  Widget _topBar(ThemeData theme, DriverRecord d) {
    final me = ref.watch(accountProvider).value;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      right: 12,
      // **زجاجٌ لا سطحٌ معتم.** الشريط يطفو فوق خريطةٍ حيّة؛ وسطحٌ أبيض
      // يقطعها ويُخفي ما تحته. والزجاج يُبقي الشارع مرئياً ويقول للعين
      // إن هذا الشريط طبقةٌ فوق الخريطة لا جزءٌ منها.
      child: ZGlass(
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // **وجهُ السائق واسمه أوّلاً** — `.hd` في المحاكي. الصورة هي
              // صورته الحيّة من التسجيل (`profiles.avatar_url`، 0019)،
              // برابطٍ موقّع لا عام. والرصيد باقٍ بنصّه تحت الاسم.
              PartyAvatar(storagePath: me?['avatar_url'] as String?, radius: 21),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _firstName(me?['full_name'] as String?),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: d.walletBalance < 0
                              ? 'عليك ${d.walletBalance.abs().round()} دينار'
                              : '${d.walletBalance.round()} دينار',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: d.walletBalance < 0
                                ? context.z.warn
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        const TextSpan(text: ' · '),
                        TextSpan(
                          text: d.bonusBalance > 0
                              ? 'هدية ${d.bonusBalance.round()} دينار'
                              : d.walletBalance < 0
                                  ? 'عمولات مستحقة'
                                  : 'رصيد المحفظة',
                        ),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                    await _openPushSetup(
                      ref.read(pushDiagnosticsProvider).value,
                    );
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
          Icon(Icons.local_shipping_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'مندوب ستوتة',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
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

  /// مفتاحا الخدمة — متساويان في الحجم وفي الوزن.
  ///
  /// **الاتصال نتيجتهما لا سببهما.** كان زرٌّ كبير مكتوبٌ عليه «ابدأ
  /// الاستقبال» لا يقول أيّ استقبال، ومفتاحٌ صغير للتسوّق تحته — فيظنّ
  /// السائق أن الكبير يحكم الصغير. فمن فتح واحداً فهو متصل، ومن أغلق
  /// الاثنين فهو غير متصل. ولا زرَّ ثالثاً يحكمهما.
  /// مربّع خدمة — يُضغط ليُفتح أو يُغلق.
  ///
  /// **الحالة تُقرأ من بعيد.** المفتوح كهرمانيٌّ بحدٍّ سميك وأيقونةٍ
  /// ملوّنة؛ والمغلق باهتٌ بحدٍّ رفيع. يُميَّزان بنظرةٍ واحدة على دراجةٍ
  /// متحرّكة، لا بقراءة سطرٍ تحت كل مفتاح.
  Widget _serviceTile({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required String on,
    required String off,
    required bool value,
    required Future<void> Function(bool) apply,
  }) {
    final scheme = theme.colorScheme;

    return Expanded(
      child: Tooltip(
        message: value ? on : off,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: _busy ? null : () => _setService(apply, !value),
            borderRadius: BorderRadius.circular(18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
              decoration: BoxDecoration(
                color: value
                    ? scheme.primary.withValues(alpha: 0.16)
                    : scheme.onSurface.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: value
                      ? scheme.primary.withValues(alpha: 0.65)
                      : scheme.onSurface.withValues(alpha: 0.09),
                  width: value ? 1.6 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: value
                          ? scheme.primary.withValues(alpha: 0.24)
                          : scheme.onSurface.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      icon,
                      size: 20,
                      color: value ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11.5,
                      height: 1.25,
                      fontWeight: value ? FontWeight.w700 : FontWeight.w400,
                      color: value ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// مربّع خدمةٍ أغلقتها الإدارة — برسالتها لا برماديٍّ صامت.
  Widget _closedTile(
    ThemeData theme,
    IconData icon,
    String title,
    String message,
  ) {
    final scheme = theme.colorScheme;

    return Expanded(
      child: Tooltip(
        // **النصّ الافتراضي كما كان.** الإدارة قد تُغلق خدمةً بلا رسالة،
        // فيبقى للسائق جوابٌ بدل فراغ.
        message: message.isEmpty ? 'هذه الخدمة متوقّفة مؤقّتاً.' : message,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: scheme.outline),
              ),
              const SizedBox(height: 7),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11.5,
                  height: 1.25,
                  color: scheme.outline,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'متوقّفة',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ),
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
    Future<void> Function(bool) apply,
    bool value,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    bool? target;
    try {
      await apply(value);

      final d = await ref.refresh(driverRecordProvider.future);
      final services =
          ref.read(serviceStatusProvider).value ??
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

  /// الرصيد تحت الأرضية — طلبه علي: «توقفت عن قبول الطلبات بسبب انتهاء
  /// الرصيد».
  ///
  /// **كان السائق يكتشف ذلك بصمت:** يبقى متّصلاً ولا يصله شيء، أو يضغط
  /// «متّصل» فيُرفض برسالةٍ تختفي. الآن السبب أوّل ما يراه، ولمسةٌ تأخذه إلى
  /// الشحن. والقرار من القاعدة (`my_order_blocks`) — الأرضية نفسها التي
  /// يفحصها البحث عن سائقين.
  Widget _walletBlockCard() {
    final b = ref.watch(orderBlocksProvider).value;
    if (b == null || b['wallet_blocked'] != true) {
      return const SizedBox.shrink();
    }
    final z = context.z;
    final bal = (b['wallet_balance'] as num?)?.round() ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: z.bad.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZanbourTheme.rLg),
          side: BorderSide(color: z.bad.withValues(alpha: 0.5)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZanbourTheme.rLg),
          onTap: () => context.push('/wallet'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                ZIconTile(Icons.account_balance_wallet, color: z.bad),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('توقفت عن قبول الطلبات بسبب انتهاء الرصيد',
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: z.bad)),
                      Text('رصيدك $bal دينار — اشحن رصيدك لتعود',
                          style: TextStyle(fontSize: 12, color: z.inkDim)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_left, color: z.bad),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// مستحقات المتاجر — بطاقةٌ حمراء فوق كلّ شيء، **ما دام عليه شيء**.
  ///
  /// **دَينٌ لا يُرى يُنسى.** كانت المستحقات خلف القائمة (⋮) في شاشةٍ لا
  /// يفتحها إلا من تذكّر؛ والتاجر ينتظر ماله ويتّصل بالدعم. الآن يراها
  /// السائق كلّما فتح التطبيق، بالمجموع كاملاً، ولمسةٌ تأخذه إلى القائمة.
  ///
  /// **والمجموع من الحساب نفسه الذي في الشاشة:** المزوّد نفسه، والمفتوحة
  /// وحدها (`settle_status` ليس `closed`)، وثمن السلع `goods_actual_iqd`.
  /// فلا يقول الرقم هنا شيئاً والقائمة شيئاً آخر. ويختفي إن لم يبقَ دَين.
  Widget _storeDuesCard() {
    final rows = ref.watch(storeDuesProvider).value ?? const [];
    final open = rows.where((r) => r['settle_status'] != 'closed').toList();
    final owed = open.fold<num>(
        0, (a, r) => a + ((r['goods_actual_iqd'] as num?) ?? 0));
    if (owed <= 0) return const SizedBox.shrink();

    final z = context.z;
    final blocked =
        ref.watch(orderBlocksProvider).value?['dues_blocked'] == true;
    final stores =
        open.map((r) => r['store_phone'] ?? r['shop_name']).toSet();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: z.bad.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZanbourTheme.rLg),
          side: BorderSide(color: z.bad.withValues(alpha: 0.45)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZanbourTheme.rLg),
          onTap: () => context.push('/store-dues'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                ZIconTile(Icons.storefront, color: z.bad),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // **حين تبلغ الحدّ يصير العنوان هو السبب** — لا بطاقةٌ
                      // ثانية فوقها تقول الشيء نفسه.
                      Text(
                          blocked
                              ? 'توقفت الطلبات لحين إرجاع المستحقات إلى المتاجر'
                              : 'مستحقات المتاجر',
                          style: TextStyle(
                              fontSize: blocked ? 13.5 : 15,
                              fontWeight: FontWeight.w700,
                              color: blocked ? z.bad : z.ink)),
                      Text(
                        blocked
                            ? 'مستحقات المتاجر — اضغط للتسوية'
                            : stores.length == 1
                                ? 'لمتجرٍ واحد — اضغط للتسوية'
                                : 'لـ${stores.length} متاجر — اضغط للتسوية',
                        style: TextStyle(fontSize: 12, color: z.inkDim),
                      ),
                    ],
                  ),
                ),
                ZCountUp(
                  owed,
                  suffix: ' دينار',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: z.bad),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_left, color: z.bad),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// بطاقة الاتصال — `.shift` في المحاكي.
  ///
  /// **كهرمانيةٌ حين يتّصل، ساكنةٌ حين ينقطع.** السائق يلمح هاتفه على
  /// المقود ثانيةً واحدة؛ ولونُ البطاقة يجيبه «هل تصلني الطلبات؟» قبل أن
  /// يقرأ حرفاً. ومركبته فيها تطفو ما دام متّصلاً.
  ///
  /// **لا زرَّ فيها.** الاتصال نتيجة المربّعات تحتها لا مفتاحٌ مستقلّ —
  /// انظر التعليق في آخر اللوح. فالبطاقة تعرض ولا تتحكّم.
  ///
  /// وأرباح اليوم من `my_earnings` — المصدر نفسه لقسم «اليوم» في
  /// «رحلاتي»، فلا يختلف الرقمان.
  Widget _connectionCard(ThemeData theme, DriverRecord d, bool online) {
    final z = context.z;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final earned = ref
        .watch(
          earningsProvider((
            from: today,
            to: today.add(const Duration(days: 1)),
          )),
        )
        .value;

    final fg = online ? z.onAmber : z.ink;
    final dim = online ? z.onAmber.withValues(alpha: 0.72) : z.inkDim;

    Widget metric(Widget value, String label) => Expanded(
      child: Column(
        children: [
          DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
            child: value,
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: dim)),
        ],
      ),
    );

    Widget sep() => Container(
      width: 1,
      height: 30,
      color: online ? z.onAmber.withValues(alpha: 0.22) : z.line,
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 340),
      curve: const Cubic(0.22, 0.9, 0.3, 1),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ZanbourTheme.rXl),
        gradient: online
            ? LinearGradient(
                begin: AlignmentDirectional.topStart,
                end: AlignmentDirectional.bottomEnd,
                colors: [z.amber2, z.amber, const Color(0xFFE09B00)],
                stops: const [0, 0.55, 1],
              )
            : null,
        color: online ? null : z.surface,
        border: online ? null : Border.all(color: z.line),
        boxShadow: online
            ? [
                BoxShadow(
                  color: z.amber.withValues(alpha: 0.34),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: Column(
        children: [
          Row(
            children: [
              ZFloat(
                enabled: online,
                child: Opacity(
                  opacity: online ? 1 : 0.45,
                  child: ZVehicleArt(kind: d.vehicleKind, width: 76, color: fg),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: online
                                ? z.onAmber
                                : theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            d.status.label,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: fg,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.star,
                          size: 16,
                          color: online ? z.onAmber : z.amber,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          d.ratingAvg.toStringAsFixed(1),
                          style: TextStyle(color: fg),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${d.tripsCompleted} رحلة',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: dim,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              metric(ZCountUp(earned?.trips ?? 0), 'رحلات اليوم'),
              sep(),
              metric(ZCountUp(earned?.gross ?? 0), 'أجور اليوم · دينار'),
              sep(),
              metric(ZCountUp(earned?.net ?? 0), 'صافي اليوم · دينار'),
            ],
          ),
          _incentiveStrip(online),
        ],
      ),
    );
  }

  /// أقرب حافزٍ إلى الاكتمال — حلقةٌ صغيرة وجملةٌ واحدة.
  ///
  /// **السائق الذي يرى هدفه قريباً يبقى متّصلاً ساعةً أخرى.** والحافز كان
  /// في شاشةٍ خلف القائمة، لا يراه إلا من تذكّر أن يفتحها.
  ///
  /// **أقربُ طبقةٍ لم تُكسب، من الحوافز التي فعّلها وحدها.** غير المفعَّل
  /// لا تُحسب رحلاته له أصلاً (0108)، فعرضه يعِد بما لن يأتي. ويختفي
  /// الشريط كلّه إن لم يكن له حافزٌ مفعَّل — لا مساحة فارغة.
  /// **أماكن الذروة على خريطته** — من حوافز الأماكن التي فعّلها (0135).
  ///
  /// دائرةٌ كهرمانية بحجم المكان واسمه فوقها: يعرف أين يقف لتُحسب ساعاته.
  /// والخادم يحسبها بلا هذا الرسم (التطبيق السابق يعمل) — هذا للعين فقط.
  List<Widget> _hotspotLayers() {
    final items = (ref.watch(myIncentivesProvider).value?['items'] as List?) ??
        const [];
    final spots = <Map<String, dynamic>>[
      for (final raw in items)
        if ((raw as Map)['activated'] == true)
          for (final h in (raw['hotspots'] as List?) ?? const [])
            Map<String, dynamic>.from(h as Map),
    ];
    if (spots.isEmpty) return const [];
    final z = context.z;
    LatLng at(Map<String, dynamic> h) =>
        LatLng((h['lat'] as num).toDouble(), (h['lng'] as num).toDouble());
    return [
      CircleLayer(circles: [
        for (final h in spots)
          CircleMarker(
            point: at(h),
            radius: (h['radius_m'] as num?)?.toDouble() ?? 500,
            useRadiusInMeter: true,
            color: z.amber.withValues(alpha: 0.18),
            borderColor: z.amber,
            borderStrokeWidth: 2,
          ),
      ]),
      MarkerLayer(markers: [
        for (final h in spots)
          Marker(
            point: at(h),
            width: 160,
            height: 30,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: z.amber,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '🔥 ${h['name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: z.onAmber,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
      ]),
    ];
  }

  Widget _incentiveStrip(bool online) {
    final items = (ref.watch(myIncentivesProvider).value?['items'] as List?) ??
        const [];

    Map<String, dynamic>? best;
    var bestRatio = -1.0;
    for (final raw in items) {
      final it = Map<String, dynamic>.from(raw as Map);
      if (it['activated'] != true) continue;
      final trips = (it['trips'] as num?)?.toDouble() ?? 0;
      final hours = (it['hours'] as num?)?.toDouble() ?? 0;
      for (final t in (it['tiers'] as List?) ?? const []) {
        final tier = Map<String, dynamic>.from(t as Map);
        if (tier['earned'] == true) continue;
        final needT = (tier['trips_required'] as num?)?.toDouble() ?? 0;
        final needH = (tier['hours_required'] as num?)?.toDouble() ?? 0;
        final ratios = [
          if (needT > 0) (trips / needT).clamp(0.0, 1.0),
          if (needH > 0) (hours / needH).clamp(0.0, 1.0),
        ];
        if (ratios.isEmpty) continue;
        final r = ratios.reduce((a, b) => a < b ? a : b);
        if (r > bestRatio) {
          bestRatio = r;
          best = {
            'ratio': r,
            'reward': (tier['reward_iqd'] as num?)?.round() ?? 0,
            'leftTrips': needT > 0 ? (needT - trips).ceil().clamp(0, 9999) : 0,
            'leftHours': needH > 0 ? (needH - hours).clamp(0.0, 9999.0) : 0.0,
          };
        }
        break; // الطبقات مرتّبة: أوّل ما لم يُكسب هو التالي
      }
    }
    if (best == null) return const SizedBox.shrink();

    final z = context.z;
    final fg = online ? z.onAmber : z.ink;
    final leftT = best['leftTrips'] as int;
    final leftH = best['leftHours'] as double;
    final left = [
      if (leftT > 0) 'باقي $leftT ${leftT == 1 ? 'رحلة' : 'رحلات'}',
      if (leftH > 0) 'باقي ${leftH.toStringAsFixed(leftH % 1 == 0 ? 0 : 1)} ساعة',
    ].join(' و');

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: online
            ? z.onAmber.withValues(alpha: 0.10)
            : z.amberWash,
        borderRadius: BorderRadius.circular(ZanbourTheme.r),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZanbourTheme.r),
          onTap: () => context.push('/incentives'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  height: 30,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: best['ratio'] as double),
                    duration: const Duration(milliseconds: 900),
                    curve: const Cubic(0.2, 0.9, 0.25, 1),
                    builder: (_, v, _) => CircularProgressIndicator(
                      value: v,
                      strokeWidth: 4,
                      color: online ? z.onAmber : z.amber,
                      backgroundColor: (online ? z.onAmber : z.amber)
                          .withValues(alpha: 0.18),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$left لمكافأة ${best['reward']} دينار',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                  ),
                ),
                Icon(Icons.chevron_left, size: 18, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomPanel(ThemeData theme, DriverRecord d, bool online) {
    final services =
        ref.watch(serviceStatusProvider).value ??
        const ServiceAvailability.open();

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // **زرّ القنّاص فوق اللوح مباشرةً لا في موضعٍ ثابت.** كان على
          // ارتفاعٍ مكتوب (٢٤٠)، واللوح يطول ويقصر: بطاقة الاتصال وخيارات
          // التكتك ورسالة الخطأ — فيختفي الزرّ تحته أحياناً. هنا يتبعه.
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: FloatingActionButton.small(
                heroTag: 'locate',
                onPressed: _locating ? null : _locateMe,
                // شفافٌ فوق الخريطة كبقية الطبقات العائمة.
                backgroundColor: theme.colorScheme.surface.withValues(
                  alpha: 0.86,
                ),
                elevation: 2,
                child: _locating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : Icon(Icons.my_location, color: theme.colorScheme.primary),
              ),
            ),
          ),
          // اللوح زجاجيٌّ أيضاً: الخريطة تبقى حاضرةً تحته، فيبدو لوحاً يعلو
          // الشارع لا جداراً يسدّه.
          ZGlass(
            radius: 28,
            topOnly: true,
            blur: 26,
            opacity: 0.80,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // مقبضٌ يقول إن هذا لوحٌ يعلو الخريطة لا حافّة شاشة.
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outline,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    _walletBlockCard(),
                _storeDuesCard(),
                _connectionCard(theme, d, online),

                    const SizedBox(height: 14),

                    // ═══ الخدمات — مربّعاتٌ في صفّ ═══
                    //
                    // **ثلاثة صفوفٍ بمفاتيح كانت تأكل نصف الشاشة** وتدفع
                    // الخريطة خارجها، والسائق يحتاج أن يرى شارعه. والمربّع
                    // يقول الشيء نفسه في ثلث المساحة: أيقونةٌ واسمٌ وحالةٌ
                    // تُقرأ باللون — والوصف الكامل يبقى بالضغط المطوّل، فلا
                    // تضيع كلمةٌ كُتبت للسائق.
                    //
                    // **وترتيب الشروط كما كان حرفاً بحرف.** المغلقة تُخفى
                    // ومكانها رسالة الإدارة؛ ومفتاحٌ رماديّ سؤالٌ بلا جواب:
                    // يضغطه السائق فلا يقع شيء فيظنّ التطبيق معطوباً ويتصل
                    // بالدعم. وسائق الستوتة لا يرى ما ثبّتته القاعدة مغلقاً
                    // (0105).
                    if (d.isStoota)
                      _stootaNotice(theme)
                    else ...[
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!services.rides)
                              _closedTile(
                                theme,
                                Icons.person_outline,
                                'طلبات الركّاب',
                                services.ridesMessage,
                              )
                            else
                              _serviceTile(
                                theme: theme,
                                icon: Icons.person_outline,
                                title: 'طلبات الركّاب',
                                on: 'تصلك طلبات نقل الركّاب',
                                off: 'لا تصلك طلبات ركّاب',
                                value: d.acceptsRides,
                                apply: ref
                                    .read(driverRepositoryProvider)
                                    .setAcceptsRides,
                              ),
                            const SizedBox(width: 8),
                            if (!services.shopping)
                              _closedTile(
                                theme,
                                Icons.shopping_basket_outlined,
                                'طلبات التسوّق',
                                services.shoppingMessage,
                              )
                            else
                              _serviceTile(
                                theme: theme,
                                icon: Icons.shopping_basket_outlined,
                                title: 'طلبات التسوّق',
                                on: d.isTuktuk
                                    ? 'تشتري بمالك وتستردّه نقداً — بأجرة الدراجة'
                                    : 'تشتري بمالك وتستردّه نقداً عند التسليم',
                                off: 'لا تصلك طلبات تسوّق',
                                value: d.acceptsShopping,
                                apply: ref
                                    .read(driverRepositoryProvider)
                                    .setAcceptsShopping,
                              ),
                            const SizedBox(width: 8),
                            if (!services.delivery)
                              _closedTile(
                                theme,
                                Icons.local_shipping_outlined,
                                'طلبات التوصيل',
                                services.deliveryMessage,
                              )
                            else
                              _serviceTile(
                                theme: theme,
                                icon: Icons.local_shipping_outlined,
                                title: 'طلبات التوصيل',
                                on: 'طرودٌ من المتاجر — قد تدفع ثمن السلعة مقدّماً',
                                off: 'لا تصلك طلبات توصيل',
                                value: d.acceptsDelivery,
                                apply: ref
                                    .read(driverRepositoryProvider)
                                    .setAcceptsDelivery,
                              ),
                          ],
                        ),
                      ),

                      // خيار التكتك يتبع «طلبات الركّاب» لا التسوّق.
                      if (d.isTuktuk && d.acceptsRides) _tuktukOption(theme, d),

                      // **داخل قسم التوصيل، مستقلاً عن خيار الرحلات أعلاه.**
                      // طلب التكتك يصله دائماً؛ وهذا يفتح له طرود الدراجة.
                      if (d.isTuktuk && d.acceptsDelivery && services.delivery)
                        _tuktukDeliveryOption(theme, d),
                    ],

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
                            Icon(
                              Icons.error_outline,
                              size: 18,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer,
                                ),
                              ),
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
        ],
      ),
    );
  }
}
