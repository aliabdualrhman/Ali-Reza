import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';

/// حوافز السائق: هدفٌ ومكافأة، والعدّاد يتقدّم وحده.
///
/// **تُقيَّم عند الفتح لا عند العرض فقط.** `my_incentives` تستدعي التقييم
/// قبل أن تردّ (0107)، فمن بلغ هدفه قبل ثانية يرى المكافأة مصروفة الآن
/// لا بعد رحلةٍ تالية.
final myIncentivesProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final v = await ref.watch(supabaseProvider).rpc('my_incentives');
  return Map<String, dynamic>.from(v as Map);
});

/// يفعّل السائق الحافز أو يُلغيه. القاعدة تفحص السقف وترفض الزائد (0108).
Future<void> _toggle(BuildContext context, WidgetRef ref,
    {required String id, required bool on}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final sb = ref.read(supabaseProvider);
    await sb.rpc(on ? 'deactivate_incentive' : 'activate_incentive',
        params: {'p_id': id});
    ref.invalidate(myIncentivesProvider);
    messenger.showSnackBar(SnackBar(
        content: Text(on ? 'أُلغي الحافز' : 'فُعّل الحافز — بالتوفيق')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(AppError.message(e))));
  }
}

class IncentivesScreen extends ConsumerWidget {
  const IncentivesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final data = ref.watch(myIncentivesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('الحوافز')),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppError.message(e), textAlign: TextAlign.center),
          ),
        ),
        data: (d) {
          final items = (d['items'] as List?) ?? const [];
          final earned = (d['earned_total'] as num?) ?? 0;
          final maxActive = (d['max_active'] as num?)?.toInt() ?? 1;
          final activeCount = (d['active_count'] as num?)?.toInt() ?? 0;

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myIncentivesProvider),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                if (earned > 0)
                  Card(
                    color: theme.colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(
                        children: [
                          Icon(Icons.emoji_events,
                              color: theme.colorScheme.primary, size: 30),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${earned.round()} دينار',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.bold)),
                                Text('مجموع ما ربحته من الحوافز',
                                    style: theme.textTheme.bodySmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),

                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 60),
                    child: Column(
                      children: [
                        Icon(Icons.card_giftcard_outlined,
                            size: 64, color: theme.colorScheme.outline),
                        const SizedBox(height: 14),
                        Text('لا توجد حوافز جارية الآن',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          'حين تُطلق الإدارة حافزاً يظهر هنا، ويُحتسب لك '
                          'تلقائياً بلا تسجيل.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),

                if (items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'فعّلتَ $activeCount من $maxActive — '
                      'الحافز لا يُحتسب لك حتى تفعّله.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),

                for (final it in items)
                  _IncentiveCard(
                    data: Map<String, dynamic>.from(it as Map),
                    canActivate: activeCount < maxActive,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IncentiveCard extends ConsumerWidget {
  const _IncentiveCard({required this.data, required this.canActivate});

  final Map<String, dynamic> data;

  /// هل بقي للسائق مكانٌ ضمن سقف المفعَّلة؟
  final bool canActivate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tiers = (data['tiers'] as List?) ?? const [];
    final trips = (data['trips'] as num?)?.toInt() ?? 0;
    final hours = (data['hours'] as num?)?.toDouble() ?? 0;
    final ends = DateTime.parse('${data['ends_at']}').toLocal();
    final real = data['reward_kind'] == 'real';
    final on = data['activated'] == true;

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${data['title']}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Chip(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  label: Text(real ? 'رصيد يُسحب' : 'رصيد هدية',
                      style: theme.textTheme.bodySmall),
                ),
              ],
            ),
            if ('${data['description'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('${data['description']}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 10),

            // **الوقت المتبقّي أولاً.** الهدف بلا مهلةٍ ظاهرة لا يُستعجل.
            Row(
              children: [
                Icon(Icons.schedule,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(_remaining(ends),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
            const Divider(height: 22),

            // عدّادك الآن
            Row(
              children: [
                _Counter(
                    icon: Icons.route, label: 'رحلاتك', value: '$trips'),
                const SizedBox(width: 20),
                _Counter(
                    icon: Icons.timer_outlined,
                    label: 'ساعات اتصالك',
                    value: hours.toStringAsFixed(1)),
              ],
            ),
            const SizedBox(height: 14),

            for (final t in tiers)
              _Tier(
                tier: Map<String, dynamic>.from(t as Map),
                trips: trips,
                hours: hours,
              ),

            const SizedBox(height: 4),
            // **زرّ التفعيل آخرَ البطاقة.** يقرأ الشروط أولاً ثم يقرّر —
            // وعدّاده يبدأ من لحظة ضغطه لا من بداية الحافز.
            SizedBox(
              width: double.infinity,
              child: on
                  ? OutlinedButton.icon(
                      onPressed: () =>
                          _toggle(context, ref, id: '${data['id']}', on: true),
                      icon: const Icon(Icons.check_circle, size: 18),
                      label: const Text('مُفعَّل — اضغط للإلغاء'),
                    )
                  : FilledButton.icon(
                      onPressed: !canActivate
                          ? null
                          : () => _toggle(context, ref,
                              id: '${data['id']}', on: false),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(canActivate
                          ? 'فعّل الحافز'
                          : 'ألغِ حافزاً آخر لتفعّله'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _remaining(DateTime ends) {
    final left = ends.difference(DateTime.now());
    if (left.isNegative) return 'انتهى';
    if (left.inHours < 24) {
      final h = left.inHours;
      final m = left.inMinutes % 60;
      return h > 0 ? 'يتبقّى $h ساعة و$m دقيقة' : 'يتبقّى $m دقيقة';
    }
    return 'ينتهي ${DateFormat('d MMM — HH:mm', 'ar').format(ends)}';
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text(value,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// مستوى واحد: شريط تقدّم ومبلغ.
///
/// **التقدّم يُقاس بأبعد الشرطين.** حافزٌ يشترط ٢٠ رحلة و٥ ساعات لا يكتمل
/// بإحداهما، فالشريط يعرض الأقلّ نسبةً — وهو ما ينقص فعلاً.
class _Tier extends StatelessWidget {
  const _Tier({required this.tier, required this.trips, required this.hours});

  final Map<String, dynamic> tier;
  final int trips;
  final double hours;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needTrips = (tier['trips_required'] as num?)?.toInt() ?? 0;
    final needHours = (tier['hours_required'] as num?)?.toDouble() ?? 0;
    final reward = (tier['reward_iqd'] as num?)?.round() ?? 0;
    final earned = tier['earned'] == true;

    final ratios = <double>[
      if (needTrips > 0) (trips / needTrips).clamp(0.0, 1.0),
      if (needHours > 0) (hours / needHours).clamp(0.0, 1.0),
    ];
    final progress = earned
        ? 1.0
        : ratios.isEmpty
            ? 0.0
            : ratios.reduce((a, b) => a < b ? a : b);

    final parts = <String>[
      if (needTrips > 0) '$needTrips رحلة',
      if (needHours > 0) '${needHours.toStringAsFixed(needHours % 1 == 0 ? 0 : 1)} ساعة',
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                earned ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18,
                color: earned ? Colors.green.shade600 : theme.colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(parts.join(' + '),
                    style: theme.textTheme.bodyMedium),
              ),
              Text('$reward دينار',
                  style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: earned
                          ? Colors.green.shade700
                          : theme.colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                  earned ? Colors.green.shade600 : theme.colorScheme.primary),
            ),
          ),
          if (earned) ...[
            const SizedBox(height: 4),
            Text('صُرفت',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.green.shade700)),
          ],
        ],
      ),
    );
  }
}
