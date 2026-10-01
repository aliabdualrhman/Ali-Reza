import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';
import 'delivery_trip_view.dart';
import 'driver_repository.dart';
import 'location_tracker.dart';

/// شاشة الرحلة الجارية — من القبول حتى الإنهاء.
///
/// تُبنى حول سؤال واحد: **ما الفعل التالي؟** السائق على دراجة، وكل شاشة
/// تعرض عليه أكثر من قرار واحد هي شاشة سيئة. لذلك زر رئيسي واحد كبير
/// يتبدّل نصه مع تقدّم الرحلة.
/// كم متراً نسمح بها بين السائق والوجهة قبل أن نسأله عند الإنهاء.
///
/// أوسع من نطاق الوصول (٢٠٠م): الوجهة عنوانٌ كتبه الراكب وقد يكون طرف
/// الشارع، والسؤال المتكرر بلا داعٍ يُعلّم السائق تجاهله.
/// احتياطيٌّ عند تعذّر القراءة من القاعدة — لا مصدرٌ للحقيقة.
///
/// المصدر `pricing_zones.dropoff_warn_radius_m` (0053)، ويُقرأ لكل رحلة
/// عبر `dropoffWarnRadius`. وهذا الرقم لشبكةٍ منقطعة لحظة الإنهاء:
/// تحذيرٌ بحدٍّ قديم أهون من رحلةٍ لا تُنهى.
const _dropoffWarnRadiusFallback = 400;

class ActiveTripScreen extends ConsumerStatefulWidget {
  const ActiveTripScreen({super.key});

  @override
  ConsumerState<ActiveTripScreen> createState() => _ActiveTripScreenState();
}

class _ActiveTripScreenState extends ConsumerState<ActiveTripScreen> {
  bool _busy = false;
  String? _error;

  /// المعرّف من المزوّد لا من معامل — نفس سبب OfferScreen: الشاشة تُفتح
  /// من طرق متعددة، والمصدر الواحد يمنع اختلافها.
  String? get _tripId => ref.read(activeDriverTripProvider).value?['id'] as String?;

