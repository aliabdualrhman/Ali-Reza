import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/perms.dart';

class PayoutQuery {
  const PayoutQuery(this.status, this.text);
  final String? status;
  final String text;
  @override
  bool operator ==(Object other) =>
      other is PayoutQuery && other.status == status && other.text == text;
  @override
  int get hashCode => Object.hash(status, text);
}

final payoutsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, PayoutQuery>(
  (ref, q) => ref
      .watch(adminRepositoryProvider)
      .payoutRequests(q.status, query: q.text),
);

/// طلبات سحب السائقين إلى زين كاش.
///
/// **الترتيب المقصود للعمل:** افتح الطلب، حوّل المبلغ يدوياً من زين كاش
/// إلى الرقم المعروض، **ثم** اضغط "تمّ الدفع". الضغط هو ما يخصم من رصيد
/// السائق — فلا تضغطه قبل التحويل، ولا تحوّل مرتين إن تردّدت.
class PayoutsPage extends ConsumerStatefulWidget {
  const PayoutsPage({super.key});

  @override
  ConsumerState<PayoutsPage> createState() => _PayoutsPageState();
}

class _PayoutsPageState extends ConsumerState<PayoutsPage> {
  String? _filter = 'pending';
  String _text = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(payoutsProvider(PayoutQuery(_filter, _text)));

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'طلبات السحب',
            actions: [
              FilterChoice<String?>(
                value: _filter,
                options: const [
                  ('pending', 'معلّقة'),
                  ('paid', 'مدفوعة'),
                  (null, 'الكل'),
                ],
                onChanged: (v) => setState(() => _filter = v),
              ),
              SearchField(
                controller: _search,
                hint: 'اسم السائق أو هاتفه',
                onSubmitted: (v) => setState(() => _text = v),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: rows.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(e,
                  onRetry: () => ref.invalidate(payoutsProvider)),
              data: (list) {
                if (list.isEmpty) {
                  return const Center(child: Text('لا توجد طلبات'));
                }
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => _PayoutRow(row: list[i]),
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

class _PayoutRow extends ConsumerWidget {
  const _PayoutRow({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final driver = row['drivers'] as Map<String, dynamic>?;
    final profile = driver?['profiles'] as Map<String, dynamic>?;
    final status = '${row['status']}';
    final pending = status == 'pending';
    final balance = (driver?['wallet_balance_iqd'] as num?)?.round() ?? 0;
    final amount = (row['amount_iqd'] as num).round();

    final compact = Breaks.isCompact(context);

    // من يرى الطلبات ولا يعالجها: يرى «بانتظار» بدل زرّين.
    final actions = !pending
        ? Text(status == 'paid' ? 'مدفوع' : 'مرفوض')
        : !can(ref, 'payouts.process')
            ? const Text('بانتظار المعالجة')
            : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => _reject(context, ref, row['id'] as String),
                child: const Text('رفض'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () =>
                    _confirmPaid(context, ref, row['id'] as String, amount),
                child: const Text('تمّ الدفع'),
              ),
            ],
          );

    return ListTile(
      contentPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 20, vertical: 12),
      leading: Icon(switch (status) {
        'paid' => Icons.check_circle,
        'rejected' => Icons.cancel,
        _ => Icons.hourglass_top,
      }),
      title: Text('${profile?['full_name'] ?? 'سائق'} — $amount دينار',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          SelectableText('زين كاش: ${row['zain_phone']}',
              textDirection: TextDirection.ltr),
          Text(
            'رصيده الآن $balance دينار · طُلب ${_date(row['requested_at'])}'
            '${'${row['admin_note'] ?? ''}'.isEmpty ? '' : ' · ${row['admin_note']}'}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          // على الهاتف: الأزرار تحت النص لا بجانبه. زرّان عربيان في
          // `trailing` يزاحمان الاسم فيُقصّ أحدهما خارج الشاشة.
          if (compact)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: actions,
              ),
            ),
        ],
      ),
      trailing: compact ? null : actions,
    );
  }
}

Future<void> _confirmPaid(
    BuildContext context, WidgetRef ref, String id, int amount) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تأكيد الدفع'),
      content: Text(
        'هل حوّلت $amount دينار فعلاً عبر زين كاش؟\n\n'
        'الضغط على "تمّ" يخصم المبلغ من رصيد السائق. '
        'لا تضغطه قبل إتمام التحويل.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: const Text('تمّ')),
      ],
    ),
  );
  if (ok != true) return;

  try {
    await ref.read(adminRepositoryProvider).markPayoutPaid(id);
    ref.invalidate(payoutsProvider);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

Future<void> _reject(BuildContext context, WidgetRef ref, String id) async {
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('رفض الطلب'),
      content: SizedBox(
        width: Breaks.dialogWidth(ctx, 360),
        child: TextField(
          controller: note,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'السبب',
            hintText: 'يراه السائق في سجل طلباته',
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: const Text('رفض')),
      ],
    ),
  );

  if (ok == true) {
    try {
      await ref.read(adminRepositoryProvider).rejectPayout(id, note.text.trim());
      ref.invalidate(payoutsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
  note.dispose();
}

String _date(Object? raw) {
  final d = DateTime.tryParse('$raw')?.toLocal();
  if (d == null) return '';
  return '${d.year}/${d.month}/${d.day}';
}
