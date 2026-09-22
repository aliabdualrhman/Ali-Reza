import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';

final myRatingsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(driverRepositoryProvider).myRatings(),
);

/// تقييمي — ما قاله الركّاب، بلا أسماء.
///
/// **من قيّم يبقى مجهولاً أبداً.** الدالة في القاعدة لا تعيد `rater_id`
/// إطلاقاً: سائق يعرف من أعطاه نجمة واحدة قد ينتقم، وراكب يخشى ذلك
/// يعطي خمساً دائماً — فيصير التقييم بلا معنى ويضيع علينا نحن أيضاً.
class MyRatingsScreen extends ConsumerWidget {
  const MyRatingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final driver = ref.watch(driverRecordProvider).value;
    final ratings = ref.watch(myRatingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('تقييمي')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myRatingsProvider),
        child: ListView(
          children: [
            // ---- الملخّص ----
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 28),
              color: theme.colorScheme.primaryContainer,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Icon(Icons.star, color: Colors.amber, size: 40),
                      const SizedBox(width: 10),
                      Text(
                        (driver?.ratingAvg ?? 5.0).toStringAsFixed(2),
                        style: theme.textTheme.displaySmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('من ${driver?.ratingCount ?? 0} تقييم',
                      style: theme.textTheme.titleMedium),
                ],
              ),
            ),

            // ---- توزيع النجوم ----
            ratings.maybeWhen(
              data: (rows) {
                if (rows.isEmpty) return const SizedBox.shrink();
                final counts = List<int>.filled(6, 0);
                for (final r in rows) {
                  final s = (r['stars'] as num?)?.toInt() ?? 0;
                  if (s >= 1 && s <= 5) counts[s]++;
                }
                final max = counts.reduce((a, b) => a > b ? a : b);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Column(
                    children: [
                      for (var s = 5; s >= 1; s--)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              SizedBox(
                                  width: 18,
                                  child: Text('$s',
                                      textAlign: TextAlign.center)),
                              const Icon(Icons.star,
                                  size: 14, color: Colors.amber),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: max == 0 ? 0 : counts[s] / max,
                                    minHeight: 8,
                                    backgroundColor:
                                        theme.colorScheme.surfaceContainerHighest,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                  width: 26,
                                  child: Text('${counts[s]}',
                                      textAlign: TextAlign.end)),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),

            const Divider(height: 32),

            // ---- التعليقات ----
            ratings.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text(AppError.message(e))),
              ),
              data: (rows) {
                final withComment = rows
                    .where((r) => '${r['comment'] ?? ''}'.trim().isNotEmpty)
                    .toList();
                if (withComment.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('لا توجد ملاحظات مكتوبة')),
                  );
                }
                return Column(
                  children: [
                    for (final r in withComment)
                      ListTile(
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star,
                                size: 18, color: Colors.amber),
                            const SizedBox(width: 4),
                            Text('${r['stars']}'),
                          ],
                        ),
                        title: Text('${r['comment']}'),
                        subtitle: Text(_date(r['created_at']),
                            style: theme.textTheme.bodySmall),
                      ),
                  ],
                );
              },
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
  return '${d.year}/${d.month}/${d.day}';
}
