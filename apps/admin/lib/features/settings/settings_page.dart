import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import 'services_card.dart';
import 'verification_card.dart';
import '../../core/perms.dart';

final settingsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(adminRepositoryProvider).settings(),
);

/// الإعدادات العامة — قيم يغيّرها المدير بلا إعادة بناء تطبيق.
///
/// **لا يظهر هنا سرٌّ واحد.** المفاتيح (service_role وغيره) في جدول
/// `app_config` المنفصل الذي لا يقرؤه أحد من التطبيقات. الفصل حماية لا
/// ترتيب: سرٌّ واحد في جدول مقروء يُسقط النظام كله.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(settingsProvider);

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'الإعدادات'),
          const SizedBox(height: 20),
          Expanded(
            child: rows.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(e,
                  onRetry: () => ref.invalidate(settingsProvider)),
              data: (list) => ListView(
                children: [
                  // **البطاقتان قبل القائمة.** الخدمات تُغلق وتُفتح
                  // فيراها كل مستخدمٍ في الحال، ووضعُ التوثيق يقرّر إن
                  // كان مستخدمٌ جديد يدخل أصلاً. وما يُقرأ في بطاقةٍ
                  // يُحذف من القائمة: عرضُه مرتين يُغري بتعديل النصّ
                  // الخام فيُكتب وضعٌ لا يعرفه التطبيق.
                  ServicesCard(settings: list),
                  VerificationModeCard(settings: list),

                  for (final r in list
                      .where((r) => !const {
                            'verification_mode',
                            'otp_enabled',
                            'rides_enabled',
                            'shopping_enabled',
                            'rides_closed_msg',
                            'shopping_closed_msg',
                            'delivery_enabled',
                            'delivery_closed_msg',
                          }.contains(r['key'])))
                    Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        title: Text('${r['label'] ?? r['key']}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: SelectableText('${r['value']}',
                            textDirection: TextDirection.ltr),
                        trailing: FilledButton.tonal(
                          onPressed: !can(ref, 'settings.manage') ? null : () => _edit(context, ref, r),
                          child: const Text('تعديل'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _edit(
    BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
  final ctl = TextEditingController(text: '${row['value']}');
  var busy = false;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text('${row['label'] ?? row['key']}'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctl,
                autofocus: true,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: 'القيمة',
                  helperText: row['key'] == 'topup_whatsapp'
                      ? 'بالصيغة الدولية مع + مثل +9647801711922'
                      : null,
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: !can(ref, 'settings.manage') ? null : busy
                ? null
                : () async {
                    setLocal(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await ref
                          .read(adminRepositoryProvider)
                          .saveSetting('${row['key']}', ctl.text.trim());
                      ref.invalidate(settingsProvider);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      setLocal(() {
                        error = '$e';
                        busy = false;
                      });
                    }
                  },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );
  ctl.dispose();
}
