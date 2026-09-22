import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'delivery_repository.dart';
import 'store_screen.dart';

/// «طلبات المندوب» — ما في الطريق الآن، وكشف الحساب.
///
/// **كشف حسابٍ لا سجلٌّ فقط.** التاجر يسأل كل مساء: كم طرداً وصل؟ وكم
/// عند المناديب من مالي؟ فالمجاميع قبل القائمة، والمستحقات قبل التاريخ.
class DeliveriesScreen extends ConsumerWidget {
  const DeliveriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final store = ref.watch(myStoreProvider);
    final all = ref.watch(myDeliveriesProvider);
    final services = ref.watch(serviceStatusProvider).value ??
        const ServiceAvailability.open();

    final approved = store.value?['status'] == 'approved';

    return Scaffold(
      appBar: AppBar(
        title: const Text('طلبات المندوب'),
        actions: [
          IconButton(
            tooltip: 'متجري',
            icon: const Icon(Icons.storefront_outlined),
            onPressed: () => context.push('/store'),
          ),
        ],
      ),
      floatingActionButton: approved && services.delivery
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/delivery/new'),
              icon: const Icon(Icons.add),
              label: const Text('طلب مندوب'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myDeliveriesProvider);
          ref.invalidate(myStoreProvider);
        },
        child: all.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [
            const SizedBox(height: 120),
            Center(child: Text(AppError.message(e))),
          ]),
          data: (rows) {
            final confirms =
                rows.where((r) => r['settle_status'] == 'claimed').toList();
            final live = rows
                .where((r) => kLiveDeliveryStatuses.contains(r['status']))
                .toList();
            final past = rows
                .where((r) => !kLiveDeliveryStatuses.contains(r['status']))
                .toList();

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                if (store.value != null && !approved) ...[
                  StoreStatusBanner(store: store.value!),
                  const SizedBox(height: 12),
                ],
                if (!services.delivery) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(services.deliveryMessage.isEmpty
                          ? 'خدمة طلب المندوب متوقّفة مؤقّتاً.'
                          : services.deliveryMessage),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // ---- بانتظار تأكيدك ----
                if (confirms.isNotEmpty) ...[
                  _Header('بانتظار تأكيدك'),
                  for (final r in confirms) SettleConfirmCard(trip: r),
                  const SizedBox(height: 8),
                ],

                _Summary(rows: rows),
                const SizedBox(height: 12),

                if (live.isNotEmpty) ...[
                  _Header('في الطريق الآن (${live.length})'),
                  for (final r in live) DeliveryTile(trip: r),
                  const SizedBox(height: 8),
                ],

                _Header('السجلّ'),
                if (past.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: Text('لا طلبات بعد',
                          style: theme.textTheme.bodyMedium),
                    ),
                  ),
                for (final r in past) DeliveryTile(trip: r),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      );
}

/// المجاميع: ما وصل هذا الشهر، وما عند المناديب من مالك.
class _Summary extends StatelessWidget {
  const _Summary({required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);

    final delivered = rows.where((r) =>
        r['status'] == 'completed' &&
        r['delivery_outcome'] == 'delivered' &&
        (DateTime.tryParse('${r['completed_at']}')?.toLocal().isAfter(month) ??
            false));
    final fees = delivered.fold<num>(
        0, (a, r) => a + ((r['fare_final_iqd'] as num?) ?? 0));

    final owed = rows
        .where((r) => const {'open', 'claimed', 'disputed'}
            .contains(r['settle_status']))
        .fold<num>(0, (a, r) => a + ((r['goods_actual_iqd'] as num?) ?? 0));

    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 2),
              Text(label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Row(
          children: [
            cell('وصل هذا الشهر', '${delivered.length}'),
            cell('أجور التوصيل هذا الشهر', '${fees.round()}'),
            cell('عند المناديب لك', '${owed.round()}',
                color: owed > 0 ? ZanbourTheme.warning : null),
          ],
        ),
      ),
    );
  }
}

/// صفٌّ في القائمة — يُفتح على التفاصيل.
class DeliveryTile extends StatelessWidget {
  const DeliveryTile({super.key, required this.trip});
  final Map<String, dynamic> trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = '${trip['status']}';
    final live = kLiveDeliveryStatuses.contains(status);
    final settle = trip['settle_status'] as String?;
    final goods = ((trip['goods_actual_iqd'] as num?) ?? 0).round();
    final fee = ((trip['fare_final_iqd'] ?? trip['fare_estimated_iqd'] ?? 0)
            as num)
        .round();

    final color = switch (status) {
      'completed' => trip['delivery_outcome'] == 'returned'
          ? theme.colorScheme.error
          : ZanbourTheme.success,
      'cancelled' || 'no_drivers' => theme.colorScheme.outline,
      _ => theme.colorScheme.primary,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => context.push('/delivery/${trip['id']}'),
        leading: Icon(
          live ? Icons.delivery_dining : Icons.inventory_2_outlined,
          color: color,
        ),
        title: Text('${trip['dropoff_address'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${deliveryStageLabel(trip)} · رقم ${trip['trip_number']}'
              ' · ${_date(trip['requested_at'])}',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
            if (settle != null)
              Text(
                switch (settle) {
                  'open' => 'بذمّة المندوب $goods دينار',
                  'claimed' => 'المندوب يقول إنه أعاد $goods — أكّد',
                  'disputed' => 'نزاع على $goods دينار — الإدارة تتابع',
                  _ => 'أُغلقت المستحقات',
                },
                style: theme.textTheme.bodySmall?.copyWith(
                  color: settle == 'closed'
                      ? theme.colorScheme.onSurfaceVariant
                      : ZanbourTheme.warning,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
        trailing: Text('$fee د',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      ),
    );
  }
}

/// «هل وصلك ثمن الطلب؟» — نعم تُغلق، ولا تفتح نزاعاً.
class SettleConfirmCard extends ConsumerStatefulWidget {
  const SettleConfirmCard({super.key, required this.trip});
  final Map<String, dynamic> trip;

  @override
  ConsumerState<SettleConfirmCard> createState() => _SettleConfirmCardState();
}

class _SettleConfirmCardState extends ConsumerState<SettleConfirmCard> {
  bool _busy = false;

  Future<void> _answer(bool received) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(deliveryRepositoryProvider)
          .confirmSettled(widget.trip['id'] as String, received);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(received
              ? 'أُغلقت المستحقات'
              : 'سُجّل أن المبلغ لم يصلك — الإدارة تتابع'),
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
    final t = widget.trip;
    final goods = ((t['goods_actual_iqd'] as num?) ?? 0).round();

    return Card(
      color: ZanbourTheme.warning.withValues(alpha: 0.10),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('هل وصلك المبلغ المتبقي؟',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('يقول المندوب إنه أعاد لك $goods دينار — الطلب رقم '
                '${t['trip_number']} (${t['dropoff_address'] ?? ''}).'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : () => _answer(true),
                    child: const Text('نعم، وصلني'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _answer(false),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error),
                    child: const Text('لا، لم يصلني'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _date(Object? raw) {
  final d = DateTime.tryParse('$raw')?.toLocal();
  if (d == null) return '';
  return '${d.month}/${d.day} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
