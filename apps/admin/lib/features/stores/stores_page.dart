import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web/web.dart' as web;

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';
import '../trips/trip_detail_page.dart';
import '../trips/trips_page.dart' show fmtDateTime;
import '../../core/perms.dart';

/// (الحالة، البحث)
typedef _StoresQ = ({String? status, String text});

final _storesProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, _StoresQ>(
  (ref, q) => ref
      .watch(adminRepositoryProvider)
      .stores(status: q.status, query: q.text),
);

final _settlementsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>(
  (ref, status) =>
      ref.watch(adminRepositoryProvider).settlements(status: status),
);

/// المتاجر وطلب المندوب — اعتمادٌ ومستحقات.
///
/// **تبويبان لأن السؤالين مختلفان.** «من ينتظر اعتماداً؟» عملٌ يوميٌّ
/// يُنجَز ويُنسى؛ و«من عليه مالٌ لمن؟» متابعةٌ لا تنتهي حتى يُغلق آخر دين.
class StoresPage extends StatelessWidget {
  const StoresPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: EdgeInsets.all(Breaks.pad(context)),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: 'المتاجر',
              subtitle: 'طلب المندوب — اعتماد المتاجر ومستحقاتها',
            ),
            SizedBox(height: 12),
            TabBar(
              isScrollable: true,
              tabs: [Tab(text: 'المتاجر'), Tab(text: 'المستحقات')],
            ),
            SizedBox(height: 12),
            Expanded(
              child: TabBarView(children: [_StoresTab(), _SettlementsTab()]),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// المتاجر
// =============================================================================

class _StoresTab extends ConsumerStatefulWidget {
  const _StoresTab();

  @override
  ConsumerState<_StoresTab> createState() => _StoresTabState();
}

class _StoresTabState extends ConsumerState<_StoresTab> {
  String? _status = 'pending';
  String _text = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  _StoresQ get _q => (status: _status, text: _text);

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_storesProvider(_q));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChoice<String?>(
              value: _status,
              options: const [
                ('pending', 'بانتظار المراجعة'),
                ('changes', 'تعديلات تنتظر'),
                ('approved', 'معتمدة'),
                ('suspended', 'موقوفة'),
                ('rejected', 'مرفوضة'),
                (null, 'الكل'),
              ],
              onChanged: (v) => setState(() => _status = v),
            ),
            SearchField(
              controller: _search,
              width: 280,
              hint: 'اسم المتجر أو صاحبه أو رقمه',
              onSubmitted: (v) => setState(() => _text = v),
            ),
            IconButton.filledTonal(
              icon: const Icon(Icons.refresh),
              tooltip: 'تحديث',
              onPressed: () => ref.invalidate(_storesProvider(_q)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(e,
                onRetry: () => ref.invalidate(_storesProvider(_q))),
            data: (list) => list.isEmpty
                ? const Center(child: Text('لا متاجر هنا'))
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _StoreCard(
                      store: list[i],
                      onChanged: () => ref.invalidate(_storesProvider(_q)),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _StoreCard extends ConsumerStatefulWidget {
  const _StoreCard({required this.store, required this.onChanged});
  final Map<String, dynamic> store;
  final VoidCallback onChanged;

  @override
  ConsumerState<_StoreCard> createState() => _StoreCardState();
}

class _StoreCardState extends ConsumerState<_StoreCard> {
  bool _busy = false;

  Map<String, dynamic> get s => widget.store;

  Future<void> _do(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      widget.onChanged();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(adminError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  AdminRepository get _repo => ref.read(adminRepositoryProvider);

  Future<void> _reject() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('رفض «${s['name']}»'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 380),
          child: TextField(
            controller: reason,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'سبب الرفض — يراه التاجر',
              hintText: 'الموقع غير صحيح / الاسم غير واضح…',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('رفض')),
        ],
      ),
    );
    if (ok != true || reason.text.trim().isEmpty) return;
    await _do(
        () => _repo.setStoreStatus('${s['id']}', 'rejected',
            reason: reason.text.trim()),
        'رُفض المتجر');
  }

  Future<void> _rejectChanges() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('رفض التعديل'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 380),
          child: TextField(
            controller: reason,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'السبب — يراه التاجر، ومتجره يبقى ببياناته الحالية'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('رفض التعديل')),
        ],
      ),
    );
    if (ok != true || reason.text.trim().isEmpty) return;
    await _do(
        () => _repo.reviewStoreChanges('${s['id']}', false,
            reason: reason.text.trim()),
        'رُفض التعديل');
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('حذف «${s['name']}»'),
        content: const Text(
            'يُحذف المتجر نهائياً ويُشعَر صاحبه. طلباته السابقة تبقى في '
            'السجلّ. يستطيع تسجيله من جديد.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok == true) await _do(() => _repo.deleteStore('${s['id']}'), 'حُذف المتجر');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = '${s['status']}';
    final (label, color) = switch (status) {
      'approved' => ('معتمد', AdminTheme.success),
      'rejected' => ('مرفوض', theme.colorScheme.error),
      'suspended' => ('موقوف', theme.colorScheme.outline),
      _ => ('بانتظار المراجعة', AdminTheme.warning),
    };
    final lat = s['lat'], lng = s['lng'];
    final openAmount = ((s['open_amount_iqd'] as num?) ?? 0).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${s['name']}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                Chip(
                  label: Text(label),
                  side: BorderSide(color: color),
                  backgroundColor: color.withValues(alpha: 0.12),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('العنوان: ${s['address'] ?? '—'}'),
            SelectableText('هاتف المتجر: ${s['phone'] ?? '—'}'),
            const SizedBox(height: 6),
            Text(
              'الصاحب: ${s['owner_name'] ?? '—'} · ${s['owner_phone'] ?? '—'}'
              ' · ${s['owner_email'] ?? '—'}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'سُجّل ${fmtDateTime(s['created_at'])}'
              ' · آخر تعديل ${fmtDateTime(s['updated_at'])}'
              '${s['reviewed_at'] != null ? ' · رُوجع ${fmtDateTime(s['reviewed_at'])}' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            // **التعديل المعلّق: القديم بجانب الجديد.** المدير يعتمد ما
            // تغيّر لا المتجر كله — فيرى الفرق لا الصورة الكاملة.
            if (s['pending_changes'] is Map) ...[
              const SizedBox(height: 10),
              _ChangesDiff(store: s),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: !can(ref, 'stores.review') ? null : _busy
                        ? null
                        : () => _do(
                            () => _repo.reviewStoreChanges('${s['id']}', true),
                            'اعتُمد التعديل'),
                    icon: const Icon(Icons.check),
                    label: const Text('اعتماد التعديل'),
                  ),
                  OutlinedButton.icon(
                    onPressed: !can(ref, 'stores.review') ? null : _busy ? null : _rejectChanges,
                    icon: const Icon(Icons.close),
                    label: const Text('رفض التعديل'),
                  ),
                ],
              ),
              const Divider(height: 24),
            ],
            if (status == 'rejected' && s['rejection_reason'] != null)
              Text('سبب الرفض: ${s['rejection_reason']}',
                  style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 6),
            Text(
              'الطلبات: ${s['deliveries_total'] ?? 0} · النشطة الآن: '
              '${s['deliveries_active'] ?? 0} · مستحقات مفتوحة: '
              '${s['open_settlements'] ?? 0} ($openAmount دينار)',
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (lat is num && lng is num)
                  OutlinedButton.icon(
                    // اللوحة ويبٌ وحده — نافذةٌ جديدة بلا حزمة فتح روابط.
                    onPressed: () => web.window.open(
                        'https://www.google.com/maps/search/'
                        '?api=1&query=$lat,$lng',
                        '_blank'),
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('الموقع على الخريطة'),
                  ),
                if (status != 'approved')
                  FilledButton.icon(
                    onPressed: !can(ref, 'stores.review') ? null : _busy
                        ? null
                        : () => _do(
                            () => _repo.setStoreStatus('${s['id']}', 'approved'),
                            'اعتُمد المتجر'),
                    icon: const Icon(Icons.verified),
                    label: Text(status == 'suspended' ? 'إعادة التفعيل' : 'اعتماد'),
                  ),
                if (status == 'pending')
                  OutlinedButton.icon(
                    onPressed: !can(ref, 'stores.review') ? null : _busy ? null : _reject,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('رفض'),
                  ),
                if (status == 'approved')
                  OutlinedButton.icon(
                    onPressed: !can(ref, 'stores.review') ? null : _busy
                        ? null
                        : () => _do(
                            () => _repo.setStoreStatus('${s['id']}', 'suspended'),
                            'أُوقف المتجر مؤقتاً'),
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('إيقاف مؤقت'),
                  ),
                TextButton.icon(
                  onPressed: !can(ref, 'stores.review') ? null : _busy ? null : _delete,
                  style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// ما تغيّر في المتجر: كل حقلٍ مختلف سطرٌ، القديم ← الجديد.
class _ChangesDiff extends StatelessWidget {
  const _ChangesDiff({required this.store});
  final Map<String, dynamic> store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = (store['pending_changes'] as Map).cast<String, dynamic>();

    final rows = <(String, String, String)>[
      for (final (k, label) in const [
        ('name', 'الاسم'),
        ('phone', 'الهاتف'),
        ('address', 'العنوان'),
      ])
        if ('${c[k] ?? ''}' != '${store[k] ?? ''}')
          (label, '${store[k] ?? '—'}', '${c[k] ?? '—'}'),
    ];

    final oldLat = (store['lat'] as num?)?.toDouble();
    final oldLng = (store['lng'] as num?)?.toDouble();
    final newLat = (c['lat'] as num?)?.toDouble();
    final newLng = (c['lng'] as num?)?.toDouble();
    final moved = oldLat != null &&
        newLat != null &&
        ((oldLat - newLat).abs() > 0.00005 ||
            ((oldLng ?? 0) - (newLng ?? 0)).abs() > 0.00005);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AdminTheme.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AdminTheme.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('تعديلٌ ينتظر الموافقة — ${fmtDateTime(store['pending_changes_at'])}',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          for (final (label, from, to) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text.rich(TextSpan(children: [
                TextSpan(
                    text: '$label: ',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(
                    text: from,
                    style: const TextStyle(
                        decoration: TextDecoration.lineThrough)),
                const TextSpan(text: '  ←  '),
                TextSpan(
                    text: to,
                    style: const TextStyle(color: AdminTheme.success)),
              ])),
            ),
          if (moved)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('الموقع تغيّر:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                TextButton(
                  onPressed: () => web.window.open(
                      'https://www.google.com/maps/search/?api=1'
                      '&query=$oldLat,$oldLng',
                      '_blank'),
                  child: const Text('القديم'),
                ),
                TextButton(
                  onPressed: () => web.window.open(
                      'https://www.google.com/maps/search/?api=1'
                      '&query=$newLat,$newLng',
                      '_blank'),
                  child: const Text('الجديد'),
                ),
              ],
            ),
          if (rows.isEmpty && !moved) const Text('لا فرق ظاهر في الحقول'),
        ],
      ),
    );
  }
}

