import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';
import 'dashboard_actions.dart';
import '../../core/perms.dart';

/// لوحة الأرقام — أول ما يراه المدير.
///
/// **ثلاثة أرقامٍ للرصيد لا رقم واحد.** «مُولَّد» ورقةٌ لا مال، و«مُعبَّأ»
/// ما دخل محافظ السائقين فعلاً، و«معلَّق» رموزٌ في أيدي الناس لم تُستعمل
/// بعد — وهي التزامٌ علينا لا رصيدٌ لنا. وخلطها في رقم يُخفي أخطر ما
/// فيها.
///
/// **والعمولة تُقرأ من الرحلة لا تُحسب هنا.** مثبّتة لحظة الإكمال بسعر
/// منطقتها يومها، فلا يتغيّر تاريخ الشهر الماضي كلما عُدّلت نسبة.
final dashboardProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  ref.watch(sessionProvider);
  return ref.watch(adminRepositoryProvider).dashboard();
});

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dashboardProvider);

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'اللوحة',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'تحديث',
                onPressed: () => ref.invalidate(dashboardProvider),
              ),
              // التصدير بصلاحيته، والتصفير للمالك وحده (0100).
              if (can(ref, 'trips.export'))
              OutlinedButton.icon(
                onPressed: () => exportDashboard(context, ref),
                icon: const Icon(Icons.download),
                label: const Text('تنزيل إكسل'),
              ),
              if (isOwner(ref))
              OutlinedButton.icon(
                onPressed: () => resetDashboard(context, ref),
                icon: const Icon(Icons.restart_alt),
                label: const Text('تصفير'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: data.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  ErrorView(e, onRetry: () => ref.invalidate(dashboardProvider)),
              data: (d) => _Body(d, ref),
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.d, this.ref);
  final Map<String, dynamic> d;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codes = (d['codes'] as Map).cast<String, dynamic>();
    final trips = (d['trips'] as Map).cast<String, dynamic>();
    final people = (d['people'] as Map).cast<String, dynamic>();

    return ListView(
      children: [
        _Group('الرصيد', [
          _Stat('وُلّد', _iqd(codes['generated_iqd']),
              note: '${codes['count_total']} رمزاً',
              color: theme.colorScheme.onSurfaceVariant),
          _Stat('عُبّئ', _iqd(codes['redeemed_iqd']),
              note: 'دخل محافظ السائقين', color: AdminTheme.success),
          // **المعلَّق ملوَّن تحذيراً لا خطأً.** ليس عطلاً، لكنه مالٌ
          // نَدين به: كل دينار منه قد يُطلب غداً.
          _Stat('معلَّق', _iqd(codes['outstanding_iqd']),
              note: '${codes['count_unused']} رمزاً لم يُستعمل',
              color: AdminTheme.warning),
        ]),

        _Group('العمولات — حصّتنا من الرحلات', [
          _Stat('اليوم', _iqd(trips['commission_today'])),
          _Stat('هذا الشهر', _iqd(trips['commission_month'])),
          _Stat('الكل', _iqd(trips['commission_total']),
              color: AdminTheme.success),
        ]),

        _Group('أجور الرحلات المكتملة', [
          _Stat('اليوم', _iqd(trips['fare_today'])),
          _Stat('هذا الشهر', _iqd(trips['fare_month'])),
          _Stat('الكل', _iqd(trips['fare_total'])),
        ]),

        _Group('الرحلات', [
          _Stat('اليوم', '${trips['today']}',
              note: '${trips['completed_today']} مكتملة'),
          _Stat('هذا الشهر', '${trips['month']}',
              note: '${trips['completed_month']} مكتملة'),
          _Stat('الكل', '${trips['total']}',
              note: '${trips['completed_total']} مكتملة'),
          // **الملغاة معروضة لا مخفية.** إلغاءٌ كثيرٌ خبرٌ يجب أن يُرى،
          // وإخفاؤه يجعل اللوحة تُطمئن بينما العمل ينهار.
          _Stat('ألغيت هذا الشهر', '${trips['cancelled_month']}',
              note: 'من ${trips['month']}',
              color: (trips['cancelled_month'] as num) > 0
                  ? AdminTheme.warning
                  : null),
        ]),

        _Group('الناس', [
          _Stat('السائقون', '${people['drivers']}',
              note: '${people['drivers_approved']} معتمَد'),
          _Stat('الركّاب', '${people['riders']}'),
          _Stat('حسابات جديدة اليوم', '${people['new_today']}'),
          _Stat('هذا الشهر', '${people['new_month']}'),
        ]),

        // **نقطة الصفر معلنة لا خفيّة.** من يرى «٣ رحلات» ولا يعرف أن
        // اللوحة صُفّرت أمس يظنّ العمل توقّف.
        if (d['epoch'] != null) ...[
          const SizedBox(height: 4),
          Center(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('الأرقام محسوبة منذ ${_stampAr(d['epoch'])}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                if (isOwner(ref))
                  TextButton(
                    onPressed: () => undoReset(context, ref),
                    child: const Text('إلغاء التصفير'),
                  ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 20),
        Center(
          // **الوقت مكتوب.** الرقم بلا وقته لا يُصدَّق: من يرى «اليوم ٣»
          // ولا يعرف متى قُرئ لا يدري أهو قديمٌ أم لحظته.
          child: Text(
            'قُرئت ${_time(d['at'])}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.stats);
  final String title;
  final List<_Stat> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          // **يلتفّ ولا يُقصّ.** اللوحة تُفتح على الهاتف أحياناً، وصفٌّ
          // ثابت بأربع بطاقات يدفع آخرها خارج الشاشة.
          Wrap(spacing: 12, runSpacing: 12, children: stats),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.note, this.color});

  final String label;
  final String value;
  final String? note;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Container(
        width: Breaks.isCompact(context) ? 160 : 210,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            if (note != null) ...[
              const SizedBox(height: 4),
              Text(note!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

/// **فواصل الآلاف.** «165000» تُقرأ خطأً في لمحة، و«165,000» لا.
String _iqd(Object? raw) {
  final n = (raw as num?)?.round() ?? 0;
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${n < 0 ? '-' : ''}$b د.ع';
}

/// تاريخٌ مقروء لنقطة الصفر.
String _stampAr(Object? raw) {
  final t = DateTime.tryParse('$raw')?.toLocal();
  if (t == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

String _time(Object? raw) {
  final t = DateTime.tryParse('$raw')?.toLocal();
  if (t == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}
