import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';

/// حذف حساب راكب أو سائق.
///
/// **الحذف نوعان تقرّرهما القاعدة لا هذه الشاشة:** حسابٌ لم يركب قطّ
/// يُمحى كلياً، وحسابٌ له رحلات يُجهَّل ويبقى سجلّه المالي. ولهذا لا
/// نعد المدير بشيء قبل الفعل — نخبره بما حدث بعده.
///
/// **والاسم يُكتب لا يُضغط زر.** الحذف لا رجعة فيه، وزر «تأكيد» وحده
/// يُضغط سهواً في نهاية يوم طويل. كتابةُ الاسم تُجبر على النظر إلى من
/// تحذف.
///
/// يعيد `true` إن حُذف الحساب.
Future<bool?> showDeleteAccountDialog(
  BuildContext context, {
  required String userId,
  required String fullName,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _DeleteAccountDialog(userId: userId, fullName: fullName),
    );

class _DeleteAccountDialog extends ConsumerStatefulWidget {
  const _DeleteAccountDialog({required this.userId, required this.fullName});

  final String userId;
  final String fullName;

  @override
  ConsumerState<_DeleteAccountDialog> createState() =>
      _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<_DeleteAccountDialog> {
  final _confirm = TextEditingController();
  final _reason = TextEditingController();

  bool _busy = false;
  String? _error;

  bool get _matches => _confirm.text.trim() == widget.fullName.trim();

  @override
  void initState() {
    super.initState();
    _confirm.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _confirm.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(adminRepositoryProvider)
          .deleteAccount(widget.userId, reason: _reason.text.trim());

      if (!mounted) return;
      Navigator.pop(context, true);

      final purged = result == 'purged';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(purged
            ? 'مُحي الحساب كلياً — لم تكن له رحلات'
            : 'جُهّل الحساب — بقي سجلّ رحلاته للمحاسبة'),
        duration: const Duration(seconds: 5),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded,
          color: AdminTheme.danger, size: 32),
      title: const Text('حذف الحساب'),
      content: SizedBox(
        width: Breaks.dialogWidth(context, 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ستُحذف بيانات «${widget.fullName}» ووثائقه وصوره نهائياً، '
                'ولن يستطيع الدخول بحسابه بعدها.',
                style: theme.textTheme.bodyLarge,
              ),

              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ما يحدث بحسب حالته:',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Text(
                      '• بلا رحلات ← محوٌ كامل، لا يبقى منه شيء.\n'
                      '• له رحلات ← تُمحى هويته ويبقى سجلّ رحلاته '
                      'ومبالغها للمحاسبة.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(
                  labelText: 'سبب الحذف',
                  hintText: 'حساب تجريبي، إساءة، طلب صاحبه…',
                ),
              ),

              const SizedBox(height: 20),
              Text('اكتب اسم صاحب الحساب للتأكيد:',
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              TextField(
                controller: _confirm,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: widget.fullName,
                  errorText: _confirm.text.isNotEmpty && !_matches
                      ? 'الاسم غير مطابق'
                      : null,
                  suffixIcon: _matches
                      ? Icon(Icons.check_circle, color: AdminTheme.success)
                      : null,
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 16),
                SelectableText(_error!,
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: (_busy || !_matches) ? null : _delete,
          style: FilledButton.styleFrom(backgroundColor: AdminTheme.danger),
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('احذف نهائياً'),
        ),
      ],
    );
  }
}
