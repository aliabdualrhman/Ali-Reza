import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';

/// تعديل بيانات مستخدم — **يخدم الراكب والسائق معاً**.
///
/// كلاهما صفّ في `profiles`، والحقول المعروضة هنا مشتركة بينهما. أما
/// بيانات المركبة فتعيش في `drivers` ولها بابها: طلبات التعديل (0036)،
/// لأن اللوحة واللون هما ما يتعرّف بهما الراكب على سائقه في الشارع،
/// وتغييرهما بلا مراجعة أخطر من تصحيح اسم.
///
/// **ولماذا نسمح بالتعديل المباشر أصلاً؟** لأن نظام الطلبات يحمي من
/// تغيير المستخدم لهويته بعد اعتماد وثائقه، ولا يحمي من خطأ إملائي
/// أدخله المدير نفسه. من يتصل يقول «اسمي مكتوب خطأ» لا ينبغي أن ينتظر
/// دورة طلب وموافقة على خطأ يراه المدير أمامه.
///
/// يعيد `true` إن حُفظ تعديل، و`null` إن أُلغي.
Future<bool?> showEditProfileDialog(
  BuildContext context, {
  required String userId,
  required String? fullName,
  required String? phone,
  required String? address,
  required String? dateOfBirth,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _EditProfileDialog(
        userId: userId,
        fullName: fullName ?? '',
        phone: phone ?? '',
        address: address ?? '',
        dateOfBirth: DateTime.tryParse('$dateOfBirth'),
      ),
    );

class _EditProfileDialog extends ConsumerStatefulWidget {
  const _EditProfileDialog({
    required this.userId,
    required this.fullName,
    required this.phone,
    required this.address,
    required this.dateOfBirth,
  });

  final String userId;
  final String fullName;
  final String phone;
  final String address;
  final DateTime? dateOfBirth;

  @override
  ConsumerState<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends ConsumerState<_EditProfileDialog> {
  late final _name = TextEditingController(text: widget.fullName);
  late final _phone = TextEditingController(text: widget.phone);
  late final _address = TextEditingController(text: widget.address);
  late DateTime? _dob = widget.dateOfBirth;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  /// ما تغيّر فعلاً — لا ما عُرض.
  ///
  /// **نمرّر المتغيّر وحده.** الدالة في القاعدة تقرأ `null` على أنه «لا
  /// تمسّ هذا الحقل»، فإرسال القيم كلها في كل مرة يجعل سجلّ التدقيق
  /// يقول «عُدّل الهاتف» لمن لم يمسّه، ويُخفي التعديل الحقيقي في ضجيج.
  Future<void> _save() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final address = _address.text.trim();

    final changedName = name != widget.fullName ? name : null;
    final changedPhone = phone != widget.phone ? phone : null;
    final changedAddr = address != widget.address ? address : null;
    final changedDob = _dob != widget.dateOfBirth ? _dob : null;

    if (changedName == null &&
        changedPhone == null &&
        changedAddr == null &&
        changedDob == null) {
      Navigator.pop(context, false);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminRepositoryProvider).updateProfile(
            id: widget.userId,
            fullName: changedName,
            phone: changedPhone,
            address: changedAddr,
            dateOfBirth: changedDob,
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 25),
      firstDate: DateTime(now.year - 100),
      // العمر الأدنى ١٦ — تفرضه القاعدة أيضاً، وهذا يمنع الرحلة إليها.
      lastDate: DateTime(now.year - 16, now.month, now.day),
    );
    if (picked != null) setState(() => _dob = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('تعديل البيانات'),
      content: SizedBox(
        width: Breaks.dialogWidth(context, 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'الاسم الكامل',
                  helperText: 'ثلاثة أحرف على الأقل',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _phone,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'الهاتف',
                  helperText: 'بالصيغة الدولية: ‎+9647XXXXXXXXX',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _address,
                decoration: const InputDecoration(labelText: 'العنوان'),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: _busy ? null : _pickDate,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'تاريخ الميلاد',
                    suffixIcon: Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(
                    _dob == null
                        ? 'غير محدّد'
                        : '${_dob!.year}/${_dob!.month}/${_dob!.day}',
                  ),
                ),
              ),

              // **تحذير دائم لا رسالة عابرة.** التعديل المباشر يتجاوز
              // مراجعة الوثائق، ومن يعدّل اسم سائق معتمَد يجب أن يعرف
              // أن فعله مسجَّل باسمه قبل أن يفعله لا بعده.
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.history_edu,
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'كل تعديل يُسجَّل في سجلّ التدقيق باسمك، وبما كان '
                        'وما صار.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 16),
                SelectableText(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
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
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('حفظ'),
        ),
      ],
    );
  }
}
