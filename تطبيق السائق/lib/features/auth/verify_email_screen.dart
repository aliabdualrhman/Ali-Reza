import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'auth_repository.dart';

/// تأكيد البريد برمز من ٦ أرقام.
///
/// **لماذا رمز لا رابط؟** الرابط الافتراضي في Supabase يوجّه إلى عنوان
/// إعادة توجيه لا وجود له ما دمنا بلا موقع، فيرى المستخدم صفحة خطأ حتى
/// حين ينجح التفعيل فعلاً. والرمز يبقي المستخدم داخل التطبيق من أوله
/// لآخره بلا انتقال إلى المتصفح.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});

  final String email;

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  final _code = TextEditingController();
  final _focus = FocusNode();

  bool _busy = false;
  String? _error;
  String? _info;

  /// مهلة قبل السماح بإعادة الإرسال.
  ///
  /// Supabase يحدّ الإرسال من طرفه، فبدون عدّاد يضغط المستخدم الزر مراراً
  /// ويصطدم برسالة "محاولات كثيرة" بدل انتظار واضح.
  int _cooldown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // نفتح لوحة المفاتيح فوراً: هذه الشاشة لها غرض واحد لا غير.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startCooldown() {
    setState(() => _cooldown = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'أدخل الرمز المكوّن من ٦ أرقام');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });

    try {
      await ref.read(authRepositoryProvider).verifyEmailOtp(
            email: widget.email,
            token: code,
          );
      // نجح: أُنشئت الجلسة والموجّه ينقل تلقائياً لشاشة الصورة الحية
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AppError.message(e);
          _code.clear();
        });
        _focus.requestFocus();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(authRepositoryProvider).resendConfirmation(widget.email);
      if (mounted) {
        setState(() => _info = 'أُرسل رمز جديد إلى بريدك');
        _startCooldown();
      }
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
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.mark_email_unread_outlined,
                      size: 80, color: theme.colorScheme.primary),
                  const SizedBox(height: 20),
                  Text(
                    'أدخل رمز التأكيد',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'أرسلنا رمزاً من ٦ أرقام إلى',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.email,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 32),

                  // حقل واحد بخط كبير ومسافات متباعدة بدل ست خانات منفصلة.
                  // أبسط في الكود، ويسمح بلصق الرمز كاملاً دفعة واحدة —
                  // وهو ما يفعله أغلب الناس فعلاً.
                  TextField(
                    controller: _code,
                    focusNode: _focus,
                    autofocus: true,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    maxLength: 6,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 14,
                    ),
                    decoration: const InputDecoration(
                      hintText: '••••••',
                      counterText: '',
                    ),
                    onChanged: (v) {
                      if (_error != null) setState(() => _error = null);
                      // تحقق تلقائي عند اكتمال الرمز — لا داعي لضغطة زر
                      if (v.length == 6) _verify();
                    },
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  if (_info != null) ...[
                    const SizedBox(height: 12),
                    Text(_info!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.primary)),
                  ],

                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _verify,
                    child: _busy
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4))
                        : const Text('تأكيد'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: (_busy || _cooldown > 0) ? null : _resend,
                    child: Text(_cooldown > 0
                        ? 'إعادة الإرسال بعد $_cooldown ثانية'
                        : 'لم يصلني الرمز — أعد الإرسال'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'تحقق من مجلد الرسائل غير المرغوبة إن لم تجد الرسالة',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : () => context.go('/login'),
                    child: const Text('العودة لتسجيل الدخول'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
