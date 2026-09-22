import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'auth_repository.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // نخفي لوحة المفاتيح أولاً حتى يرى المستخدم رسالة الخطأ إن ظهرت
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    // **المُخبِر يُمسك قبل الانتظار.** إن أخرج الحارس الحساب أُتلفت هذه
    // الشاشة، و`ref` بعدها لا يعمل — والرسالة يجب أن تصل الشاشة الجديدة.
    final notice = ref.read(authNoticeProvider.notifier);
    notice.set(null);

    // **الدخول ليس تسجيلاً.** علامة «أنشأ حساباً للتو» تبقى مرفوعة ما دام
    // توثيق الرقم لم يكتمل؛ فإن خرج صاحبها ثم دخل بأي حساب، طُلب منه
    // توثيقٌ لم يُطلب إلا عند التسجيل. تُنزَل عند كل دخول.
    ref.read(justSignedUpProvider.notifier).set(false);

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).signIn(
            email: _email.text,
            password: _password.text,
          );
      // لا ننتقل يدوياً — الموجّه يستمع لتغيّر الجلسة ويعيد التوجيه تلقائياً
    } catch (e) {
      final msg = AppError.message(e);
      notice.set(msg);
      if (mounted) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ZanbourLogo(size: 88),
                    const SizedBox(height: 12),
                    Text(
                      'زنبور — تطبيق السائق',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'سجّل دخولك لتبدأ العمل',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 32),

                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      // البريد لاتيني دائماً — نفرض الاتجاه حتى لا ينقلب
                      // شكله داخل واجهة عربية.
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'البريد الإلكتروني',
                        prefixIcon: Icon(Icons.alternate_email),
                      ),
                      validator: Validators.email,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      textDirection: TextDirection.ltr,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                          tooltip: _obscure ? 'إظهار' : 'إخفاء',
                        ),
                      ),
                      // لا نطبّق قواعد قوة كلمة المرور عند الدخول:
                      // حساب قديم قد يحمل كلمة لا تحقق قواعدنا الحالية،
                      // ومنعه من الدخول بسببها خطأ.
                      validator: (v) =>
                          (v ?? '').isEmpty ? 'كلمة المرور مطلوبة' : null,
                    ),

                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => context.push('/forgot-password'),
                        child: const Text('نسيت كلمة المرور؟'),
                      ),
                    ),

                    if ((_error ?? ref.watch(authNoticeProvider)) != null) ...[
                      const SizedBox(height: 8),
                      _ErrorBanner(
                          message: _error ?? ref.watch(authNoticeProvider)!),
                    ],

                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : const Text('تسجيل الدخول'),
                    ),

                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('ليس لديك حساب؟',
                            style: theme.textTheme.bodyMedium),
                        TextButton(
                          onPressed: _busy ? null : () => context.push('/signup'),
                          child: const Text('أنشئ حساباً'),
                        ),
                      ],
                    ),

                    // **للمتاجر أولاً.** آبل ترفض ما يُجبر زائره على
                    // التسجيل قبل أن يرى شيئاً — انظر `GuestMode`.
                    const SizedBox(height: 4),
                    GuestEntryButton(onEntered: () => context.go('/guest')),
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

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
