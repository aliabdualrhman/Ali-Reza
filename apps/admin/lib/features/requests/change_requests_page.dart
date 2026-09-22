import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../trips/trips_page.dart' show fmtDateTime;
import '../../core/perms.dart';

/// أسماء الحقول بالعربية — نفس ما يراه المستخدم في تطبيقه.
const _labels = <String, String>{
  'full_name': 'الاسم الثلاثي',
  'phone': 'رقم الهاتف',
  'date_of_birth': 'تاريخ الميلاد',
  'address': 'العنوان',
  'vehicle_type': 'نوع المركبة',
  'vehicle_plate': 'رقم اللوحة',
  'vehicle_color': 'لون المركبة',
};

final changeRequestsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, status) => ref.watch(adminRepositoryProvider).changeRequests(status),
);

/// طلبات تعديل بيانات المستخدمين.
///
/// **القديم بجانب الجديد لا الجديد وحده.** المراجعة سؤال مقارنة: هل هذا
/// تصحيحُ خطأ إملائي أم تبديلُ شخص بآخر؟ عرض القيمة الجديدة منفردة يخفي
/// الفرق بين الحالتين تماماً.
class ChangeRequestsPage extends ConsumerStatefulWidget {
  const ChangeRequestsPage({super.key});

  @override
  ConsumerState<ChangeRequestsPage> createState() => _State();
}

class _State extends ConsumerState<ChangeRequestsPage> {
  String _status = 'pending';

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(changeRequestsProvider(_status));

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'طلبات تعديل البيانات',
            subtitle: 'ما يطلبه الركّاب والسائقون تغييره في بياناتهم',
            actions: [
              FilterChoice<String>(
                value: _status,
                options: const [
                  ('pending', 'قيد المراجعة'),
                  ('approved', 'موافَق عليها'),
                  ('rejected', 'مرفوضة'),
                ],
                onChanged: (v) => setState(() => _status = v),
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.refresh),
                tooltip: 'تحديث',
                onPressed: () =>
                    ref.invalidate(changeRequestsProvider(_status)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: rows.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(e,
                  onRetry: () =>
                      ref.invalidate(changeRequestsProvider(_status))),
              data: (list) {
                if (list.isEmpty) {
                  return Center(
                    child: Text(switch (_status) {
                      'pending' => 'لا توجد طلبات تنتظر المراجعة',
                      'approved' => 'لم يُوافَق على أي طلب بعد',
                      _ => 'لم يُرفض أي طلب',
                    }),
                  );
                }
                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _RequestCard(
                    row: list[i],
                    onDone: () =>
                        ref.invalidate(changeRequestsProvider(_status)),
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

class _RequestCard extends ConsumerStatefulWidget {
  const _RequestCard({required this.row, required this.onDone});
  final Map<String, dynamic> row;
  final VoidCallback onDone;

  @override
  ConsumerState<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends ConsumerState<_RequestCard> {
  bool _busy = false;
  String? _error;

  Future<void> _review(bool approve) async {
    // نلتقط المُبلِّغ قبل أي انتظار: نافذة السبب فجوة غير متزامنة،
    // والسياق بعدها قد لا يكون حياً.
    final messenger = ScaffoldMessenger.of(context);

    String? note;
    if (!approve) {
      note = await _askNote();
      if (note == null) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminRepositoryProvider).reviewChangeRequest(
            id: widget.row['id'] as String,
            approve: approve,
            note: note,
          );
      widget.onDone();
      messenger.showSnackBar(SnackBar(
          content: Text(approve ? 'طُبّق التعديل' : 'رُفض الطلب')));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  Future<String?> _askNote() async {
    final ctrl = TextEditingController();
    const presets = [
      'البيانات الجديدة لا تطابق وثائقك',
      'رقم الهاتف مستعمل في حساب آخر',
      'راجعنا الطلب ولم نجد سبباً للتغيير',
    ];
    final out = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('سبب الرفض'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('يصل السبب إلى المستخدم في تطبيقه.',
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 10),
                ...presets.map((x) => ListTile(
                      dense: true,
                      title: Text(x),
                      onTap: () => Navigator.pop(ctx, x),
                    )),
                const Divider(),
                TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(labelText: 'سبب آخر'),
                  onSubmitted: (v) => Navigator.pop(ctx, v),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('رفض'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.row;
    final p = r['profile'] as Map<String, dynamic>?;
    final changes = (r['changes'] as Map?) ?? const {};
    final previous = (r['previous'] as Map?) ?? const {};
    final status = '${r['status']}';
    final pending = status == 'pending';
    final compact = Breaks.isCompact(context);

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(p?['role'] == 'driver'
                    ? Icons.two_wheeler
                    : Icons.person_outline),
                Text('${p?['full_name'] ?? '—'}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                Text('${p?['phone'] ?? ''}',
                    textDirection: TextDirection.ltr,
                    style: theme.textTheme.bodySmall),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(switch (status) {
                    'approved' => 'موافَق عليه',
                    'rejected' => 'مرفوض',
                    _ => 'قيد المراجعة',
                  }),
                ),
                Text(fmtDateTime(r['created_at']),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),

            const SizedBox(height: 14),

            // القديم ← الجديد، حقلاً حقلاً
            for (final e in changes.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: compact ? null : 120,
                      child: Text('${_labels[e.key] ?? e.key}:',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    Text('${previous[e.key] ?? '—'}',
                        style: TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                    const Icon(Icons.arrow_back, size: 16),
                    SelectableText('${e.value}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),

            if ('${r['note'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('سببه: ${r['note']}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontStyle: FontStyle.italic)),
            ],

            if (!pending && '${r['review_note'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('ردّ الإدارة: ${r['review_note']}',
                  style: theme.textTheme.bodySmall),
            ],

            if (_error != null) ...[
              const SizedBox(height: 10),
              SelectableText(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],

            if (pending) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (can(ref, 'profiles.review'))
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _review(true),
                    icon: const Icon(Icons.check),
                    label: const Text('موافقة وتطبيق'),
                  ),
                  if (can(ref, 'profiles.review'))
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _review(false),
                    icon: const Icon(Icons.close),
                    label: const Text('رفض'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error),
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
