import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../core/perms.dart';

final zonesProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(adminRepositoryProvider).zones(),
);

final reviewModeProvider = FutureProvider<bool>(
  (ref) => ref.watch(adminRepositoryProvider).reviewMode(),
);

/// مناطق الخدمة — أين يعمل التطبيق وأين لا يعمل.
///
/// **المحافظات الثماني عشرة كلها معرّفة، والمفعّل منها قرارك.** التوسّع
/// بضغطة لا بترحيل جديد، والحدود مرسومة الآن لا في يومٍ نكون فيه
/// مستعجلين.
///
/// **والتركيز قرار لا قصور:** مشكلة الدجاجة والبيضة تُحلّ بحيٍّ مكتظ فيه
/// عشرون سائقاً، لا بثماني عشرة محافظة فيها سائق أو اثنان. وراكبٌ في
/// بغداد يطلب فلا يجد أحداً لا يعود أبداً.
class ZonesPage extends ConsumerWidget {
  const ZonesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final zones = ref.watch(zonesProvider);
    final active = (zones.value ?? const [])
        .where((z) => z['is_active'] == true)
        .length;

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'مناطق الخدمة',
            subtitle: 'المنطقة المعطّلة تعني أن الراكب فيها يرى "خدمتنا غير '
                'متوفرة هنا" ولا يستطيع الطلب.',
            actions: [
              if (zones.hasValue)
                Chip(label: Text('$active من ${zones.value!.length} مفعّلة')),
              IconButton.filledTonal(
                icon: const Icon(Icons.refresh),
                tooltip: 'تحديث',
                onPressed: () => ref.invalidate(zonesProvider),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _ReviewModeCard(),
          const SizedBox(height: 16),
          Expanded(
            child: zones.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(e,
                  onRetry: () => ref.invalidate(zonesProvider)),
              data: (list) => Card(
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final z = list[i];
                    final on = z['is_active'] == true;
                    return SwitchListTile(
                      value: on,
                      secondary: Icon(
                        on ? Icons.location_on : Icons.location_off,
                        color: on ? theme.colorScheme.primary : null,
                      ),
                      title: Row(
                        children: [
                          Text('${z['city_name_ar']}',
                              style: TextStyle(
                                  fontWeight: on
                                      ? FontWeight.bold
                                      : FontWeight.normal)),
                          const SizedBox(width: 12),
                          TextButton.icon(
                            onPressed: !can(ref, 'settings.manage') ? null : () => _tune(context, ref, z),
                            icon: const Icon(Icons.tune, size: 18),
                            label: const Text('الأرقام'),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        on
                            ? 'تعمل  ·  ${(z['base_fare_iqd'] as num).round()} '
                                '+ ${(z['per_km_iqd'] as num).round()}/كم'
                            : 'معطّلة',
                        style: theme.textTheme.bodySmall,
                      ),
                      onChanged: !can(ref, 'settings.manage') ? null : (v) => _toggle(context, ref, z, v),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _toggle(
    BuildContext context, WidgetRef ref, Map<String, dynamic> zone, bool on) async {
  if (on) {
    // **نسأل قبل التفعيل لا قبل التعطيل.** التعطيل يوقف الضرر، والتفعيل
    // يفتح مدينةً كاملة على خدمة قد لا يكون فيها سائق واحد.
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تفعيل ${zone['city_name_ar']}'),
        content: const Text(
          'سيتمكّن الركّاب هنا من الطلب فوراً.\n\n'
          'تأكّد أولاً من وجود سائقين معتمدين في المدينة — راكبٌ يطلب '
          'ولا يجد أحداً لا يعود غالباً.\n\n'
          'وحدود المنطقة مستطيل تقريبي يغطّي المدينة وشيئاً حولها؛ '
          'ارسم مضلعاً دقيقاً قبل التوسّع الجاد.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('فعّلها')),
        ],
      ),
    );
    if (ok != true) return;
  }

  try {
    await ref
        .read(adminRepositoryProvider)
        .setZoneActive(zone['id'] as String, on);
    ref.invalidate(zonesProvider);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

// =============================================================================
// ضبط أرقام المنطقة
// =============================================================================
/// **كل ما يحكم سلوك المطابقة والتسعير في مكان واحد.** كانت هذه الأرقام
/// أعمدةً في القاعدة لا يصلها إلا من يفتح محرر SQL — فتبقى على افتراضها
/// لا لأنها صحيحة بل لأن تغييرها متعب.
const _fields = <(String, String, String)>[
  ('base_fare_iqd', 'أجرة البداية', 'دينار'),
  ('per_km_iqd', 'سعر الكيلومتر', 'دينار'),
  ('minimum_fare_iqd', 'الحد الأدنى للأجرة', 'دينار'),
  ('commission_rate', 'نسبة العمولة', '٠٫١٥ = ١٥٪'),
  ('max_concurrent_offers', 'عروض متزامنة', 'سائق'),
  ('boosted_concurrent_offers', 'عروض بعد رفع السعر', 'سائق'),
  ('search_boost_pct', 'نسبة رفع السعر', '٪'),
  ('offer_timeout_s', 'مهلة ردّ السائق', 'ثانية'),
  ('offer_round_seconds', 'العودة إلى من رفض بعد', 'ثانية'),
  ('max_search_seconds', 'أقصى مدة بحث', 'ثانية'),
  ('search_radius_m', 'نطاق البحث', 'متر'),
  ('max_search_radius_m', 'أقصى نطاق بحث', 'متر'),
  ('arrival_radius_m', 'نطاق تأكيد الوصول', 'متر'),
  ('tuktuk_surcharge_pct', 'زيادة التكتك', '٪'),
  ('second_leg_discount_pct', 'خصم المرحلة الثانية', '٪'),
  ('stopover_surcharge_pct', 'زيادة التوقف', '٪'),
  ('stopover_free_minutes', 'دقائق التوقف المشمولة', 'دقيقة'),
  ('driver_free_cancels_per_day', 'إلغاءات السائق المجانية', 'يومياً'),
  ('driver_cancel_penalty_iqd', 'عقوبة إلغاء السائق', 'دينار'),
  ('cancellation_fee_iqd', 'رسوم إلغاء الراكب', 'دينار'),
  ('min_wallet_balance_iqd', 'حدّ الدين', 'دينار (سالب)'),
];

Future<void> _tune(
    BuildContext context, WidgetRef ref, Map<String, dynamic> zone) async {
  final ctls = {
    for (final f in _fields)
      f.$1: TextEditingController(text: '${zone[f.$1] ?? ''}')
  };
  var busy = false;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text('أرقام ${zone['city_name_ar']}'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 520),
          height: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final f in _fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: ctls[f.$1],
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: InputDecoration(
                        labelText: f.$2,
                        suffixText: f.$3,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                if (error != null)
                  Text(error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: !can(ref, 'settings.manage') ? null : busy
                ? null
                : () async {
                    setLocal(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      // نرسل ما تغيّر فقط: القاعدة تُبقي ما لم يُرسل على
                      // حاله، فحقلٌ تُرك فارغاً لا يصفّر الرقم.
                      final out = <String, num>{};
                      for (final f in _fields) {
                        final raw = ctls[f.$1]!.text.trim();
                        if (raw.isEmpty) continue;
                        final v = num.tryParse(raw);
                        if (v == null) {
                          throw 'قيمة غير صحيحة في «${f.$2}»';
                        }
                        if ('$v' != '${zone[f.$1]}') out[f.$1] = v;
                      }
                      if (out.isNotEmpty) {
                        await ref
                            .read(adminRepositoryProvider)
                            .setZoneNumbers(zone['id'] as String, out);
                      }
                      ref.invalidate(zonesProvider);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      setLocal(() {
                        error = '$e';
                        busy = false;
                      });
                    }
                  },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );

  for (final c in ctls.values) {
    c.dispose();
  }
}

// =============================================================================
/// وضع المراجعة — الخدمة متاحة في كل العالم.
///
/// **لماذا هنا لا في الإعدادات؟** لأنه سؤال تغطية لا سؤال ضبط: من يفتح
/// صفحة المناطق يسأل «أين نعمل؟»، وهذا المفتاح هو الجواب الأوسع عليه.
/// ودفنُه بين الأرقام يعني أن يُنسى مشتغلاً.
class _ReviewModeCard extends ConsumerStatefulWidget {
  const _ReviewModeCard();

  @override
  ConsumerState<_ReviewModeCard> createState() => _ReviewModeCardState();
}

class _ReviewModeCardState extends ConsumerState<_ReviewModeCard> {
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    // المُبلِّغ قبل نافذة التأكيد: النافذة فجوة غير متزامنة.
    final messenger = ScaffoldMessenger.of(context);

    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تشغيل وضع المراجعة'),
          content: SizedBox(
            width: Breaks.dialogWidth(ctx, 420),
            child: const Text(
              'ستصير الخدمة متاحة من أي مكان في العالم، بتسعيرة المنطقة '
              'الأولى المفعّلة.\n\n'
              'هذا للمراجعة والاختبار وحدهما. أطفئه فور قبول التطبيق — '
              'تركُه مشتغلاً يعني أن أي شخص في أي بلد يستطيع طلب رحلة لن '
              'يجد لها سائقاً.',
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('شغّله')),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).setReviewMode(on);
      ref.invalidate(reviewModeProvider);
      messenger.showSnackBar(SnackBar(
        content: Text(on
            ? 'وضع المراجعة يعمل — الخدمة متاحة في كل العالم'
            : 'أُطفئ وضع المراجعة — عادت الخدمة إلى المناطق المفعّلة'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = ref.watch(reviewModeProvider).value ?? false;

    return Card(
      color: on ? AdminTheme.warning.withValues(alpha: 0.14) : null,
      shape: on
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: AdminTheme.warning, width: 1.5),
            )
          : null,
      child: SwitchListTile(
        value: on,
        onChanged: !can(ref, 'settings.manage') ? null : _busy ? null : _toggle,
        secondary: Icon(on ? Icons.public : Icons.public_off,
            color: on ? AdminTheme.warning : null),
        title: Text(
          on ? 'وضع المراجعة يعمل — كل العالم' : 'وضع المراجعة',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: on ? AdminTheme.warning : null,
          ),
        ),
        subtitle: Text(
          on
              ? 'الخدمة متاحة من أي مكان في العالم. أطفئه فور قبول التطبيق '
                  'في المتجر.'
              : 'شغّله يوم إرسال التطبيق للمراجعة، ليستطيع مراجع جوجل أو '
                  'آبل طلب رحلة من مكتبه خارج العراق.',
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}
