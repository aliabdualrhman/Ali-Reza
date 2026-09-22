import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// تنبيهُ أن الإشعارات لن تصل — بطاقةٌ عائمة لا شريطٌ يحجب.
///
/// **الشريط الملتصق بأعلى الشاشة كان يغطّي شريط التطبيق نفسه**، فيبدو
/// عطلاً في الواجهة لا تنبيهاً مقصوداً — ويُغري بتجاهله لأنه يشبه خطأً
/// عابراً. والبطاقة المرتفعة بحوافّ مستديرة تُقرأ إعلاناً مقصوداً.
///
/// **ولا تُغلق ولا تُخفى.** سائقٌ لا تصله الطلبات لا يعمل أصلاً، وراكبٌ
/// لا يعرف أن سائقه وصل يقف في الشارع. فالتنبيه يبقى حتى يُصلَح سببه.
class PushAlertCard extends StatelessWidget {
  const PushAlertCard({
    super.key,
    required this.notificationsOk,
    required this.onFix,
    this.backgroundOk,
    this.message,
  });

  final bool notificationsOk;

  /// `null` = لا يعني هذا التطبيق. الراكب لا يحتاج عملاً في الخلفية:
  /// إشعاراته تصل عبر فايربيز حتى وهو مغلق.
  final bool? backgroundOk;

  final VoidCallback onFix;
  final String? message;

  bool get _broken => !notificationsOk || backgroundOk == false;

