import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/perms.dart';
import '../trips/trips_page.dart' show fmtDateTime;

final incentivesProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(adminRepositoryProvider).incentives(),
);

/// ترتيب السائقين خلال آخر (n) يوماً — مفتاحُ العائلة هو عدد الأيام.
final leaderboardProvider =
    FutureProvider.family<List<Map<String, dynamic>>, int>(
  (ref, days) => ref.watch(adminRepositoryProvider).driverLeaderboard(
        from: DateTime.now().subtract(Duration(days: days)),
      ),
);

/// الحوافز: هدفٌ ومكافأة، يصوغهما المدير كاملَين.
///
/// **لا مستويات دائمة ولا فئات.** طلبها علي هكذا: «أكمل ٢٠ فتأخذ ٣٠٠٠،
/// وأكمل ٣٠ فتأخذ ١٠٠٠٠، خلال من–إلى». فكل حافزٍ مدّةٌ ومستوياتٌ داخلها،
/// والصرف تلقائيّ بلا تدخّل (0107).
class IncentivesPage extends ConsumerWidget {
  const IncentivesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final list = ref.watch(incentivesProvider);
    final canManage = can(ref, 'incentives.manage');

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'الحوافز والعروض',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'تحديث',
                onPressed: () => ref.invalidate(incentivesProvider),
              ),
              if (canManage)
                FilledButton.icon(
                  onPressed: () => _editDialog(context, ref, null),
                  icon: const Icon(Icons.add),
                  label: const Text('حافز جديد'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: list.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  ErrorView(e, onRetry: () => ref.invalidate(incentivesProvider)),
              data: (data) {
                final rows = [
                  for (final r in (data['items'] as List? ?? const []))
                    Map<String, dynamic>.from(r as Map)
                ];
                final maxActive = (data['max_active'] as num?)?.toInt() ?? 1;
                if (rows.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'لا توجد حوافز بعد. أنشئ حافزاً: هدفٌ خلال مدّة، '
                        'ومكافأةٌ تُصرف تلقائياً.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: rows.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => i == 0
                      // **السقف فوق القائمة.** هو قرارٌ واحدٌ يحكم الصفحة
                      // كلها: كم حافزاً يجمع السائق معاً.
                      ? Card(
                          child: ListTile(
                            leading: const Icon(Icons.layers_outlined),
                            title: const Text(
                                'كم حافزاً يفعّل السائق في وقتٍ واحد؟'),
                            subtitle: const Text(
                                'الحافز لا يُحتسب للسائق حتى يفعّله من تطبيقه'),
                            trailing: DropdownButton<int>(
                              value: maxActive,
                              items: [
                                for (var n = 1; n <= 5; n++)
                                  DropdownMenuItem(
                                      value: n, child: Text('$n'))
                              ],
                              onChanged: !canManage
                                  ? null
                                  : (v) async {
                                      if (v == null) return;
                                      await ref
                                          .read(adminRepositoryProvider)
                                          .setIncentivesMax(v);
                                      ref.invalidate(incentivesProvider);
                                    },
                            ),
                          ),
                        )
                      : _Card(
                          row: rows[i - 1],
                          canManage: canManage,
                          theme: theme,
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

class _Card extends ConsumerWidget {
  const _Card({required this.row, required this.canManage, required this.theme});

  final Map<String, dynamic> row;
  final bool canManage;
  final ThemeData theme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiers = (row['tiers'] as List?) ?? const [];
    final active = row['is_active'] == true;
    final ends = DateTime.parse('${row['ends_at']}');
    final over = ends.isBefore(DateTime.now());
    final paid = (row['awards_total'] as num?)?.round() ?? 0;
    final count = (row['awards_count'] as num?)?.toInt() ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${row['title']}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(row['reward_kind'] == 'real'
                      ? 'رصيد يُسحب'
                      : 'رصيد هدية'),
                ),
                const SizedBox(width: 8),
                if (over)
                  const Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text('انتهى'))
                else
                  // **المفتاح يوقف الحافز ولا يحذفه.** ما صُرف منه لا يُسترجع،
                  // وحذفُه يمحو أثر صرفه من السجلّ.
                  Switch(
                    value: active,
                    onChanged: !canManage
                        ? null
                        : (v) async {
                            await ref
                                .read(adminRepositoryProvider)
                                .setIncentiveActive(row['id'] as String, v);
                            ref.invalidate(incentivesProvider);
                          },
                  ),
              ],
            ),
            if ('${row['description'] ?? ''}'.isNotEmpty)
              Text('${row['description']}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text(
              'من ${fmtDateTime(row['starts_at'])} '
              'إلى ${fmtDateTime(row['ends_at'])}',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 22),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (final t in tiers)
                  Chip(
                    avatar: const Icon(Icons.flag_outlined, size: 16),
                    label: Text(_tierLabel(Map<String, dynamic>.from(t as Map))),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              count == 0
                  ? 'فعّله ${(row['optins'] as num?)?.toInt() ?? 0} سائقاً · لم يُصرف بعد'
                  : 'فعّله ${(row['optins'] as num?)?.toInt() ?? 0} سائقاً · '
                      'صُرف $count مرة — $paid دينار',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: count == 0
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                  fontWeight: count == 0 ? null : FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              (row['targets'] as num?)?.toInt() == 0 || row['targets'] == null
                  ? 'موجَّه إلى: كل السائقين'
                  : 'موجَّه إلى ${(row['targets'] as num).toInt()} سائقاً بأعيانهم',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (canManage) ...[
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (count == 0)
                      TextButton.icon(
                        onPressed: () => _editDialog(context, ref, row),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('تعديل'),
                      ),
                    TextButton.icon(
                      onPressed: () => _targetsDialog(context, ref, row),
                      icon: const Icon(Icons.group_add_outlined, size: 18),
                      label: const Text('إرسال إلى سائقين'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _tierLabel(Map<String, dynamic> t) {
    final trips = (t['trips_required'] as num?)?.toInt() ?? 0;
    final hours = (t['hours_required'] as num?)?.toDouble() ?? 0;
    final reward = (t['reward_iqd'] as num?)?.round() ?? 0;
    final parts = <String>[
      if (trips > 0) '$trips رحلة',
      if (hours > 0) '${hours.toStringAsFixed(hours % 1 == 0 ? 0 : 1)} ساعة',
    ];
    return '${parts.join(' + ')} ← $reward دينار';
  }
}

// =============================================================================
/// إنشاء حافزٍ أو تعديله. المصروف منه لا يُعدَّل — القاعدة ترفض (0107).
Future<void> _editDialog(
    BuildContext context, WidgetRef ref, Map<String, dynamic>? row) async {
  final title = TextEditingController(text: '${row?['title'] ?? ''}');
  final desc = TextEditingController(text: '${row?['description'] ?? ''}');

  var from = row == null
      ? DateTime.now()
      : DateTime.parse('${row['starts_at']}').toLocal();
  var to = row == null
      ? DateTime.now().add(const Duration(days: 7))
      : DateTime.parse('${row['ends_at']}').toLocal();
  var rewardKind = '${row?['reward_kind'] ?? 'bonus'}';

  final vehicles = <String>{
    ...((row?['vehicle_kinds'] as List?) ?? const []).map((e) => '$e'),
  };

  // المستويات: (رحلات، ساعات، مكافأة)
  final tiers = <List<TextEditingController>>[];
  for (final t in ((row?['tiers'] as List?) ?? const [])) {
    final m = Map<String, dynamic>.from(t as Map);
    tiers.add([
      TextEditingController(text: '${(m['trips_required'] as num?)?.toInt() ?? 0}'),
      TextEditingController(
          text: '${(m['hours_required'] as num?)?.toDouble() ?? 0}'),
      TextEditingController(text: '${(m['reward_iqd'] as num?)?.round() ?? 0}'),
    ]);
  }
  if (tiers.isEmpty) {
    tiers.add([
      TextEditingController(text: '20'),
      TextEditingController(text: '0'),
      TextEditingController(text: '3000'),
    ]);
  }

  var busy = false;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Future<void> pick(bool isFrom) async {
          final base = isFrom ? from : to;
          final d = await showDatePicker(
            context: ctx,
            initialDate: base,
            firstDate: DateTime.now().subtract(const Duration(days: 30)),
            lastDate: DateTime.now().add(const Duration(days: 365)),
          );
          if (d == null || !ctx.mounted) return;
          final t = await showTimePicker(
            context: ctx,
            initialTime: TimeOfDay.fromDateTime(base),
          );
          if (t == null) return;
          final picked =
              DateTime(d.year, d.month, d.day, t.hour, t.minute);
          setLocal(() => isFrom ? from = picked : to = picked);
        }

        return AlertDialog(
          title: Text(row == null ? 'حافز جديد' : 'تعديل الحافز'),
          content: SizedBox(
            width: Breaks.dialogWidth(ctx, 520),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: title,
                    decoration: const InputDecoration(
                      labelText: 'عنوان الحافز',
                      hintText: 'مثال: حافز نهاية الأسبوع',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: desc,
                    decoration: const InputDecoration(
                      labelText: 'شرحٌ للسائق (اختياري)',
                    ),
                  ),
                  const SizedBox(height: 16),

                  Text('المدّة',
                      style: Theme.of(ctx)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => pick(true),
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: Text(_stamp(from)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => pick(false),
                          icon: const Icon(Icons.stop, size: 18),
                          label: Text(_stamp(to)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // ساعةٌ أو أسبوع — المدّة حرّة كما طلب علي.
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (label, dur) in const [
                        ('ساعة', Duration(hours: 1)),
                        ('٦ ساعات', Duration(hours: 6)),
                        ('اليوم', Duration(days: 1)),
                        ('أسبوع', Duration(days: 7)),
                        ('شهر', Duration(days: 30)),
                      ])
                        ActionChip(
                          label: Text(label),
                          onPressed: () =>
                              setLocal(() => to = from.add(dur)),
                        ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  Text('المكافأة',
                      style: Theme.of(ctx)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'bonus',
                          icon: Icon(Icons.card_giftcard),
                          label: Text('رصيد هدية')),
                      ButtonSegment(
                          value: 'real',
                          icon: Icon(Icons.payments_outlined),
                          label: Text('رصيد يُسحب')),
                    ],
                    selected: {rewardKind},
                    onSelectionChanged: (v) =>
                        setLocal(() => rewardKind = v.first),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    rewardKind == 'bonus'
                        ? 'تُخصم منه عمولة السائق أولاً، ولا يُسحب نقداً.'
                        : 'يدخل محفظته ويستطيع سحبه إلى زين كاش.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),

                  const SizedBox(height: 16),
                  Text('المركبات (فارغ = الكل)',
                      style: Theme.of(ctx)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (code, label) in const [
                        ('bike', 'دراجة'),
                        ('tuktuk', 'تكتك'),
                        ('stoota', 'ستوتة'),
                      ])
                        FilterChip(
                          label: Text(label),
                          selected: vehicles.contains(code),
                          onSelected: (v) => setLocal(() =>
                              v ? vehicles.add(code) : vehicles.remove(code)),
                        ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text('المستويات',
                            style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold)),
                      ),
                      TextButton.icon(
                        onPressed: () => setLocal(() => tiers.add([
                              TextEditingController(text: '0'),
                              TextEditingController(text: '0'),
                              TextEditingController(text: '0'),
                            ])),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('مستوى'),
                      ),
                    ],
                  ),
                  Text(
                    'الرحلات والساعات **معاً** شرطان يجب تحقّقهما. '
                    'اكتب صفراً لما لا تشترطه.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < tiers.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: tiers[i][0],
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration:
                                  const InputDecoration(labelText: 'رحلات'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: tiers[i][1],
                              keyboardType: TextInputType.number,
                              decoration:
                                  const InputDecoration(labelText: 'ساعات'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: tiers[i][2],
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration: const InputDecoration(
                                  labelText: 'المكافأة', suffixText: 'دينار'),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: tiers.length == 1
                                ? null
                                : () => setLocal(() => tiers.removeAt(i)),
                          ),
                        ],
                      ),
                    ),

                  if (error != null) ...[
                    const SizedBox(height: 10),
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
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await ref.read(adminRepositoryProvider).saveIncentive({
                          if (row != null) 'id': row['id'],
                          'title': title.text.trim(),
                          'description': desc.text.trim(),
                          'starts_at': from.toUtc().toIso8601String(),
                          'ends_at': to.toUtc().toIso8601String(),
                          'reward_kind': rewardKind,
                          'vehicle_kinds': vehicles.toList(),
                          'tiers': [
                            for (final t in tiers)
                              {
                                'trips_required':
                                    int.tryParse(t[0].text.trim()) ?? 0,
                                'hours_required':
                                    double.tryParse(t[1].text.trim()) ?? 0,
                                'reward_iqd':
                                    int.tryParse(t[2].text.trim()) ?? 0,
                              }
                          ],
                        });
                        ref.invalidate(incentivesProvider);
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setLocal(() {
                          error = '$e';
                          busy = false;
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2))
                  : const Text('حفظ'),
            ),
          ],
        );
      },
    ),
  );

  title.dispose();
  desc.dispose();
  for (final t in tiers) {
    for (final c in t) {
      c.dispose();
    }
  }
}

