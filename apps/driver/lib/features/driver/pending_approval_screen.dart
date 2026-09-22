import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';
import 'driver_repository.dart';

/// شاشة انتظار اعتماد الحساب.
///
/// السائق يصلها بعد رفع وثائقه ويبقى فيها حتى يعتمده المدير. **لا تحتاج
/// تحديثاً يدوياً:** `driverRecordProvider` يستمع لصف السائق لحظياً، فحين
/// تتبدّل حالة الاعتماد ينقله الموجّه تلقائياً وهو ينظر إلى الشاشة.
class PendingApprovalScreen extends ConsumerWidget {
  const PendingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final driverAsync = ref.watch(driverRecordProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('حسابك'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'خروج',
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
      body: driverAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppError.message(e))),
        data: (d) {
          final rejected = d?.verification == VerificationStatus.rejected;
          final suspended = d?.verification == VerificationStatus.suspended;

          // **«قيد المراجعة» كذبةٌ قبل رفع الوثائق.** لا شيء يُراجَع،
          // ولا أحد ينتظر السائق — بل هو الذي ينتظر بلا أن يعرف أن
          // الدور عليه. فيقعد يوماً يظنّ أن المدير متأخّر.
          //
          // فنعدّ الناقص أولاً: ما دام هناك مطلوبٌ لم يُرفع فالرسالة
          // «أكمل وثائقك» لا «انتظر».
          final docs = ref.watch(myDocumentsProvider).value;
          final missing = docs == null
              ? 0
              : DriverDocument.values.where((t) => t.required).where((t) {
                  final row = docs.cast<Map<String, dynamic>?>().firstWhere(
                        (r) => r?['doc_type'] == t.code,
                        orElse: () => null,
                      );
                  return row == null || row['status'] == 'rejected';
                }).length;

          final needsDocs = !rejected && !suspended && missing > 0;

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 32),
                  Icon(
                    rejected || suspended
                        ? Icons.cancel_outlined
                        : needsDocs
                            ? Icons.cloud_upload_outlined
                            : Icons.hourglass_top,
                    size: 88,
                    color: rejected || suspended
                        ? ZanbourTheme.danger
                        : ZanbourTheme.warning,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    rejected
                        ? 'لم يُعتمد حسابك'
                        : suspended
                            ? 'حسابك موقوف'
                            : needsDocs
                                ? 'بقيت وثائقك'
                                : 'حسابك قيد المراجعة',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    rejected
                        ? (d?.rejectionReason ??
                            'راجع وثائقك وأعد رفع المرفوض منها.')
                        : suspended
                            ? 'تواصل مع الإدارة لمعرفة السبب.'
                            : needsDocs
                                ? 'بقي $missing من الوثائق المطلوبة. '
                                    'ارفعها ليبدأ المدير بمراجعة حسابك.'
                                : 'يراجع المدير وثائقك. ستتبدّل هذه الشاشة '
                                    'تلقائياً فور اعتمادك.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 36),
                  FilledButton.icon(
                    onPressed: () => context.push('/documents'),
                    icon: Icon(
                        needsDocs ? Icons.upload_file : Icons.folder_open),
                    label: Text(rejected
                        ? 'أعد رفع الوثائق'
                        : needsDocs
                            ? 'ارفع وثائقك الآن'
                            : 'وثائقي'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
