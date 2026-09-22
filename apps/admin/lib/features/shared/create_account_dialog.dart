import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';

/// إنشاء حساب راكب أو سائق من اللوحة — ببريد مؤكَّد وبلا انتظار رمز.
///
/// **حالتان تولّدت منهما:**
///
///   ١) الاختبار المغلق يشترط اثني عشر مختبِراً يستعملون التطبيق فعلاً،
///      وكلٌّ يحتاج حساباً مستقلاً: القيد `trips_one_active_per_rider`
///      يمنع مشاركة حساب — أولهم يطلب رحلة والباقون يُرفضون.
///
///   ٢) وسائق في موقف الدراجات لا يُحسن التسجيل ولا يملك بريداً. يُترك
///      اليوم فيذهب غداً إلى منافس.
///
/// يعيد بيانات الدخول عند النجاح لتُعرض للمدير مرة واحدة.
Future<({String email, String password})?> showCreateAccountDialog(
  BuildContext context, {
  String role = 'rider',
}) =>
    showDialog<({String email, String password})>(
      context: context,
      builder: (_) => _CreateAccountDialog(role: role),
    );

class _CreateAccountDialog extends ConsumerStatefulWidget {
  const _CreateAccountDialog({required this.role});

  final String role;

  @override
  ConsumerState<_CreateAccountDialog> createState() =>
      _CreateAccountDialogState();
}

class _CreateAccountDialogState extends ConsumerState<_CreateAccountDialog> {
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController(text: '+964');
  final _address = TextEditingController();
  late final _password = TextEditingController(text: _randomPassword());

  late String _role = widget.role;
  DateTime? _dob;
  bool _busy = false;
  String? _error;

