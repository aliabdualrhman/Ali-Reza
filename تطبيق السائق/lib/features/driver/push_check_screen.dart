import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';
import '../../core/push_service.dart';

/// **عامٌّ لا خاصّ.** تحتاجه الشاشة الرئيسية أيضاً لورقة الإصلاح،
/// ومزوّدان اثنان لخدمةٍ واحدة يعنيان حالتين قد تختلفان.
final pushServiceProvider = Provider<PushService>(
  (ref) => PushService(ref.watch(supabaseProvider)),
);

final pushDiagnosticsProvider = FutureProvider<PushDiagnostics>(
  (ref) => ref.watch(pushServiceProvider).diagnose(),
);

/// فحص الإشعارات — يقول أين انقطعت السلسلة بدل أن يتركنا نخمّن.
///
/// **لماذا شاشة كاملة لهذا؟** لأن ثلاثة أعطال مختلفة عرضها واحد: "لا يصل
/// إشعار". إذنٌ مرفوض، ورمزٌ لم يُولَّد، ورمزٌ في الجهاز يخالف المخزّن في
/// القاعدة. الثالث أخطرها لأنه يبدو سليماً — القاعدة تحمل رمزاً، وفايربيز
/// ترسل إليه، وهو رمز جهازٍ لم يعد موجوداً فترد `NotRegistered`.
class PushCheckScreen extends ConsumerWidget {
  const PushCheckScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final diag = ref.watch(pushDiagnosticsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('فحص الإشعارات'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'إعادة الفحص',
            onPressed: () => ref.invalidate(pushDiagnosticsProvider),
          ),
        ],
      ),
      body: diag.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppError.message(e))),
        data: (d) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: d.healthy
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  Icon(d.healthy ? Icons.check_circle : Icons.error_outline,
                      size: 44),
                  const SizedBox(height: 10),
                  Text(
                    d.healthy
                        ? 'جهازك جاهز لاستقبال الطلبات'
                        : 'لن تصلك الطلبات على هذا الجهاز',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  if (!d.healthy) ...[
                    const SizedBox(height: 8),
                    Text(_advice(d),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 20),
            _BatteryRow(unrestricted: d.batteryUnrestricted),
            _Row(
              label: 'مسجّل الدخول',
              ok: d.signedIn,
              detail: d.signedIn ? 'نعم' : 'لا — سجّل دخولك أولاً',
            ),
            _Row(
              label: 'إذن الإشعارات',
              ok: d.permissionGranted == true,
              detail: d.permissionGranted == true
                  ? 'ممنوح'
                  : 'مرفوض — فعّله من إعدادات الهاتف',
            ),
            _Row(
              label: 'رمز هذا الجهاز',
              ok: d.deviceToken != null,
              detail: d.deviceToken == null
                  ? 'لم يُولَّد'
                  : '${d.deviceToken!.substring(0, 18)}…',
            ),
            _Row(
              label: 'الرمز المخزّن في الخادم',
              ok: d.storedToken != null,
              detail: d.storedToken == null
                  ? 'فارغ'
                  : '${d.storedToken!.substring(0, 18)}…',
            ),
            _Row(
              label: 'تطابق الرمزين',
              ok: d.tokenMatches,
              detail: d.tokenMatches
                  ? 'متطابقان'
                  : 'مختلفان — الخادم يرسل إلى جهاز قديم',
            ),

            if (d.error != null) ...[
              const SizedBox(height: 16),
              Text(d.error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],

            const SizedBox(height: 28),

            // **زر لا إرشاد.** أندرويد لا يعيد سؤال المستخدم بعد رفضه
            // الإذن، والطريق الوحيد بعدها هو صفحة إعدادات التطبيق —
            // وشرحُ مسارها بالكلمات يضيع خطوةً أو خطوتين عند أكثر الناس.
            if (d.permissionGranted != true) ...[
              FilledButton.icon(
                onPressed: () => openAppSettings(),
                icon: const Icon(Icons.settings),
                label: const Text('فتح إعدادات الإشعارات'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
              ),
              const SizedBox(height: 10),
              Text(
                'فعّل "الإشعارات" ثم ارجع واضغط زر التحديث أعلى الشاشة.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
            ],

            FilledButton.icon(
              onPressed: () async {
                try {
                  await ref.read(pushServiceProvider).resync();
                  ref.invalidate(pushDiagnosticsProvider);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('أُعيدت مزامنة الرمز')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppError.message(e))),
                    );
                  }
                }
              },
              icon: const Icon(Icons.sync),
              label: const Text('إعادة مزامنة الرمز'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: d.deviceToken == null
                  ? null
                  : () async {
                      await Clipboard.setData(
                          ClipboardData(text: d.deviceToken!));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('نُسخ رمز الجهاز')),
                        );
                      }
                    },
              icon: const Icon(Icons.copy),
              label: const Text('نسخ رمز الجهاز'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
            ),
          ],
        ),
      ),
    );
  }
}

