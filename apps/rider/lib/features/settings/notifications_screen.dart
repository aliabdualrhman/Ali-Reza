import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/push_service.dart';
import '../auth/auth_repository.dart';

/// شاشة «الإشعارات» في تطبيق الراكب.
///
/// **لماذا شاشة كاملة لا سطر في الإعدادات؟** لأن وصول الإشعار سلسلةٌ من
/// أربع حلقات، وكلٌّ منها تفشل صامتة: إذنٌ مرفوض، ورمزٌ لم يُولَّد،
/// ورمزٌ لم يصل القاعدة، وتطبيقٌ جمّده النظام. أربعة أعطال مختلفة عرضها
/// واحد — «لا يصل إشعار».
///
/// وتمييزها بالسؤال يضيّع ساعات مع مختبِر لا يعرف أين إعدادات هاتفه.
/// هنا يفتح الشاشة ويرسل صورة، فنعرف أيّ حلقة انكسرت.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  RiderPushStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final s = await PushService(ref.read(supabaseProvider)).diagnose();
    if (mounted) {
      setState(() {
        _status = s;
        _busy = false;
      });
    }
  }

  Future<void> _resync() async {
    setState(() => _busy = true);
    await PushService(ref.read(supabaseProvider)).resync();
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _status;

    return Scaffold(
      appBar: AppBar(
        title: const Text('الإشعارات'),
        actions: [
          IconButton(
            tooltip: 'إعادة الفحص',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _check,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ما الذي يصلك؟', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  const _Bullet('قُبل طلبك — حين يقبل سائق رحلتك'),
                  const _Bullet('السائق وصل — حين يبلغ نقطة انطلاقك'),
                  const _Bullet('انتهت رحلتك — لتقييم سائقك'),
                  const _Bullet('أُلغيت الرحلة'),
                  const _Bullet('لا يوجد سائق متاح'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),
          Text('حالة جهازك', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),

          if (s == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else ...[
            _Row(
              label: 'إذن الإشعارات',
              ok: s.permissionGranted == true,
              detail: s.permissionGranted == true
                  ? 'ممنوح'
                  : 'مرفوض — لن يظهر أي إشعار',
            ),
            _Row(
              label: 'رمز الجهاز',
              ok: s.hasToken,
              detail: s.hasToken
                  ? 'وُلّد بنجاح'
                  : 'لم يُولَّد — خدمات Google غير متاحة على هذا الجهاز',
            ),
            _Row(
              label: 'مسجَّل في الخادم',
              ok: s.registered,
              detail: s.registered ? 'نعم' : 'لا',
            ),

            if (s.error != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                s.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],

            const SizedBox(height: 20),

            // **نطمئنه لا نخيفه.** الجهاز الذي لا يولّد رمزاً ليس معطوباً
            // ولا التطبيق: الإشعارات تصله ما دام التطبيق يعمل، عبر
            // الطبقة المحلية. وقول ذلك صراحةً أهون من تركه يظن أن
            // التطبيق لا يعمل عنده.
            if (!s.healthy)
              Card(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 20, color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('ماذا يعني هذا؟',
                                style: theme.textTheme.titleSmall),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        s.permissionGranted != true
                            ? 'اسمح للتطبيق بإرسال الإشعارات من إعدادات '
                                'هاتفك، ثم أعد الفحص.'
                            : 'جهازك لا يستطيع استقبال الإشعارات وهو مغلق — '
                                'خدمات Google غير متاحة عليه.\n\n'
                                'لكنّ إشعارات رحلتك ستصلك ما دام التطبيق '
                                'مفتوحاً أو يعمل في الخلفية. أبقِه مفتوحاً '
                                'أثناء انتظار سائقك.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _resync,
                  icon: const Icon(Icons.sync),
                  label: const Text('إعادة المحاولة'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => openAppSettings(),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('إعدادات الهاتف'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('• '),
            Expanded(
              child:
                  Text(text, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.ok, required this.detail});

  final String label;
  final bool ok;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ok ? Icons.check_circle : Icons.cancel,
        color: ok ? theme.colorScheme.primary : theme.colorScheme.error,
      ),
      title: Text(label),
      subtitle: Text(detail, style: theme.textTheme.bodySmall),
    );
  }
}