  Future<void> _advance(Map<String, dynamic> trip) async {
    final id = _tripId;
    if (id == null) return;
    final status = trip['status'] as String;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final repo = ref.read(driverRepositoryProvider);
      switch (status) {
        case 'accepted':
          await repo.advance(id, 'driver_arrived');
        case 'driver_arrived':
          await repo.advance(id, 'in_progress');
        case 'in_progress':
          // **محطة وسيطة قبل الإنهاء.** الرحلة متعددة المحطات تُقفل عند
          // أولاها لو تركنا زر الإنهاء وحده، فتضيع مرحلة وأجرتها.
          final legs = (trip['stop_count'] as num?)?.toInt() ?? 1;
          final leg = (trip['current_leg'] as num?)?.toInt() ?? 1;
          if (leg < legs) {
            await repo.arriveAtStop(id);
            ref.invalidate(tripStopsProvider(id));
            break;
          }

          // **تحذير لا منع.** الإنهاء بعيداً عن الوجهة له أعذار حقيقية:
          // الراكب يطلب النزول قبل الوصول، أو الشارع مغلق. لكن الإنهاء
          // في منتصف الطريق سهواً يُقيّد أجرة كاملة على راكب لم يصل،
          // فنسأل مرة واحدة ونمضي.
          final (proceed, farMeters) = await _confirmFarCompletion(trip);
          if (!proceed) {
            if (mounted) setState(() => _busy = false);
            return;
          }

          // **نبلّغ قبل الإنهاء لا بعده.** بعد `complete` تتبدّل الحالة
          // فيوجّهنا المراقب إلى الشاشة الرئيسية، وقد تُهدم هذه الشاشة
          // قبل أن يصل النداء — فيضيع القياس ولا يُعرف أنه ضاع.
          if (farMeters != null) {
            try {
              await repo.reportCompletionDistance(id, farMeters);
            } catch (_) {
              // قياسٌ ضائع أهون من رحلةٍ عالقة.
            }
          }

          // لا نمرّر مسافة محسوبة: القاعدة تستعمل التقدير المخزّن.
          // حساب المسافة الفعلية من أثر المسار يأتي لاحقاً.
          await repo.complete(id);
          // התوجيه للرئيسية سيتم تلقائياً عبر مراقب الحالة،
          // والشاشة الرئيسية ستفحص وجود رحلة غير مقيّمة لتعرض النافذة.
      }
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // الملاحة
  // ---------------------------------------------------------------------------
  /// يفتح تطبيق ملاحة خارجياً على الوجهة.
  ///
  /// **لماذا لا نبني ملاحة داخل التطبيق؟** لأنها مشروع كامل بذاته: توجيه
  /// صوتي، إعادة حساب عند الانحراف، تحذيرات مرورية. أوبر وكريم لا تفعلان
  /// ذلك أيضاً — تفتحان تطبيق الملاحة المفضّل للسائق.
  ///
  /// وWaze تحديداً أدق في بغداد لتحذيرات الازدحام ونقاط التفتيش.
  Future<void> _navigate(double lat, double lng) async {
    // نجرّب بالترتيب: Waze، ثم خرائط جوجل، ثم أي تطبيق يفهم geo:
    final candidates = <Uri>[
      Uri.parse('waze://?ll=$lat,$lng&navigate=yes'),
      // **آيفون لا يعرف `google.navigation:` ولا `geo:`** — كانا يفشلان
      // فيسقط السائق إلى صفحة ويب. فلآيفون تطبيقُ خرائط جوجل بمخططه،
      // ثم خرائط آبل الموجودة في كل جهاز.
      Uri.parse('comgooglemaps://?daddr=$lat,$lng&directionsmode=driving'),
      Uri.parse('google.navigation:q=$lat,$lng'),
      Uri.parse('geo:$lat,$lng?q=$lat,$lng'),
      if (defaultTargetPlatform == TargetPlatform.iOS)
        Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=d'),
    ];

    for (final uri in candidates) {
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }
      } catch (_) {
        // نجرّب التالي
      }
    }

