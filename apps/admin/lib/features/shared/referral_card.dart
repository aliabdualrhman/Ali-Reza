import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/theme.dart';
import '../trips/trips_page.dart' show fmtDateTime;

/// بطاقة الدعوة في ملف السائق أو الراكب.
///
/// **تجيب عن ثلاثة أسئلة تُطرح فعلاً:**
///
///   ١) من أين جاءنا هذا المستخدم؟ — قناةٌ تُقاس لا تُخمَّن.
///   ٢) كم دعوةً كسب؟ — لتعرف من يستحقّ الشكر ومن بلغ سقفه.
///   ٣) **من دعاه هو؟** — وهذا أهمّها عند الشكّ: سلسلةُ حساباتٍ يدعو
///      بعضها بعضاً أوضحُ إشارةٍ على الاحتيال، ولا تُرى إلا هنا.
class ReferralCard extends ConsumerWidget {
  const ReferralCard({super.key, required this.userId});

  final String userId;

  static const _sources = <String, String>{
    'friend': 'صديق دعاه',
    'ad': 'إعلان',
    'street': 'الشارع',
    'other': 'مصدر آخر',
    'unknown': 'لم يُسأل',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final info = ref.watch(referralInfoProvider(userId));

    return info.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      // **لا نُخفي الخطأ ولا نُضخّمه.** بطاقةٌ إضافية تعطّلت لا تستحق
      // أن تحجب بقية الملف.
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SelectableText('تعذّر قراءة بيانات الدعوة: $e',
              style: theme.textTheme.bodySmall),
        ),
      ),
      data: (d) {
        final source = d['heard_from'] as String?;
        final note = d['heard_from_note'] as String?;
        final code = d['referral_code'] as String?;
        final total = (d['invited_total'] as num?)?.toInt() ?? 0;
        final rewarded = (d['invited_rewarded'] as num?)?.toInt() ?? 0;
        final pending = (d['invited_pending'] as num?)?.toInt() ?? 0;
        final earned = (d['earned_iqd'] as num?)?.round() ?? 0;
        final by = d['invited_by'] as Map?;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('الدعوة والتسويق', style: theme.textTheme.titleMedium),
                const SizedBox(height: 16),

                Wrap(
                  spacing: 40,
                  runSpacing: 16,
                  children: [
                    _Field(
                      'من أين سمع عنّا',
                      _sources[source ?? 'unknown'] ?? source ?? '—',
                      caption: note,
                    ),
                    _Field('رمزه', code ?? 'لم يُنشئه', ltr: code != null),
                    _Field('دعوات نجحت', '$rewarded'),
                    _Field('قيد الإكمال', '$pending'),
                    _Field('كسب', '$earned دينار'),
                  ],
                ),

                if (by != null) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 12),
                  Text('دعاه', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.person_outline,
                          size: 18, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SelectableText(
                          '${by['name'] ?? '—'}  ·  ${by['phone'] ?? '—'}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      _StatusChip('${by['status']}'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(fmtDateTime(by['at']),
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],

                // **إنذارٌ لا اتهام.** من دعا اثنين وكسب من كليهما قد
                // يكون بائعاً ماهراً وقد يكون محتالاً — والرقم وحده لا
                // يفرّق. نلفت النظر ونترك الحكم للمدير.
                if (total >= 2 && by != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AdminTheme.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 18, color: AdminTheme.warning),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'هذا الحساب مدعوٌّ وداعٍ في آنٍ. راجع سلسلة '
                            'الدعوات إن شككت.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'rewarded' => ('صُرفت', AdminTheme.success),
      'pending' => ('قيد الإكمال', AdminTheme.warning),
      _ => ('مرفوضة', AdminTheme.danger),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.caption, this.ltr = false});

  final String label;
  final String value;
  final String? caption;
  final bool ltr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        SelectableText(
          value,
          textDirection: ltr ? TextDirection.ltr : null,
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (caption != null && caption!.isNotEmpty)
          Text(caption!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
