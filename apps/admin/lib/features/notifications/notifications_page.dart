import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/theme.dart';
import '../trips/trips_page.dart' show fmtDateTime;
import 'send_notification_dialog.dart';
import '../../core/perms.dart';

/// لوحة الإشعارات — قسمان: السائقون والركّاب.
///
/// **ولماذا قسمان لا قائمة واحدة بفلتر؟** لأن الجمهورين مختلفان في كل
/// شيء: ما يُقال لسائقٍ عن العمولة لا يُقال لراكب، وخطأُ الإرسال إلى
/// الجمهور الخطأ لا يُسترد. والفصل البصري يجعل الخطأ أصعب.
class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(templatesProvider);
    ref.invalidate(sentNotificationsProvider);
    ref.invalidate(schedulesProvider);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الإشعارات'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          onTap: (_) => setState(() {}),
          tabs: const [
            Tab(icon: Icon(Icons.two_wheeler), text: 'السائقون'),
            Tab(icon: Icon(Icons.person_outline), text: 'الركّاب'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _AudienceTab(audience: 'driver'),
          _AudienceTab(audience: 'rider'),
        ],
      ),
    );
  }
}

// =============================================================================
class _AudienceTab extends ConsumerWidget {
  const _AudienceTab({required this.audience});

  final String audience;

