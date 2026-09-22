import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'errors.dart';
import 'validators.dart';

/// إكمال استعادة كلمة المرور برمز من ٦ أرقام — مشتركة بين التطبيقين.
///
/// **العطل الذي وُلدت منه.** كانت الاستعادة تعتمد على الرابط في الرسالة،
/// وهو مقطوع في ثلاثة مواضع معاً:
///
///   ١) القالب يرسل `{{ .ConfirmationURL }}` لا رمزاً.
///   ٢) الرابط يوجّه إلى `Site URL` وقيمته الافتراضية `localhost:3000`،
///      فيرى صاحبه على هاتفه `ERR_CONNECTION_REFUSED`.
///   ٣) ولا يوجد فلتر روابط عميقة في البيان أصلاً، فحتى لو صحّ العنوان
///      لفُتح في المتصفح لا في التطبيق.
///
/// فمن ينسى كلمة مروره كان يفقد حسابه نهائياً — وفي تطبيق فيه محافظ
/// وأرصدة، ذلك فقدان مال لا إزعاج واجهة.
///
/// **ولماذا الرمز لا إصلاح الرابط؟** لأن الروابط العميقة تحتاج نطاقاً
/// مملوكاً وملف تحقق على خادمه ومراجعة من جوجل. والرمز يعمل اليوم بلا
/// شيء من ذلك — وهو النمط الذي يعمل في تأكيد التسجيل عندنا أصلاً.
/// نصف المسار كان محوّلاً إلى الرموز ونصفه منسيّاً على الروابط.
///
/// **يتطلب تعديلاً في لوحة Supabase:** قالب `Reset Password` يجب أن يعرض
/// `{{ .Token }}` بدل `{{ .ConfirmationURL }}`.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({
    super.key,
    required this.email,
    required this.onDone,
  });

  /// البريد الذي أُرسل إليه الرمز.
  final String email;

  /// يُستدعى بعد نجاح التغيير — التنقّل من مسؤولية التطبيق لا الحزمة.
  final VoidCallback onDone;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final sb = Supabase.instance.client;
    try {
      // **الترتيب إلزامي.** التحقق من الرمز يُنشئ الجلسة، و`updateUser`
      // لا تعمل بلا جلسة. عكسُهما يفشل بخطأ صلاحية مضلِّل.
      await sb.auth.verifyOTP(
        type: OtpType.recovery,
        email: widget.email.trim(),
        token: _code.text.trim(),
      );
      await sb.auth.updateUser(UserAttributes(password: _pass.text));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تغيير كلمة المرور')),
      );
      widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('كلمة مرور جديدة')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'أرسلنا رمزاً من ٦ أرقام إلى',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.email,
                      style: theme.textTheme.titleSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),

                    TextFormField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24, letterSpacing: 8),
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'الرمز',
                        counterText: '',
                      ),
                      validator: (v) => (v ?? '').trim().length == 6
                          ? null
                          : 'أدخل الرمز المكوّن من ٦ أرقام',
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _pass,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: 'كلمة المرور الجديدة',
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility
                              : Icons.visibility_off),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: Validators.password,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _confirm,
                      obscureText: _obscure,
                      decoration:
                          const InputDecoration(labelText: 'تأكيد كلمة المرور'),
                      validator: (v) =>
                          Validators.confirmPassword(v, _pass.text),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ],

                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('تغيير كلمة المرور'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