    // آخر ملاذ: صفحة ويب تعمل بلا أي تطبيق مثبّت
    final web = Uri.parse('https://www.google.com/maps/dir/?api=1'
        '&destination=$lat,$lng&travelmode=driving');
    if (await canLaunchUrl(web)) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      setState(() => _error = 'لم نجد تطبيق ملاحة على جهازك');
    }
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tripAsync = ref.watch(activeDriverTripProvider);

    final isDelivery = tripAsync.value?['kind'] == 'delivery';
    return Scaffold(
      appBar: AppBar(
          title: Text(isDelivery ? 'طلب المندوب' : 'الرحلة الجارية')),
      body: tripAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppError.message(e))),
        data: (trip) {
          if (trip == null) {
            // انتهت أو أُلغيت — نعود للرئيسية
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/home');
            });
            return const Center(child: CircularProgressIndicator());
          }

          // **طلب المندوب مسارٌ آخر في ملفٍ آخر** — انظر رأس
          // `delivery_trip_view.dart`. لا فروع هنا تمسّ الرحلة والتسوّق.
          if (trip['kind'] == 'delivery') return DeliveryTripView(trip: trip);

          final status = trip['status'] as String;
          final goingToRider = status == 'accepted' || status == 'driver_arrived';

          // **طلب التسوّق مسارٌ مختلف، لا رحلةٌ بأسماءٍ أخرى.**
          // السائق يقصد المحل أولاً ثم بيت الراكب — فـ«الملاحة إلى
          // الراكب» و«بدأت الرحلة» تصفان شيئاً لا يفعله، وتوجّهانه إلى
          // المكان الخطأ في أول مرحلة.
          final isShopping = trip['kind'] == 'shopping';
          final tripId = trip['id'] as String;
          final leg = (trip['current_leg'] as num?)?.toInt() ?? 1;
          final legs = (trip['stop_count'] as num?)?.toInt() ?? 1;
          final stops = ref.watch(tripStopsProvider(tripId)).value ?? const [];

          // المحطة التي نقصدها الآن: في رحلة بمحطة واحدة هي الوجهة نفسها.
          final target = stops
              .where((st) => (st['seq'] as num?)?.toInt() == leg)
              .firstOrNull;

          // طلب تغيير الوجهة يصل فجأة أثناء القيادة — نعرضه فور وصوله.
          ref.listen(pendingChangeProvider(tripId), (_, next) {
            final req = next.value;
            if (req != null && mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _showChangeRequest(req);
              });
            }
          });

          return SafeArea(
            // **يمرّر ولا يقصّ.** كان عموداً ثابتاً، فلمّا أضفنا تحذير
            // البُعد وزرَّي التسوّق دُفع زرّ الإجراء خارج الشاشة —
            // فيقف السائق أمام شاشةٍ لا يستطيع أن يفعل فيها شيئاً ولا
            // أن يمرّرها. وأسوأ ما فيه أنه يقع في أضيق الشاشات وحدها،
            // فلا يظهر في الاختبار على جهازٍ كبير.
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // رمز الرحلة أمام السائق طوال الرحلة: حين يتصل بالدعم
                  // أو يختلف مع راكب على أجرة، هذا الرقم وحده يجد الرحلة
                  // في اللوحة.
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TripCodeBadge(number: trip['trip_number']),
                  ),
                  const SizedBox(height: 12),
                  _StatusStrip(status: status, shopping: isShopping),
                  const SizedBox(height: 20),

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Addr(
                            icon: Icons.trip_origin,
                            color: theme.colorScheme.primary,
                            label: isShopping ? 'المتجر' : 'نقطة الانطلاق',
                            title: isShopping
                                ? (trip['shop_name'] as String?)
                                : null,
                            value: '${trip['pickup_address'] ?? ''}',
                            active: isShopping
                                ? status != 'in_progress'
                                : goingToRider,
                          ),
                          const Divider(height: 24),
                          _Addr(
                            icon: Icons.location_on,
                            color: theme.colorScheme.error,
                            label: isShopping
                                ? 'نقطة التسليم'
                                : (legs > 1
                                    ? 'المحطة $leg من $legs'
                                    : 'الوجهة'),
                            value: legs > 1 && target != null
                                ? '${target['address'] ?? ''}'
                                : '${trip['dropoff_address'] ?? ''}',
                            active: isShopping
                                ? status == 'in_progress'
                                : !goingToRider,
                          ),
                          if (trip['has_stopover'] == true) ...[
                            const Divider(height: 24),
                            Row(
                              children: [
                                Icon(Icons.pause_circle_outline,
                                    size: 20, color: theme.colorScheme.tertiary),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Text(
                                      'الراكب طلب توقفاً في الطريق — '
                                      'الأجرة تشمله'),
                                ),
                              ],
                            ),
                          ],
                          if ((trip['rider_note'] as String?)?.isNotEmpty ??
                              false) ...[
                            const Divider(height: 24),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.sticky_note_2_outlined,
                                    size: 20),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: Text('${trip['rider_note']}')),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),
                  _RiderCard(tripId: trip['id'] as String, status: status),

                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('الأجرة'),
                          Text(
                            '${((trip['fare_final_iqd'] ?? trip['fare_estimated_iqd']) as num?)?.round() ?? 0} دينار',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(_error!,
                          style: TextStyle(
                              color: theme.colorScheme.onErrorContainer)),
                    ),
                  ],

                  // **القائمة في متناوله طوال الطلب.** هو في المحل
                  // يقرأ سطراً سطراً، ولا يحفظ ستّ سلعٍ في رأسه.
                  if (trip['kind'] == 'shopping') ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _showItems(context, trip),
                      icon: const Icon(Icons.receipt_long),
                      label: Text(
                          'قائمة الطلب (${(trip['items'] as List?)?.length ?? 0})'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      onPressed: () => _enterGoodsPrice(context, ref, trip),
                      icon: const Icon(Icons.payments_outlined),
                      label: Text(trip['goods_actual_iqd'] == null
                          ? 'اكتب سعر البضاعة'
                          : 'سعر البضاعة: '
                              '${(trip['goods_actual_iqd'] as num).round()} دينار'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // زر الملاحة — يوجّه لنقطة الانطلاق أو الوجهة حسب المرحلة
                  OutlinedButton.icon(
                    onPressed: () {
                      // **الملاحة تتبع المحطة الحالية لا الوجهة الأخيرة.**
                      // توجيه السائق إلى آخر المحطات وهو في أولاها يجعله
                      // يتخطّى نقطة كان يجب أن يقف عندها.
                      final (double, double)? p;
                      // **في التسوّق: المحل أولاً ثم التسليم.** و`pickup`
                      // هو المحل. فبعد الوصول إليه تصير الوجهة `dropoff`
                      // — بينما `goingToRider` تبقى صادقة في
                      // `driver_arrived` فتُعيده إلى المحل الذي غادره.
                      // **الملاحة تبقى إلى المتجر ما دام يتسوّق.**
                      // مرحلة `driver_arrived` تعني أنه في المتجر يشتري
                      // — لا أنه فرغ. فتحويل الوجهة عندها يسحبه من
                      // مكانه قبل أن يُنهي شراءه. ولا تتحوّل إلا بعد
                      // «تمّ التسوّق».
                      if (isShopping) {
                        p = status == 'in_progress'
                            ? _extractPoint(trip, 'dropoff')
                            : _extractPoint(trip, 'pickup');
                      } else if (goingToRider) {
                        p = _extractPoint(trip, 'pickup');
                      } else if (legs > 1 && target != null) {
                        p = _stopPoint(target);
                      } else {
                        p = _extractPoint(trip, 'dropoff');
                      }
                      if (p != null) {
                        _navigate(p.$1, p.$2);
                      } else {
                        // كان هذا الزر يفشل صامتاً حين تغيب الإحداثيات:
                        // لا فعل ولا رسالة، فيبدو التطبيق معطوباً بلا سبب.
                        // الفشل الصامت أسوأ من الخطأ الواضح.
                        setState(() => _error =
                            'تعذّر تحديد إحداثيات الوجهة. '
                            'تواصل مع الإدارة — قاعدة البيانات تحتاج تحديثاً.');
                      }
                    },
                    icon: const Icon(Icons.navigation),
                    label: Text(
                      isShopping
                          ? switch (status) {
                              'accepted' => 'الملاحة إلى المتجر',
                              'driver_arrived' => 'الملاحة إلى نقطة التسوّق',
                              _ => 'الملاحة إلى نقطة التسليم',
                            }
                          : (goingToRider
                              ? 'الملاحة إلى الراكب'
                              : 'الملاحة إلى الوجهة'),
                    ),
                  ),
                  const SizedBox(height: 10),

                  FilledButton(
                    onPressed: _busy ? null : () => _advance(trip),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(60)),
                    child: _busy
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.6))
                        : Text(
                            isShopping
                                ? switch (status) {
                                    'accepted' => 'وصلت إلى المتجر',
                                    'driver_arrived' => 'تمّ التسوّق',
                                    _ => 'وصلت إلى نقطة التسليم',
                                  }
                                : switch (status) {
                                    'accepted' => 'وصلت إلى الراكب',
                                    'driver_arrived' => 'بدأت الرحلة',
                                    _ => _moreStops(trip)
                                        ? 'وصلت إلى المحطة الأولى'
                                        : 'إنهاء الرحلة',
                                  },
                            style: const TextStyle(fontSize: 18),
                          ),
                  ),

                  // **زر الإلغاء يختفي بعد بدء الرحلة عمداً.** الراكب على
                  // الدراجة حينها، وتركه في منتصف الطريق ليس إلغاءً بل
                  // هجراً — والقاعدة ترفضه أيضاً.
                  if (status != 'in_progress') ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : () => _cancel(trip),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: const Text('إلغاء الرحلة'),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// يسأل السائق إن كان بعيداً عن الوجهة. يعيد `true` للمضيّ قدماً.
  ///
  /// **الفحص هنا لا في القاعدة، خلافاً لـ"وصلت" و"بدأت".** تلك انتقالات
  /// يكذب فيها التطبيق على الراكب فتُحرَس في الخادم؛ وهذا سؤال للسائق
  /// عن قصده، والقصد لا يُفحص من بعيد.
  ///
  /// **ويعيد المسافة أيضاً** — كان يعيد `true/false` فقط، فيُسأل السائق
  /// ويمضي ولا يبقى أثر. ولا سبيل بعدها لتمييز رحلةٍ انتهت في مكانها
  /// من رحلةٍ انتهت في منتصف الطريق. وهو حارسٌ يعتمد عليه نظام الدعوة.
  Future<(bool, int?)> _confirmFarCompletion(Map<String, dynamic> trip) async {
    final dropoff = _extractPoint(trip, 'dropoff');
    if (dropoff == null) return (true, null);   // لا إحداثيات — لا قياس

    final pos = ref.read(locationTrackerProvider);
    if (pos == null) return (true, null);       // لا موقع — لا نعطّل الإنهاء

    final meters = Geolocator.distanceBetween(
      pos.latitude, pos.longitude, dropoff.$1, dropoff.$2,
    ).round();

    // **نقرأ الحدّ لا نفترضه.** والقراءة هنا لا عند فتح الشاشة: نداءٌ
    // واحد عند الإنهاء أهون من نداءٍ في كل رحلة لا تصل مرحلته.
    var limit = _dropoffWarnRadiusFallback;
    try {
      limit = await ref
          .read(driverRepositoryProvider)
          .dropoffWarnRadius('${trip['id']}');
    } catch (_) {
      // شبكةٌ منقطعة. نحذّر بالاحتياطي ولا نعطّل الإنهاء.
    }

    if (meters <= limit) return (true, meters);

    if (!mounted) return (false, meters);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('أنت بعيد عن منطقة الوصول'),
        content: Text(
          'تبعد ${meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} كم' : '$meters متر'} '
          'عن وجهة الراكب. هل أنت متأكد من إنهاء الرحلة؟',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('نعم، أنهِها')),
        ],
      ),
    );
    return (ok == true, meters);
  }

  // ---------------------------------------------------------------------------
  // إلغاء السائق
  // ---------------------------------------------------------------------------
  Future<void> _cancel(Map<String, dynamic> trip) async {
    final id = _tripId;
    if (id == null) return;

    // نقرأ العدّاد **قبل** السؤال لنُري السائق العاقبة بدل أن يكتشفها
    // بعد الخصم. فشل القراءة لا يمنع الإلغاء — نسأل بلا رقم.
    int? used;
    int? free;
    int? penalty;
    try {
      final r = await ref.read(driverRepositoryProvider).cancelsToday();
      used = r.$1;
      free = r.$2;
      penalty = r.$3;
    } catch (_) {}

    if (!mounted) return;
    final remaining = (free == null || used == null) ? null : free - used;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إلغاء الرحلة'),
        content: Text(
          remaining == null
              ? 'الراكب ينتظرك الآن. هل تريد إلغاء الرحلة؟'
              : remaining > 0
                  ? 'الراكب ينتظرك الآن.\n\n'
                      'لك $remaining إلغاء مجاني اليوم. '
                      'بعدها يُخصم $penalty دينار عن كل إلغاء.'
                  : 'الراكب ينتظرك الآن.\n\n'
                      'استنفدت إلغاءاتك المجانية اليوم، '
                      'وسيُخصم $penalty دينار من رصيدك.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('إلغاء الرحلة'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(driverRepositoryProvider).cancel(id);
      // الموجّه يعيدنا إلى الخريطة حين تختفي الرحلة النشطة.
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// هل بقيت محطة بعد الحالية؟
  static bool _moreStops(Map<String, dynamic> trip) {
    final legs = (trip['stop_count'] as num?)?.toInt() ?? 1;
    final leg = (trip['current_leg'] as num?)?.toInt() ?? 1;
    return leg < legs;
  }

  /// يعرض طلب تغيير الوجهة ويأخذ ردّ السائق.
  ///
  /// **الرفض ليس عقوبة ولا إلغاءً.** الراكب طلب واعتذر السائق، وتمضي
  /// الرحلة إلى وجهتها الأصلية بلا رسوم على أحد.
  Future<void> _showChangeRequest(Map<String, dynamic> req) async {
    final quoted = (req['quoted_fare_iqd'] as num?)?.round() ?? 0;
    final km = ((req['new_leg_m'] as num?)?.toDouble() ?? 0) / 1000;

    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('الراكب يطلب تغيير الوجهة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${req['new_address'] ?? 'وجهة جديدة'}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('${km.toStringAsFixed(1)} كم إضافية من موقعك الحالي'),
            const SizedBox(height: 6),
            Text('الأجرة تصير $quoted دينار — شاملةً ما قطعته حتى الآن.'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('اعتذر')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('موافق')),
        ],
      ),
    );

    if (accept == null) return;
    try {
      await ref
          .read(driverRepositoryProvider)
          .respondToChange(req['id'] as String, accept);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    }
  }

  /// إحداثيات محطة. `trip_stops` تحمل الموقع بصيغة geography، ونقرأ
  /// الحقول المسطّحة إن وفّرها المُشغّل — وإلا نرجع للوجهة الأخيرة.
  (double, double)? _stopPoint(Map<String, dynamic> stop) {
    final lat = stop['lat'];
    final lng = stop['lng'];
    if (lat is num && lng is num) return (lat.toDouble(), lng.toDouble());
    return null;
  }

  /// يستخرج الإحداثيات من عمود geography.
  ///
  /// PostgREST يعيد النقطة بصيغة WKB سداسية عشرية افتراضياً وهي غير
  /// صالحة للقراءة هنا. الحل العملي: نستعمل العنوان النصي للعرض،
  /// والملاحة تحتاج إحداثيات — فنقرؤها من الحقول المسطّحة إن توفرت.
  (double, double)? _extractPoint(Map<String, dynamic> trip, String which) {
    final lat = trip['${which}_lat'];
    final lng = trip['${which}_lng'];
    if (lat is num && lng is num) return (lat.toDouble(), lng.toDouble());
    return null;
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.status, this.shopping = false});
  final String status;
  final bool shopping;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // **أسماء المراحل تتبع نوع الطلب.** «الرحلة جارية» في طلب تسوّق
    // تصف شيئاً لا يحدث: لا راكب على الدراجة، بل بضاعةٌ في الطريق.
    final steps = shopping
        ? ['إلى المتجر', 'في المتجر', 'إلى التسليم']
        : ['في الطريق', 'وصلت', 'الرحلة جارية'];
    final current = switch (status) {
      'accepted' => 0,
      'driver_arrived' => 1,
      _ => 2,
    };

    return Row(
      children: List.generate(steps.length * 2 - 1, (i) {
        if (i.isOdd) {
          return Expanded(
            child: Container(
              height: 2,
              color: (i ~/ 2) < current
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          );
        }
        final idx = i ~/ 2;
        final done = idx <= current;
        return Column(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: done
                  ? theme.colorScheme.primary
                  : theme.colorScheme.surfaceContainerHighest,
              child: Icon(
                done ? Icons.check : Icons.circle_outlined,
                size: 16,
                color: done
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 4),
            Text(steps[idx], style: theme.textTheme.bodySmall),
          ],
        );
      }),
    );
  }
}