  @override
  Widget build(BuildContext context) {
    if (!_broken) return const SizedBox.shrink();

    final theme = Theme.of(context);
    const red = Color(0xFFC62828);

    final text = message ??
        (backgroundOk == false && notificationsOk
            ? 'نظام هاتفك يوقف التطبيق في الخلفية — لن تصلك الطلبات.'
            : 'الإشعارات معطّلة — لن يصلك شيء والشاشة مطفأة.');

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: red,
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onFix,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: Colors.white24,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.priority_high,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'مهمّ — إعداداتٌ ناقصة',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        text,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // **زرٌّ ظاهر لا سهمٌ صغير.** البطاقة كلها تُضغط، لكنّ
                // كثيراً من الناس لا يعرف أن البطاقات تُضغط.
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'إصلاح',
                    style: TextStyle(
                        color: red, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
/// خطوةٌ واحدة في ورقة الإصلاح.
class PushStep {
  const PushStep({
    required this.title,
    required this.detail,
    required this.done,
    required this.action,
    required this.onTap,
  });

  final String title;
  final String detail;
  final bool done;
  final String action;
  final Future<void> Function() onTap;
}

/// ورقة الإصلاح — خطواتٌ مرقّمة لا مصطلحات.
///
/// **«إعادة مزامنة الرمز» جملةٌ لا يفهمها أحد.** وأكثر سائقينا لا يعرف
/// ما «الرمز» ولا ما «المزامنة»، فيترك الزرّ ولا يضغطه — والعطل الذي
/// يُصلحه هو أشيعها: رمزٌ في الجهاز يخالف المخزّن في الخادم، فتُرسل
/// الطلبات إلى جهازٍ لم يعد موجوداً.
///
/// فصارت خطواتٍ مرقّمة، كلٌّ منها فعلٌ واحدٌ بلغةٍ عادية، وأمامها علامة
/// إن تمّت.
Future<void> showPushSetupSheet(
  BuildContext context, {
  required String title,
  required List<PushStep> steps,
  String? diagnostic,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) =>
        _SetupSheet(title: title, steps: steps, diagnostic: diagnostic),
  );
}

class _SetupSheet extends StatefulWidget {
  const _SetupSheet({
    required this.title,
    required this.steps,
    this.diagnostic,
  });

  final String title;
  final List<PushStep> steps;

  /// سبب العطل بنصّه كما ردّه النظام — يُعرض مطويّاً أسفل الخطوات.
  ///
  /// **حُذف مع الشاشة التقنية، وكان ذلك خطأً.** الخطوات وحدها تقول
  /// «لم يتمّ» ولا تقول **لماذا**، و`SERVICE_NOT_AVAILABLE` يعني خدمات
  /// Google لا تطبيقنا — فمن لا يقرأه يبحث في المكان الخطأ يوماً كاملاً.
  /// فبقي مطويّاً: لا يزحم المستخدم العادي، ويُفتح حين نسأل عنه.
  final String? diagnostic;

  @override
  State<_SetupSheet> createState() => _SetupSheetState();
}

class _SetupSheetState extends State<_SetupSheet> {
  int? _busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // **`ListTile` لا صفٌّ مبنيّ باليد.** النسخة الأولى كانت `Row` فيه
    // `Expanded`، فظهرت الورقة صندوقاً فارغاً على الجهاز: خطأُ تخطيطٍ
    // في نسخة الإصدار يُرسم مساحةً رمادية صامتة لا رسالةَ خطأ.
    // و`ListTile` يحسب قيوده بنفسه فلا يقع فيه ذلك.
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'اتبع الخطوات بالترتيب.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            for (var i = 0; i < widget.steps.length; i++)
              _tile(theme, i, widget.steps[i]),

            if (widget.diagnostic != null) ...[
              const SizedBox(height: 4),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'تفاصيل تقنية',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  children: [
                    SelectableText(
                      widget.diagnostic!,
                      textDirection: TextDirection.ltr,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(ThemeData theme, int i, PushStep step) {
    final done = step.done;
    final busy = _busy == i;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: done
          ? Colors.green.withValues(alpha: 0.10)
          : theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: done ? Colors.green.shade600 : Colors.transparent,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: CircleAvatar(
          radius: 15,
          backgroundColor:
              done ? Colors.green.shade600 : theme.colorScheme.primary,
          child: done
              ? const Icon(Icons.check, size: 18, color: Colors.white)
              : Text('${i + 1}',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        title: Text(step.title,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(step.detail, style: theme.textTheme.bodyMedium),
        ),
        isThreeLine: false,
        // **`minimumSize` يُبطَل هنا صراحةً.** سمة التطبيق تفرض
        // `Size.fromHeight(54)` على كل `FilledButton` — وهي تعني
        // **عرضاً لا نهائياً**، لا ارتفاعاً وحده. فالزرّ داخل `trailing`
        // يبتلع العرض كلّه ويبقى للنصّ حرفٌ واحد في كل سطر.
        trailing: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : FilledButton(
                onPressed: () async {
                  setState(() => _busy = i);
                  try {
                    await step.onTap();
                  } finally {
                    if (mounted) setState(() => _busy = null);
                  }
                },
                style: FilledButton.styleFrom(
                  minimumSize: const Size(72, 40),
                  maximumSize: const Size(110, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 14),
                  backgroundColor:
                      done ? theme.colorScheme.surfaceContainerHighest : null,
                  foregroundColor: done ? theme.colorScheme.outline : null,
                ),
                child: Text(step.action),
              ),
      ),
    );
  }
}

// =============================================================================
/// يطلب إذن الإشعارات **بنافذة النظام** إن أمكن.
///
/// **ولماذا لا نفتح الإعدادات مباشرةً؟** لأن نافذة النظام ضغطةٌ واحدة،
/// وصفحةُ الإعدادات رحلةٌ يضيع فيها أكثر الناس. لكنّ أندرويد لا يعرضها
/// إلا مرة: بعد الرفض الدائم لا تظهر مهما طلبنا — وعندها الإعدادات هي
/// الطريق الوحيد.
///
/// يعيد `true` إن صار الإذن ممنوحاً.
Future<bool> requestNotificationPermission() async {
  var status = await Permission.notification.status;
  if (status.isGranted) return true;

  if (!status.isPermanentlyDenied) {
    status = await Permission.notification.request();
    if (status.isGranted) return true;
  }

  await openAppSettings();
  return false;
}