  bool _fits(String? a) => a == audience || a == 'both';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final label = audience == 'driver' ? 'السائقين' : 'الركّاب';
    final count = ref.watch(
        audienceCountProvider((audience: audience, approvedOnly: false)));

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // ---- إرسال فوري ----
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.campaign_outlined,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Text('إرسال إلى كل $label',
                        style: theme.textTheme.titleMedium),
                    const Spacer(),
                    count.when(
                      loading: () => const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      error: (_, _) => const SizedBox.shrink(),
                      data: (n) => Text('$n مستقبِلاً',
                          style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: !can(ref, 'notifications.send') ? null : () async {
                        final sent = await showSendNotificationDialog(
                          context,
                          audience: audience,
                        );
                        if (sent == true) {
                          ref.invalidate(sentNotificationsProvider);
                        }
                      },
                      icon: const Icon(Icons.send),
                      label: const Text('اكتب وأرسل الآن'),
                    ),
                    OutlinedButton.icon(
                      onPressed: !can(ref, 'notifications.send') ? null : () async {
                        final saved = await showSaveTemplateDialog(
                          context,
                          audience: audience,
                        );
                        if (saved == true) ref.invalidate(templatesProvider);
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('حفظ رسالة جاهزة'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),
        Text('الرسائل الجاهزة', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'تُكتب مرة وتُرسل مراراً — فلا يتسلّل خطأ إملائي إلى مئات الهواتف.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        _Templates(audience: audience, fits: _fits),

        const SizedBox(height: 28),
        Text('المجدولة', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        _Schedules(fits: _fits),

        const SizedBox(height: 28),
        Text('آخر ما أُرسل', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        _SentList(fits: _fits),
      ],
    );
  }
}

// =============================================================================
class _Templates extends ConsumerWidget {
  const _Templates({required this.audience, required this.fits});

  final String audience;
  final bool Function(String?) fits;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final all = ref.watch(templatesProvider);

    return all.when(
      loading: () => const Center(
          child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator())),
      error: (e, _) => SelectableText('تعذّر التحميل: $e'),
      data: (rows) {
        final list = rows.where((t) => fits(t['audience'] as String?)).toList();
        if (list.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text('لا رسائل محفوظة بعد',
                    style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
          );
        }

        return Column(
          children: [
            for (final t in list)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text('${t['title']}'),
                  subtitle: Text('${t['body']}',
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'أرسلها الآن',
                        icon: const Icon(Icons.send),
                        onPressed: !can(ref, 'notifications.send') ? null : () async {
                          final sent = await showSendNotificationDialog(
                            context,
                            audience: audience,
                            title: '${t['title']}',
                            body: '${t['body']}',
                          );
                          if (sent == true) {
                            ref.invalidate(sentNotificationsProvider);
                          }
                        },
                      ),
                      IconButton(
                        tooltip: 'جدولتها',
                        icon: const Icon(Icons.schedule),
                        onPressed: !can(ref, 'notifications.send') ? null : () async {
                          final saved = await showScheduleDialog(
                            context,
                            templateId: '${t['id']}',
                            audience: audience,
                          );
                          if (saved == true) ref.invalidate(schedulesProvider);
                        },
                      ),
                      IconButton(
                        tooltip: 'حذف',
                        icon: Icon(Icons.remove_circle_outline,
                            color: AdminTheme.danger),
                        onPressed: !can(ref, 'notifications.send') ? null : () async {
                          await ref
                              .read(adminRepositoryProvider)
                              .deleteTemplate('${t['id']}');
                          ref.invalidate(templatesProvider);
                        },
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// =============================================================================
class _Schedules extends ConsumerWidget {
  const _Schedules({required this.fits});

  final bool Function(String?) fits;

  static const _freq = {
    'daily': 'يومياً',
    'weekly': 'أسبوعياً',
    'once': 'مرة واحدة',
  };
  static const _days = [
    'الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء',
    'الخميس', 'الجمعة', 'السبت',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final all = ref.watch(schedulesProvider);

    return all.when(
      loading: () => const SizedBox(height: 60),
      error: (e, _) => SelectableText('تعذّر التحميل: $e'),
      data: (rows) {
        final list = rows.where((s) => fits(s['audience'] as String?)).toList();
        if (list.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'لا رسائل مجدولة. احفظ رسالة جاهزة ثم اضغط ⏰ لجدولتها.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          );
        }

        return Column(
          children: [
            for (final s in list)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: SwitchListTile(
                  value: s['is_active'] == true,
                  onChanged: !can(ref, 'notifications.send') ? null : (v) async {
                    await ref
                        .read(adminRepositoryProvider)
                        .setScheduleActive('${s['id']}', v);
                    ref.invalidate(schedulesProvider);
                  },
                  title: Text('${s['notification_templates']?['title'] ?? '—'}'),
                  subtitle: Text(
                    '${_freq[s['frequency']] ?? s['frequency']}'
                    '${s['weekday'] == null ? '' : ' — ${_days[(s['weekday'] as num).toInt()]}'}'
                    '  ·  الساعة ${s['send_at_hour']}:00'
                    '${s['last_sent_at'] == null ? '' : '  ·  آخر إرسال ${fmtDateTime(s['last_sent_at'])}'}',
                  ),
                  secondary: IconButton(
                    tooltip: 'حذف',
                    icon: Icon(Icons.delete_outline, color: AdminTheme.danger),
                    onPressed: !can(ref, 'notifications.send') ? null : () async {
                      await ref
                          .read(adminRepositoryProvider)
                          .deleteSchedule('${s['id']}');
                      ref.invalidate(schedulesProvider);
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// =============================================================================
class _SentList extends ConsumerWidget {
  const _SentList({required this.fits});

  final bool Function(String?) fits;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final all = ref.watch(sentNotificationsProvider);

    return all.when(
      loading: () => const SizedBox(height: 60),
      error: (e, _) => SelectableText('تعذّر التحميل: $e'),
      data: (rows) {
        // الرسائل الشخصية تظهر في القسمين — لا جمهور لها.
        final list = rows
            .where((n) => n['user_id'] != null || fits(n['audience'] as String?))
            .toList();

        if (list.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text('لم تُرسل إشعارات بعد',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          );
        }

        return Column(
          children: [
            for (final n in list.take(20))
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(n['user_id'] != null
                      ? Icons.person_outline
                      : Icons.campaign_outlined),
                  title: Text('${n['title']}'),
                  subtitle: Text(
                    '${n['body']}\n${fmtDateTime(n['sent_at'])}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  // **وصل كذا من كذا.** الرقم يقول لك حجم من لا تصله
                  // إشعاراتك — وهي معلومة تُغيّر قراراتك لا تجمّل تقريرك.
                  trailing: n['user_id'] != null
                      ? null
                      : _Delivery(
                          delivered: (n['delivered'] as num?)?.toInt() ?? 0,
                          recipients: (n['recipients'] as num?)?.toInt() ?? 0,
                        ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Delivery extends StatelessWidget {
  const _Delivery({required this.delivered, required this.recipients});

  final int delivered;
  final int recipients;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = recipients == 0 ? 0 : (delivered * 100 / recipients).round();
    final color = pct >= 70
        ? AdminTheme.success
        : pct >= 40
            ? AdminTheme.warning
            : AdminTheme.danger;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$delivered / $recipients',
            style: theme.textTheme.titleSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        Text('وصلت', style: theme.textTheme.bodySmall),
      ],
    );
  }
}