/// أول عطل في السلسلة هو ما يُعرض: إصلاح الأخير قبل الأول لا يفيد.
String _advice(PushDiagnostics d) {
  // **التجميد أولاً وإن جاء صفُّه بعد غيره.** بقية الأعطال تُنتج صمتاً
  // مفهوماً؛ أما هذا فيُنتج تطبيقاً يبدو شغّالاً ولا يعمل — زر يدور بلا
  // نهاية، وموقع يتوقف فيستبعدك الخادم وأنت تحسب نفسك متصلاً.
  if (d.batteryUnrestricted == false) {
    return 'نظام هاتفك يوقف التطبيق في الخلفية. اضغط الزر أدناه واختر '
        '«بلا قيود» — بدونها لن تصلك طلبات، وقد يتوقف التطبيق في منتصف رحلة.';
  }
  if (!d.signedIn) return 'سجّل دخولك ثم أعد الفحص.';
  if (d.permissionGranted != true) {
    return 'الإذن مرفوض. افتح إعدادات الهاتف ← التطبيقات ← زنبور السائق '
        '← الإشعارات، وفعّلها.';
  }
  if (d.deviceToken == null) {
    return 'لم يُولَّد رمز للجهاز. تحقق من اتصال الإنترنت وأعد الفحص.';
  }
  if (d.storedToken == null) {
    return 'الرمز لم يصل الخادم. اضغط "إعادة مزامنة الرمز".';
  }
  if (!d.tokenMatches) {
    return 'الخادم يحمل رمز جهازٍ قديم، فيرسل الإشعارات إلى العدم. '
        'اضغط "إعادة مزامنة الرمز".';
  }
  return '';
}

/// صف تحسين البطارية — بزرّ يفتح شاشة الاستثناء مباشرة.
///
/// **زرٌّ لا تعليمات.** «افتح الإعدادات ثم التطبيقات ثم البطارية» سلسلة
/// تختلف خطواتها بين شاومي وأوبو وسامسونغ، ويضلّ فيها من يعرف هاتفه.
/// وأندرويد يتيح فتح الشاشة مباشرةً، فنفتحها.
class _BatteryRow extends StatelessWidget {
  const _BatteryRow({required this.unrestricted});

  final bool? unrestricted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bad = unrestricted == false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(
          label: 'العمل في الخلفية',
          ok: !bad,
          detail: switch (unrestricted) {
            true => 'مسموح — التطبيق لن يتوقف',
            false => 'مقيّد — النظام يوقف التطبيق فلا تصلك طلبات',
            null => 'تعذّر الفحص على هذا الجهاز',
          },
        ),
        if (bad)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FilledButton.icon(
              icon: const Icon(Icons.battery_alert),
              label: const Text('السماح بالعمل في الخلفية'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: () =>
                  Permission.ignoreBatteryOptimizations.request(),
            ),
          ),
      ],
    );
  }
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
      leading: Icon(ok ? Icons.check_circle : Icons.cancel,
          color: ok ? theme.colorScheme.primary : theme.colorScheme.error),
      title: Text(label),
      subtitle: Text(detail,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}
