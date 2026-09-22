import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/theme.dart';

/// من أين يأتي مستخدمونا — وكم منهم بقي.
///
/// **الرقم وحده يضلّل.** مئة مستخدم من إعلانٍ لم يركب منهم أحد أسوأ من
/// عشرةٍ من صديق ركبوا كلهم: الأولى كلفةٌ بلا عائد، والثانية قناةٌ
/// تستحق أن تُغذّى. فنعرض **نسبة التفعيل** لا التسجيلات وحدها.
class AcquisitionPage extends ConsumerWidget {
  const AcquisitionPage({super.key});

  static const _labels = <String, String>{
    'friend': 'دعوة صديق',
    'ad': 'إعلان',
    'street': 'ترويج في الشارع',
    'other': 'مصدر آخر',
    'unknown': 'لم يُسأل',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final report = ref.watch(acquisitionReportProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('قنوات الوصول'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(acquisitionReportProvider),
          ),
        ],
      ),
      body: report.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText('تعذّر التحميل: $e'),
          ),
        ),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Text('لا بيانات بعد',
                  style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            );
          }

          final total = rows.fold<int>(
              0, (a, r) => a + ((r['signups'] as num?)?.toInt() ?? 0));

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('من أين سمع مستخدمونا عنّا؟',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                'السؤال يُطرح عند التسجيل. ومن سجّل قبل إضافته يظهر '
                '«لم يُسأل».',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),

              for (final r in rows)
                _Row(
                  label: _labels[r['source']] ?? '${r['source']}',
                  signups: (r['signups'] as num?)?.toInt() ?? 0,
                  activated: (r['activated'] as num?)?.toInt() ?? 0,
                  pct: (r['activation_pct'] as num?)?.toDouble() ?? 0,
                  share: total == 0
                      ? 0
                      : ((r['signups'] as num?)?.toInt() ?? 0) / total,
                ),

              const SizedBox(height: 28),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('كيف تقرأ هذا؟',
                          style: theme.textTheme.titleSmall),
                      const SizedBox(height: 10),
                      Text(
                        'نسبة التفعيل = من أكمل رحلةً واحدة على الأقل من '
                        'كل مئة سجّلوا عبر تلك القناة.\n\n'
                        'قناةٌ بنسبة عالية تستحق أن تُغذّى ولو كان عددها '
                        'قليلاً؛ وقناةٌ بنسبة منخفضة تجلب أرقاماً لا '
                        'زبائن.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.signups,
    required this.activated,
    required this.pct,
    required this.share,
  });

  final String label;
  final int signups;
  final int activated;
  final double pct;
  final double share;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // **لونٌ يقول ما يقوله الرقم.** المدير يمسح الصفحة بعينه، والألوان
    // تُختصر عليه المقارنة قبل أن يقرأ رقماً واحداً.
    final color = pct >= 50
        ? AdminTheme.success
        : pct >= 20
            ? AdminTheme.warning
            : theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label, style: theme.textTheme.titleMedium),
                ),
                Text('$signups تسجيلاً',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: share,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 16, color: color),
                const SizedBox(width: 6),
                Text(
                  '$activated ركبوا فعلاً  ·  ${pct.toStringAsFixed(0)}٪',
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