class _Addr extends StatelessWidget {
  const _Addr({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.active,
    this.title,
  });

  final IconData icon;
  final Color color;
  final String label;

  /// اسمٌ يعلو العنوان بخطٍّ عريض — اسم المحل في طلب التسوّق. هو ما
  /// يبحث عنه السائق بعينه في الشارع، والعنوان تحته للتوجيه.
  final String? title;
  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      // المرحلة غير النشطة تبهت — يبقى السائق مركّزاً على وجهته الحالية
      opacity: active ? 1.0 : 0.45,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                if (title != null && title!.trim().isNotEmpty)
                  Text(title!.trim(),
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                Text(value.isEmpty ? 'موقع على الخريطة' : value,
                    style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RiderCard extends ConsumerWidget {
  const _RiderCard({required this.tripId, required this.status});

  final String tripId;
  /// حالة الرحلة — تحدّد نصّ رسالة واتساب الجاهزة.
  final String status;

  /// **الرسالة تتبع الموقف لا العكس.** قبل الوصول يقول السائق إنه في
  /// الطريق، وبعده إنه ينتظر. رسالة واحدة ثابتة تجعله يكتب التصحيح
  /// بنفسه في كل مرة وهو واقف بدراجته.
  String get _waMessage => switch (status) {
        'accepted' => 'مرحباً، أنا سائق زنبور وفي طريقي إليك.',
        'driver_arrived' => 'أنا في انتظارك في نقطة الانطلاق.',
        _ => 'مرحباً، أنا سائق زنبور.',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final party = ref.watch(tripRiderProvider(tripId));

    return party.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (r) {
        if (r == null) return const SizedBox.shrink();
        final phone = r['phone'] as String?;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // **لا صورة للراكب بقرار صريح.** الراكب يرى صورة سائقه
                // لأنه يركب خلف رجل لا يعرفه؛ والسائق يكفيه الاسم
                // والهاتف. والعرض في القاعدة لا يرسلها أصلاً بعد 0021.
                CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(Icons.person,
                      color: theme.colorScheme.onPrimaryContainer),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r['full_name'] ?? 'الراكب'}',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      if (phone != null)
                        Text(phone,
                            textDirection: TextDirection.ltr,
                            style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                // واتساب واتصال معاً: السائق الذي لا يجد المدخل يرسل
                // موقعه على واتساب، وذلك أسهل من مكالمة وهو على دراجة.
                if (phone != null)
                  ContactButtons(
                    phone: phone,
                    message: _waMessage,
                    compact: true,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// بيانات الراكب — الحقول الآمنة فقط، والهاتف أثناء الرحلة النشطة وحدها.
final tripRiderProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, tripId) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('trip_party_info')
      .select()
      .eq('trip_id', tripId)
      .eq('party', 'rider');
  return rows.isEmpty ? null : rows.first;
});

// =============================================================================
/// قائمة الطلب — تُفتح متى شاء.
void _showItems(BuildContext context, Map<String, dynamic> trip) {
  final items = (trip['items'] as List?) ?? const [];
  final est = (trip['goods_estimate_iqd'] as num?)?.round() ?? 0;

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text('قائمة الطلب',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('قدّر الراكب $est دينار',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            for (final i in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    const Icon(Icons.circle, size: 7),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${(i as Map)['name'] ?? ''}',
                          style: theme.textTheme.bodyLarge),
                    ),
                    Text('${i['qty'] ?? ''}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            if ('${trip['rider_note'] ?? ''}'.trim().isNotEmpty) ...[
              const Divider(height: 28),
              Text('ملاحظة الراكب', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text('${trip['rider_note']}', style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      );
    },
  );
}

/// سعر البضاعة الحقيقي — بعد الشراء وبعد الاتفاق هاتفياً.
///
/// **الاتفاق قبل الكتابة لا بعدها.** رقمٌ يظهر على شاشة الراكب بلا أن
/// يُستأذَن فيه خلافٌ لا محالة — والسائق واقفٌ أمام بابه بعد قليل.
Future<void> _enterGoodsPrice(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> trip,
) async {
  final ctrl = TextEditingController(
    text: (trip['goods_actual_iqd'] as num?)?.round().toString() ?? '',
  );

  final amount = await showDialog<num>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('سعر البضاعة'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('اتّصل بالراكب واتّفقا على المبلغ، ثم اكتبه هنا. '
              'يظهر عنده فوراً مع أجرة التوصيل.'),
          const SizedBox(height: 16),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              suffixText: 'دينار',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('تراجع')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, num.tryParse(ctrl.text.trim())),
          child: const Text('تثبيت'),
        ),
      ],
    ),
  );

  if (amount == null || amount <= 0 || !context.mounted) return;

  try {
    await ref
        .read(driverRepositoryProvider)
        .setGoodsPrice(tripId: trip['id'] as String, amount: amount);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppError.message(e))));
    }
  }
}
