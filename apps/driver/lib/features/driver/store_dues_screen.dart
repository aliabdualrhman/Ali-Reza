import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';

final storeDuesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(driverRepositoryProvider).storeDues(),
);

/// مستحقات المتاجر — ثمن السلع التي قبضها المندوب من المستلمين في طلبات
/// «يُعاد الثمن بعد التسليم»، ولم يُسلّمها للمتجر بعد.
///
/// **المندوب يعلن والتاجر يؤكّد.** الزرّ هنا لا يُغلق الدين؛ يرسل للتاجر
/// سؤالاً «هل وصلك؟» — فإن قال نعم أُغلق، وإن قال لا صار نزاعاً تتابعه
/// الإدارة. إغلاقٌ بشهادة المدين وحده ليس إغلاقاً.
class StoreDuesScreen extends ConsumerWidget {
  const StoreDuesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dues = ref.watch(storeDuesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('مستحقات المتاجر')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(storeDuesProvider),
        child: dues.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [
            const SizedBox(height: 120),
            Center(child: Text(AppError.message(e))),
          ]),
          data: (rows) {
            final open = rows.where((r) => r['settle_status'] != 'closed');
            final owed = open.fold<num>(
                0, (a, r) => a + ((r['goods_actual_iqd'] as num?) ?? 0));

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.storefront_outlined,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('بذمّتك للمتاجر',
                              style: theme.textTheme.titleMedium),
                        ),
                        Text('${owed.round()} دينار',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: owed > 0 ? ZanbourTheme.warning : null,
                            )),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 60),
                    child: Center(child: Text('لا مستحقات')),
                  ),
                for (final r in rows) _DueTile(row: r),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DueTile extends ConsumerStatefulWidget {
  const _DueTile({required this.row});
  final Map<String, dynamic> row;

  @override
  ConsumerState<_DueTile> createState() => _DueTileState();
}

class _DueTileState extends ConsumerState<_DueTile> {
  bool _busy = false;

  Future<void> _claim() async {
    final r = widget.row;
    final amount = ((r['goods_actual_iqd'] as num?) ?? 0).round();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تم إغلاق المستحقات؟'),
        content: Text(
          'تؤكّد أنك سلّمت ${r['shop_name'] ?? 'المتجر'} مبلغ $amount دينار '
          'عن الطلب رقم ${r['trip_number']}.\n\n'
          'يصل المتجرَ سؤالٌ ليؤكّد الاستلام، ولا يُغلق الدين قبل تأكيده.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('نعم، سلّمته'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(driverRepositoryProvider)
          .claimDeliverySettled(r['id'] as String);
      ref.invalidate(storeDuesProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('أُرسل للمتجر — بانتظار تأكيده'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppError.message(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.row;
    final status = '${r['settle_status']}';
    final amount = ((r['goods_actual_iqd'] as num?) ?? 0).round();

    final (label, color) = switch (status) {
      'open' => ('لم يُسلَّم', ZanbourTheme.warning),
      'claimed' => ('بانتظار تأكيد المتجر', theme.colorScheme.primary),
      'disputed' => ('المتجر يقول لم يصله', theme.colorScheme.error),
      _ => ('أُغلق', ZanbourTheme.success),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${r['shop_name'] ?? 'متجر'}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Text('$amount دينار',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'الطلب رقم ${r['trip_number']} · ${_date(r['completed_at'])}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 6),
                Expanded(child: Text(label, style: TextStyle(color: color))),
              ],
            ),
            // **تحت السطر لا بجانبه.** ثيم التطبيق يجعل الزرّ بعرض الشاشة؛
            // داخل صفٍّ بلا حدّ صار عرضه لا نهائياً، فسقط رسمُ السطر كله
            // وبقي مكانه فراغاً — ولم يجد المندوب زرّاً يُطفئ به دينه.
            if (status == 'open' || status == 'disputed') ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _busy ? null : _claim,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.task_alt),
                label: const Text('تم إغلاق المستحقات'),
              ),
            ],
            if (r['store_phone'] != null && status != 'closed') ...[
              const SizedBox(height: 8),
              ContactButtons(
                phone: '${r['store_phone']}',
                message: 'مرحباً، أنا مندوب زنبور بخصوص الطلب رقم '
                    '${r['trip_number']}.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _date(Object? raw) {
  final d = DateTime.tryParse('$raw')?.toLocal();
  if (d == null) return '';
  return '${d.year}/${d.month}/${d.day}';
}