String _stamp(DateTime d) =>
    '${d.year}/${d.month}/${d.day} — '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

// =============================================================================
/// لوحة ترتيب السائقين — ومنها يُوجَّه الحافز.
///
/// **الترتيب بمدّةٍ تختارها.** «الأكثر عملاً» في أسبوعٍ غيره في شهر، ومن
/// غاب شهراً يتصدّر قائمة السنة. والقائمة تُقرأ من طرفيها: أعلى السائقين
/// يعملون أصلاً، والحافز الذي يغيّر سلوكاً هو ما يذهب إلى من قلّ عمله.
Future<void> _targetsDialog(
    BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
  final picked = <String>{};
  var days = 30;
  var busy = false;
  String? error;
  String? note;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final board = ref.watch(leaderboardProvider(days));
        final list = board.value ?? const <Map<String, dynamic>>[];

        void take(int n, {bool fromBottom = false}) {
          final src = fromBottom ? list.reversed.toList() : list;
          setLocal(() {
            picked
              ..clear()
              ..addAll(src.take(n).map((d) => '${d['driver_id']}'));
          });
        }

        return AlertDialog(
          title: Text('إرسال «${row['title']}» إلى سائقين'),
          content: SizedBox(
            width: Breaks.dialogWidth(ctx, 620),
            height: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text('المدّة:'),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: days,
                      items: const [
                        DropdownMenuItem(value: 7, child: Text('آخر أسبوع')),
                        DropdownMenuItem(value: 30, child: Text('آخر شهر')),
                        DropdownMenuItem(value: 90, child: Text('آخر ٣ أشهر')),
                        DropdownMenuItem(value: 365, child: Text('آخر سنة')),
                      ],
                      onChanged: (v) => setLocal(() => days = v ?? 30),
                    ),
                    const Spacer(),
                    Text('${picked.length} مُختاراً'),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ActionChip(
                        label: const Text('أعلى ١٠'),
                        onPressed: () => take(10)),
                    ActionChip(
                        label: const Text('أعلى ١٠٠'),
                        onPressed: () => take(100)),
                    ActionChip(
                        label: const Text('أدنى ١٠٠'),
                        onPressed: () => take(100, fromBottom: true)),
                    ActionChip(
                        label: const Text('الكل'),
                        onPressed: () => take(list.length)),
                    ActionChip(
                        label: const Text('مسح'),
                        onPressed: () => setLocal(picked.clear)),
                  ],
                ),
                const Divider(height: 20),
                Expanded(
                  child: board.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('$e')),
                    data: (rows) => rows.isEmpty
                        ? const Center(child: Text('لا سائقين في هذه المدّة'))
                        : ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (_, i) {
                              final d = rows[i];
                              final id = '${d['driver_id']}';
                              final trips =
                                  (d['trips'] as num?)?.toInt() ?? 0;
                              final hours =
                                  (d['hours'] as num?)?.toDouble() ?? 0;
                              return CheckboxListTile(
                                dense: true,
                                value: picked.contains(id),
                                onChanged: (v) => setLocal(() => v == true
                                    ? picked.add(id)
                                    : picked.remove(id)),
                                secondary: CircleAvatar(
                                  radius: 14,
                                  child: Text('${i + 1}',
                                      style: const TextStyle(fontSize: 11)),
                                ),
                                title: Text('${d['full_name']}'),
                                subtitle: Text([
                                  '$trips طلباً',
                                  '${hours.toStringAsFixed(1)} ساعة',
                                  switch (d['vehicle_kind']) {
                                    'tuktuk' => 'تكتك',
                                    'stoota' => 'ستوتة',
                                    _ => 'دراجة',
                                  },
                                  if (d['is_blocked'] == true) 'موقوف',
                                  if (d['approved'] != true) 'غير معتمد',
                                ].join('  ·  ')),
                              );
                            },
                          ),
                  ),
                ),
                if (note != null)
                  Text(note!, style: TextStyle(color: Colors.green.shade700)),
                if (error != null)
                  Text(error!,
                      style:
                          TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('إغلاق'),
            ),
            // **«للجميع» فعلٌ صريح.** إفراغ القائمة بالخطأ يجب ألا يصير
            // توجيهاً إلى لا أحد، فجعلناه زرّاً مستقلاً.
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () async {
                      await ref
                          .read(adminRepositoryProvider)
                          .setIncentiveTargets('${row['id']}', const []);
                      ref.invalidate(incentivesProvider);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
              child: const Text('اجعله لكل السائقين'),
            ),
            FilledButton(
              onPressed: busy || picked.isEmpty
                  ? null
                  : () async {
                      setLocal(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final n = await ref
                            .read(adminRepositoryProvider)
                            .setIncentiveTargets(
                                '${row['id']}', picked.toList());
                        ref.invalidate(incentivesProvider);
                        setLocal(() {
                          busy = false;
                          note = 'أُرسل إلى $n سائقاً جديداً';
                        });
                      } catch (e) {
                        setLocal(() {
                          error = '$e';
                          busy = false;
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2))
                  : Text('أرسل إلى ${picked.length}'),
            ),
          ],
        );
      },
    ),
  );
}
