import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/theme.dart';

/// تقييمات شخصٍ واحد، ومعها الأكثر اختياراً.
///
/// **المتوسّط وحده لا يُصلح شيئاً.** سائقٌ هبط إلى ٢.٨: لماذا؟ التعليقات
/// مكتوبةٌ في القاعدة منذ اليوم الأول، ولم يكن لها مكانٌ يُقرأ فيه — فلا
/// المدير يعرف فيُصلح، ولا السائق يعرف فيتغيّر.
///
/// **والأكثر اختياراً ثلاثةٌ لا قائمة.** عددٌ صغير يُقرأ بنظرة؛ وقائمةٌ
/// بعشرين سطراً تُتجاهَل كلها.
class RatingsSection extends ConsumerWidget {
  const RatingsSection({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repo = ref.watch(adminRepositoryProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('التقييمات',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),

        FutureBuilder<List<Map<String, dynamic>>>(
          future: repo.ratingTagSummary(userId),
          builder: (_, snap) {
            final tags = snap.data ?? const [];
            if (tags.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in tags) _TagChip(t),
                ],
              ),
            );
          },
        ),

        FutureBuilder<List<Map<String, dynamic>>>(
          future: repo.userRatings(userId),
          builder: (_, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return Text('${snap.error}',
                  style: TextStyle(color: theme.colorScheme.error));
            }
            final rows = snap.data ?? const [];
            if (rows.isEmpty) {
              return Text('لا تقييمات بعد',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant));
            }
            return Column(
              children: [for (final r in rows) _RatingRow(r)],
            );
          },
        ),
      ],
    );
  }
}

/// تقييما رحلةٍ واحدة، متقابلين.
class TripRatingsSection extends ConsumerWidget {
  const TripRatingsSection({super.key, required this.tripId});

  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: ref.watch(adminRepositoryProvider).tripRatings(tripId),
      builder: (_, snap) {
        final rows = snap.data ?? const [];
        if (rows.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Text('التقييم المتبادل',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            for (final r in rows)
              _RatingRow(r, header: '${r['rater_name']} ← ${r['ratee_name']}'),
          ],
        );
      },
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip(this.tag);
  final Map<String, dynamic> tag;

  @override
  Widget build(BuildContext context) {
    final bad = tag['sentiment'] == 'negative';
    final color = bad ? AdminTheme.danger : AdminTheme.success;

    return Chip(
      label: Text('${tag['label']} · ${tag['uses']}'),
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
      labelStyle: TextStyle(color: color, fontWeight: FontWeight.w600),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow(this.r, {this.header});
  final Map<String, dynamic> r;
  final String? header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stars = (r['stars'] as num?)?.toInt() ?? 0;
    final labels = List<String>.from((r['labels'] as List?) ?? const []);
    final amount = r['amount'] as num?;
    final comment = '${r['comment'] ?? ''}'.trim();

    // **الشكوى تُلوَّن.** صفٌّ رماديّ بين عشرين صفاً لا يُرى، وشكوى مالٍ
    // لا تُرى لا تُعالَج.
    final bad = stars <= 3;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: bad ? AdminTheme.danger.withValues(alpha: 0.06) : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var i = 1; i <= 5; i++)
                  Icon(i <= stars ? Icons.star : Icons.star_border,
                      size: 16,
                      color: bad ? AdminTheme.danger : AdminTheme.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    header ??
                        [
                          if (r['rater_name'] != null) '${r['rater_name']}',
                          if (r['trip_number'] != null)
                            'الرحلة ${r['trip_number']}',
                        ].join(' · '),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                Text(_when(r['created_at']),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),

            if (labels.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final l in labels)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(l, style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ],

            // **المبلغ بارزٌ لا مدفون.** هو ما يُقارَن بما سجّله الطرف
            // الآخر، وهو وحده ما يُحسم به الخلاف.
            if (amount != null) ...[
              const SizedBox(height: 8),
              Text('المبلغ المُدّعى: ${amount.round()} دينار',
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: AdminTheme.danger,
                      fontWeight: FontWeight.bold)),
            ],

            if (comment.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(comment, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}

String _when(Object? raw) {
  final d = DateTime.tryParse('$raw')?.toLocal();
  if (d == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
