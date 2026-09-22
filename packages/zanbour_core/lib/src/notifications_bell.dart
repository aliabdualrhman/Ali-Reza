import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// إشعارات المستخدم كما تقرؤها القاعدة — لا كما تصل من فايربيز.
///
/// **ولماذا نقرؤها من القاعدة أصلاً؟** لأن الدفع يسقط عن جزءٍ من
/// جمهورنا: أجهزةٌ بلا خدمات Google لا تولّد رمزاً إطلاقاً
/// (`SERVICE_NOT_AVAILABLE`)، ورأيناها على جهاز مختبِرٍ ثم على جهاز
/// المطوّر نفسه.
///
/// فمن يعتمد على الإشعار وحده يخاطب جمهوراً ناقصاً **ولا يعلم أنه
/// ناقص**. والقائمة هنا تصل الجميع ما داموا يفتحون التطبيق.
final myNotificationsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await Supabase.instance.client
      .rpc('my_notifications', params: {'p_limit': 50});
  return (rows as List).cast<Map<String, dynamic>>();
});

/// عدد ما لم يُقرأ — للنقطة الحمراء على الجرس.
final unreadCountProvider = Provider<int>((ref) {
  final list = ref.watch(myNotificationsProvider).value ?? const [];
  return list.where((n) => n['is_read'] != true).length;
});

/// جرس الإشعارات في شريط التطبيق.
class NotificationsBell extends ConsumerWidget {
  const NotificationsBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadCountProvider);

    return IconButton(
      tooltip: 'الإشعارات',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NotificationsListScreen()),
      ),
      icon: Badge(
        // **لا نعرض صفراً.** شارةٌ فارغة تلفت النظر بلا سبب، وتُعلّم
        // المستخدم أن يتجاهل الشارة — فيتجاهلها حين تعني شيئاً.
        isLabelVisible: unread > 0,
        label: Text('$unread'),
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}

/// قائمة الإشعارات.
class NotificationsListScreen extends ConsumerStatefulWidget {
  const NotificationsListScreen({super.key});

  @override
  ConsumerState<NotificationsListScreen> createState() =>
      _NotificationsListScreenState();
}

class _NotificationsListScreenState
    extends ConsumerState<NotificationsListScreen> {
  @override
  void initState() {
    super.initState();
    // **نُعلّمها مقروءةً عند الفتح لا عند الخروج.** من يفتح القائمة رآها،
    // ومن يغلق التطبيق قبل الخروج لا يجوز أن تبقى شارته حمراء إلى الأبد.
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
  }

  Future<void> _markRead() async {
    try {
      await Supabase.instance.client.rpc('mark_notifications_read');
      if (mounted) ref.invalidate(myNotificationsProvider);
    } catch (_) {
      // شبكةٌ منقطعة. تبقى الشارة وتُقرأ في المرة القادمة.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = ref.watch(myNotificationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('الإشعارات'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(myNotificationsProvider),
          ),
        ],
      ),
      body: items.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('تعذّر التحميل.\n$e', textAlign: TextAlign.center),
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.notifications_none,
                        size: 56, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text('لا إشعارات بعد',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      'ستظهر هنا إعلانات زنبور وأخبار حسابك.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myNotificationsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final n = list[i];
                final unread = n['is_read'] != true;

                return Card(
                  // الجديد يُميَّز بلونه لا بنقطةٍ صغيرة تُفوَّت.
                  color: unread
                      ? theme.colorScheme.primaryContainer
                          .withValues(alpha: 0.35)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${n['title']}',
                                style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: unread
                                        ? FontWeight.w700
                                        : FontWeight.w500),
                              ),
                            ),
                            Text(
                              _ago(n['sent_at']),
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text('${n['body']}',
                            style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// **«قبل ساعتين» لا «2026/09/05 20:14».** المستخدم يريد أن يعرف إن
  /// كان الخبر جديداً، لا أن يقرأ تاريخاً ويطرحه في رأسه.
  static String _ago(dynamic raw) {
    final t = DateTime.tryParse('$raw');
    if (t == null) return '';
    final d = DateTime.now().difference(t.toLocal());

    if (d.inMinutes < 1) return 'الآن';
    if (d.inMinutes < 60) return 'قبل ${d.inMinutes} دقيقة';
    if (d.inHours < 24) return 'قبل ${d.inHours} ساعة';
    if (d.inDays < 30) return 'قبل ${d.inDays} يوماً';
    return '${t.year}/${t.month}/${t.day}';
  }
}