  /// كلمة مرور مقروءة: أحرف صغيرة وأرقام بلا ما يلتبس (`0/O`, `1/l`).
  ///
  /// **لأن المدير سيمليها على سائق في الشارع** — كلمة مولّدة برموز
  /// معقّدة تُكتب خطأً ثلاث مرات، ثم يظنّ السائق أن الحساب لا يعمل.
  static String _randomPassword() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
  }

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final min = _role == 'driver' ? 18 : 16;
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 25),
      firstDate: DateTime(now.year - 100),
      lastDate: DateTime(now.year - min, now.month, now.day),
    );
    if (picked != null) setState(() => _dob = picked);
  }

  /// **نفحص هنا ما تفحصه القاعدة** — لا لنكرّر الحراسة بل لنترجمها.
  ///
  /// القيود مكتوبة في `profiles` وتردّ خطأً خاماً بلغة PostgreSQL:
  /// «violates check constraint profiles_phone_iraqi_format». من يقرأه
  /// لا يعرف ما المطلوب، فيجرّب رقماً آخر خطأً ثم يظنّ اللوحة معطّلة.
  String? _validate() {
    if (_name.text.trim().split(RegExp(r'\s+')).length < 3) {
      return 'الاسم ثلاثي — ثلاث كلمات على الأقل';
    }
    if (!RegExp(r'^\S+@\S+\.\S+$').hasMatch(_email.text.trim())) {
      return 'بريد غير صالح';
    }
    // ‎+964 ثم 7 ثم رقم من ٣ إلى ٩ ثم ثمانية أرقام — صيغة شبكات العراق.
    if (!RegExp(r'^\+9647[3-9][0-9]{8}$').hasMatch(_phone.text.trim())) {
      return 'الهاتف يجب أن يكون بصيغة ‎+9647XXXXXXXX — مثال: ‎+9647701234567';
    }
    if (_address.text.trim().length < 5) {
      return 'العنوان خمسة أحرف على الأقل';
    }
    if (_password.text.length < 8) {
      return 'كلمة المرور ثمانية أحرف على الأقل';
    }
    if (_dob == null) return 'حدّد تاريخ الميلاد';
    return null;
  }

  Future<void> _create() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminRepositoryProvider).createAccount(
            email: _email.text,
            password: _password.text,
            fullName: _name.text,
            phone: _phone.text,
            address: _address.text,
            dateOfBirth: _dob!,
            role: _role,
          );
      if (mounted) {
        Navigator.pop(
          context,
          (email: _email.text.trim(), password: _password.text),
        );
      }
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
      title: const Text('حساب جديد'),
      content: SizedBox(
        width: Breaks.dialogWidth(context, 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'rider',
                      label: Text('راكب'),
                      icon: Icon(Icons.person_outline)),
                  ButtonSegment(
                      value: 'driver',
                      label: Text('سائق'),
                      icon: Icon(Icons.two_wheeler)),
                ],
                selected: {_role},
                onSelectionChanged: _busy
                    ? null
                    : (s) => setState(() {
                          _role = s.first;
                          _dob = null; // الحد الأدنى للعمر يختلف
                        }),
              ),
              const SizedBox(height: 20),

              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'الاسم الكامل',
                  helperText: 'ثلاثي — ثلاث كلمات على الأقل',
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _email,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                  helperText: 'لن يُرسل رمز تأكيد — الحساب مؤكَّد فوراً',
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
                  helperText: 'مثال: ‎+9647701234567',
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _address,
                decoration: const InputDecoration(
                  labelText: 'العنوان',
                  helperText: 'خمسة أحرف على الأقل',
                ),
              ),
              const SizedBox(height: 16),

              InkWell(
                onTap: _busy ? null : _pickDate,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'تاريخ الميلاد',
                    helperText: _role == 'driver'
                        ? 'العمر الأدنى ١٨ سنة'
                        : 'العمر الأدنى ١٦ سنة',
                    suffixIcon: const Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(_dob == null
                      ? 'غير محدّد'
                      : '${_dob!.year}/${_dob!.month}/${_dob!.day}'),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _password,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: 'كلمة المرور',
                  helperText: 'مولّدة تلقائياً — عدّلها إن شئت',
                  suffixIcon: IconButton(
                    tooltip: 'توليد جديدة',
                    icon: const Icon(Icons.refresh),
                    onPressed: _busy
                        ? null
                        : () => setState(
                            () => _password.text = _randomPassword()),
                  ),
                ),
              ),

              // **تحذير قبل الفعل لا بعده.** من يُنشئ حساباً بكلمة مرور
              // يعرفها يستطيع الدخول به متى شاء — والسجلّ يقول إنه
              // أنشأه لا إنه استعمله.
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'الحساب يعمل فوراً بلا رمز تأكيد. سلّم صاحبه بيانات '
                        'الدخول واطلب منه تغيير كلمة المرور. والإنشاء '
                        'مسجَّل في سجلّ التدقيق باسمك.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
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
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('أنشئ الحساب'),
        ),
      ],
    );
  }
}

/// يعرض بيانات الدخول بعد الإنشاء — **مرة واحدة**.
///
/// كلمة المرور لا تُخزَّن نصاً في أي مكان، فمن يغلق هذه النافذة قبل أن
/// ينسخها لا يستطيع استرجاعها؛ يبقى أمامه أن يُنشئ حساباً آخر أو يُرسل
/// رابط استعادة.
Future<void> showCredentialsDialog(
  BuildContext context, {
  required String email,
  required String password,
}) {
  final text = 'البريد: $email\nكلمة المرور: $password';

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('أُنشئ الحساب'),
      content: SizedBox(
        width: Breaks.dialogWidth(ctx, 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('سلّم صاحب الحساب هذه البيانات:'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                text,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'لن تُعرض كلمة المرور مرة أخرى — انسخها الآن.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('نسخ'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(ctx).showSnackBar(
              const SnackBar(content: Text('نُسخت بيانات الدخول')),
            );
          },
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('تمّ'),
        ),
      ],
    ),
  );
}