// =============================================================================
// المستحقات
// =============================================================================

class _SettlementsTab extends ConsumerStatefulWidget {
  const _SettlementsTab();

  @override
  ConsumerState<_SettlementsTab> createState() => _SettlementsTabState();
}

class _SettlementsTabState extends ConsumerState<_SettlementsTab> {
  /// null = كل غير المغلق؛ والقاعدة تعيد الكل إن طُلب، فنرشّح هنا.
  String? _status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = ref.watch(_settlementsProvider(
        _status == 'closed' ? 'closed' : _status));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChoice<String?>(
              value: _status,
              options: const [
                (null, 'غير المغلقة'),
                ('disputed', 'نزاعات'),
                ('claimed', 'بانتظار المتجر'),
                ('open', 'لم تُعَد'),
                ('closed', 'مغلقة'),
              ],
              onChanged: (v) => setState(() => _status = v),
            ),
            IconButton.filledTonal(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(_settlementsProvider),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(e,
                onRetry: () => ref.invalidate(_settlementsProvider)),
            data: (all) {
              final list = _status == null
                  ? all.where((r) => r['settle_status'] != 'closed').toList()
                  : all;
              final total = list.fold<num>(
                  0, (a, r) => a + ((r['amount_iqd'] as num?) ?? 0));
              if (list.isEmpty) {
                return const Center(child: Text('لا مستحقات هنا'));
              }
              return ListView(
                children: [
                  Text('${list.length} طلب · ${total.round()} دينار',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final r in list)
                    Card(
                      child: ListTile(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                TripDetailPage(tripId: '${r['trip_id']}'),
                          ),
                        ),
                        title: Text(
                            '${r['store_name'] ?? '—'} ← ${r['driver_name'] ?? '—'}'),
                        subtitle: Text(
                          'الطلب ${r['trip_number']} · '
                          '${fmtDateTime(r['completed_at'])} · '
                          '${switch (r['settle_status']) {
                            'open' => 'لم يُعِد المندوب الثمن',
                            'claimed' => 'المندوب يقول أعاده — بانتظار المتجر',
                            'disputed' => 'نزاع — المتجر يقول لم يصله',
                            _ => 'مغلقة',
                          }}\n'
                          'المندوب ${r['driver_phone'] ?? '—'} · المتجر ${r['store_phone'] ?? '—'}',
                        ),
                        isThreeLine: true,
                        trailing: Text(
                          '${((r['amount_iqd'] as num?) ?? 0).round()} د',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: r['settle_status'] == 'disputed'
                                ? theme.colorScheme.error
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
