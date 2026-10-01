import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';

/// رفع وثائق السائق.
///
/// الوثائق الإلزامية تحدّدها **قاعدة البيانات** — الدالة
/// `recompute_verification` تعرف ما يلزم للاعتماد، وتضبط حالة السائق
/// آلياً حين تكتمل. هذه الشاشة تعرض وترفع فقط، ولا تقرر شيئاً.
class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key});

  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  String? _uploading;
  String? _error;

  Future<void> _pickAndUpload(DriverDocument doc) async {
    setState(() {
      _error = null;
      _uploading = doc.code;
    });

    try {
      final picked = await ImagePicker().pickImage(
        // الصورة الحية من الكاميرا حصراً — الاختيار من المعرض يبطل الغرض.
        // أما البطاقة والدراجة فيُسمح بالمعرض: قد يكون صوّرها مسبقاً.
        source: doc == DriverDocument.liveSelfie
            ? ImageSource.camera
            : ImageSource.gallery,
        preferredCameraDevice: CameraDevice.front,
        // ضغط قبل الرفع: صور الهواتف تتجاوز حد الـ٥ ميجا على البكت،
        // والوضوح المطلوب للتحقق أقل بكثير.
        maxWidth: 1600,
        imageQuality: 85,
      );

      if (picked == null) {
        if (mounted) setState(() => _uploading = null);
        return;
      }

      await ref.read(authRepositoryProvider).uploadDocument(
            file: File(picked.path),
            docType: doc.code,
          );

      ref.invalidate(myDocumentsProvider);
      await ref.read(myDocumentsProvider.future);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final docsAsync = ref.watch(myDocumentsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('وثائقك')),
      body: docsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppError.message(e))),
        data: (docs) {
          // نحوّل القائمة إلى خريطة بالنوع للبحث السريع.
          // صور الدراجة متعددة فنعدّها بدل أخذ واحدة.
          final byType = <String, Map<String, dynamic>>{};
          var vehiclePhotos = 0;
          for (final d in docs) {
            final t = d['doc_type'] as String;
            if (t == DriverDocument.vehiclePhoto.code) vehiclePhotos++;
            byType[t] = d;
          }

          final required_ =
              DriverDocument.values.where((d) => d.required).toList();
          final optional =
              DriverDocument.values.where((d) => !d.required).toList();

          final done = required_.where((d) {
            if (d == DriverDocument.vehiclePhoto) return vehiclePhotos > 0;
            return byType.containsKey(d.code);
          }).length;

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            done == required_.length
                                ? Icons.check_circle
                                : Icons.upload_file,
                            color: done == required_.length
                                ? ZanbourTheme.success
                                : theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'أكملت $done من ${required_.length} وثائق مطلوبة',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: done / required_.length,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ],
                  ),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_error!,
                      style: TextStyle(
                          color: theme.colorScheme.onErrorContainer)),
                ),
              ],

              const SizedBox(height: 24),
              Text('مطلوبة',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...required_.map((d) => _DocTile(
                    doc: d,
                    row: byType[d.code],
                    count: d == DriverDocument.vehiclePhoto ? vehiclePhotos : null,
                    busy: _uploading == d.code,
                    onTap: () => _pickAndUpload(d),
                  )),

              const SizedBox(height: 24),
              Text('اختيارية',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                'لا تمنع اعتمادك، لكنها تزيد ثقة الركّاب',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              ...optional.map((d) => _DocTile(
                    doc: d,
                    row: byType[d.code],
                    busy: _uploading == d.code,
                    onTap: () => _pickAndUpload(d),
                  )),

              // **مخرجٌ ظاهر بعد الاكتمال.** صارت هذه الشاشة أول ما يراه
              // السائق بعد التسجيل، لا صفحةً يفتحها من الانتظار — فلا
              // زرَّ رجوعٍ فيها. فمن أتمّ الأربع وقف أمام قائمةٍ كلها
              // «قيد المراجعة» بلا ما يقول له: انتهى دورك.
              if (done == required_.length) ...[
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () => context.go('/pending'),
                  icon: const Icon(Icons.check),
                  label: const Text('أكملت وثائقي'),
                ),
              ],

              const SizedBox(height: 32),
              Text(
                'بعد اكتمال الوثائق يراجعها المدير ويعتمد حسابك. '
                'ستصلك النتيجة داخل التطبيق.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DocTile extends StatelessWidget {
  const _DocTile({
    required this.doc,
    required this.row,
    required this.busy,
    required this.onTap,
    this.count,
  });

  final DriverDocument doc;
  final Map<String, dynamic>? row;
  final int? count;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = row?['status'] as String?;
    final notes = row?['review_notes'] as String?;

    final (icon, color, label) = switch (status) {
      'approved' => (Icons.check_circle, ZanbourTheme.success, 'مقبولة'),
      'rejected' => (Icons.cancel, ZanbourTheme.danger, 'مرفوضة — أعد الرفع'),
      'pending' => (Icons.schedule, ZanbourTheme.warning, 'قيد المراجعة'),
      _ => (Icons.add_circle_outline, theme.colorScheme.outline, 'لم تُرفع'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.4))
            : Icon(icon, color: color),
        title: Text(doc.label),
        subtitle: Text(
          count != null && count! > 0 ? '$label · $count صور' : label,
          style: TextStyle(color: color),
        ),
        trailing: notes != null && notes.isNotEmpty
            ? Tooltip(message: notes, child: const Icon(Icons.info_outline))
            : const Icon(Icons.chevron_left),
        onTap: busy ? null : onTap,
      ),
    );
  }
}
