import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/perms.dart';

final couponsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(adminRepositoryProvider).coupons(),
);

final couponUsageProvider = FutureProvider<Map<String, int>>(
  (ref) => ref.watch(adminRepositoryProvider).couponUsage(),
);

/// كوبونات الخصم — إنشاؤها ومتابعتها وإيقافها.
///
/// **الخصم يتحمّله المنصة لا السائق.** الراكب يدفع أقل، والفرق يدخل محفظة
/// السائق تعويضاً، والعمولة تبقى على الأجرة الكاملة. فحملة ٢٥٪ على رحلة
/// بألف تكلّفنا ٢٥٠ ديناراً — رقم نعرفه ونقيسه، لا خصمٌ نأخذه من دخل
/// السائق فيكرهنا.
class CouponsPage extends ConsumerWidget {
  const CouponsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final coupons = ref.watch(couponsProvider);
    final usage = ref.watch(couponUsageProvider).value ?? const {};

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'الكوبونات',
            actions: [
              if (can(ref, 'coupons.manage'))
              FilledButton.icon(
                onPressed: () => _createDialog(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('كوبون جديد'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: coupons.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(e,
                  onRetry: () => ref.invalidate(couponsProvider)),
              data: (list) {
                if (list.isEmpty) {
                  return const Center(child: Text('لا توجد كوبونات بعد'));
                }
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = list[i];
                      final active = c['is_active'] == true;
                      final until = DateTime.tryParse('${c['valid_until']}');
                      final expired =
                          until != null && until.isBefore(DateTime.now());
                      final used = usage['${c['id']}'] ?? 0;

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10),
                        leading: Icon(
                          !active
                              ? Icons.block
                              : expired
                                  ? Icons.schedule
                                  : Icons.local_offer,
                          color: !active || expired
                              ? theme.colorScheme.error
                              : theme.colorScheme.primary,
                        ),
                        title: Row(
                          children: [
                            SelectableText(
                              '${c['code']}',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(width: 10),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 18),
                              tooltip: 'نسخ',
                              onPressed: () async {
                                await Clipboard.setData(
                                    ClipboardData(text: '${c['code']}'));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('نُسخ الرمز')),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                        subtitle: Text([
                          'خصم ${c['discount_pct']}٪',
                          'كل الركّاب',
                          '${c['max_uses_per_rider']} استعمال لكل راكب',
                          'استُعمل $used مرة',
                          if (until != null)
                            'ينتهي ${_date(until)}'
                          else
                            'بلا انتهاء',
                          if ((c['creator'] as Map?)?['full_name'] != null)
                            'أنشأه ${(c['creator'] as Map)['full_name']}',
                          if (!active) 'موقوف',
                          if (expired) 'منتهٍ',
                        ].join('  ·  ')),
                        // من يرى ولا يدير: المفتاح يظهر حالةً لا زرّاً.
                        trailing: Switch(
                          value: active,
                          onChanged: !can(ref, 'coupons.manage')
                              ? null
                              : (v) async {
                            await ref
                                .read(adminRepositoryProvider)
                                .setCouponActive(c['id'] as String, v);
                            ref.invalidate(couponsProvider);
                          },
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _date(DateTime d) {
  final l = d.toLocal();
  return '${l.year}/${l.month}/${l.day}';
}

// =============================================================================
Future<void> _createDialog(BuildContext context, WidgetRef ref) async {
  final code = TextEditingController();
  final pct = TextEditingController(text: '25');
  final uses = TextEditingController(text: '1');
  final note = TextEditingController();
  DateTime? until;
  var busy = false;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('كوبون جديد'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: code,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'الرمز',
                    hintText: 'ZANBOUR25',
                    helperText: 'يكتبه الراكب في التطبيق. حالة الأحرف لا تهم.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pct,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'نسبة الخصم',
                    suffixText: '٪',
                    helperText: 'بين ١ و١٠٠',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: uses,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'عدد الاستعمالات لكل راكب',
                    helperText: 'وليس للكوبون كله',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(until == null
                          ? 'بلا تاريخ انتهاء'
                          : 'ينتهي ${_date(until!)}'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: now.add(const Duration(days: 30)),
                          firstDate: now,
                          lastDate: now.add(const Duration(days: 730)),
                        );
                        if (picked != null) setLocal(() => until = picked);
                      },
                      child: const Text('اختر تاريخاً'),
                    ),
                    if (until != null)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setLocal(() => until = null),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظة (اختيارية)',
                    hintText: 'حملة افتتاح الناصرية',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!,
                      style:
                          TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setLocal(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await ref.read(adminRepositoryProvider).createCoupon(
                            code: code.text,
                            discountPct: int.tryParse(pct.text) ?? 0,
                            maxUsesPerRider: int.tryParse(uses.text) ?? 1,
                            // نهاية اليوم المختار لا بدايته: من اختار
                            // الثلاثين يقصد أن يعمل الكوبون طوال ذلك اليوم.
                            validUntil: until == null
                                ? null
                                : DateTime(until!.year, until!.month,
                                    until!.day, 23, 59, 59),
                            note: note.text.trim().isEmpty
                                ? null
                                : note.text.trim(),
                          );
                      ref.invalidate(couponsProvider);
                      ref.invalidate(couponUsageProvider);
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text('أُنشئ الكوبون ${code.text.trim()}'),
                        ));
                      }
                    } catch (e) {
                      setLocal(() {
                        error = '$e';
                        busy = false;
                      });
                    }
                  },
            child: const Text('إنشاء'),
          ),
        ],
      ),
    ),
  );

  code.dispose();
  pct.dispose();
  uses.dispose();
  note.dispose();
}
