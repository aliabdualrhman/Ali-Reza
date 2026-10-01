import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zanbour_core/zanbour_core.dart';

/// الحوافز التي استلمها السائق — `my_incentive_awards` (0134).
final incentiveAwardsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await Supabase.instance.client
      .rpc('my_incentive_awards', params: {'p_limit': 50}) as List;
  return rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
});

/// «الحوافز المستلمة» — في «رحلاتي» وفي شاشة الرصيد.
///
/// **لماذا قائمةٌ صريحة؟** أكمل علي حافزاً ولم يعرف إن استلمه: حافز الهدية
/// يذهب إلى رصيد الهدية لا إلى المحفظة، فلا يظهر في كشفها. هنا كلّ مكافأة
/// باسم حافزها ومبلغها ونوعها وتاريخها. ويختفي القسم إن لم يستلم شيئاً.
class IncentiveAwardsSection extends ConsumerWidget {
  const IncentiveAwardsSection({super.key, this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(incentiveAwardsProvider).value ?? const [];
    if (rows.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final z = context.z;
    final total =
        rows.fold<num>(0, (a, r) => a + ((r['amount_iqd'] as num?) ?? 0));

    return Card(
      margin: margin ?? const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const ZIconTile(Icons.emoji_events),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('الحوافز المستلمة',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Text('${total.round()} دينار',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: z.ok)),
              ],
            ),
            const SizedBox(height: 8),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, size: 18, color: z.ok),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${r['title'] ?? 'حافز'}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          Text(
                            '${r['reward_kind'] == 'real' ? 'رصيد يُسحب' : 'رصيد هدية'}'
                            ' · ${_date(r['awarded_at'])}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Text('+${((r['amount_iqd'] as num?) ?? 0).round()}',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, color: z.ok)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _date(Object? raw) {
    final d = DateTime.tryParse('$raw')?.toLocal();
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}/${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
  }
}
