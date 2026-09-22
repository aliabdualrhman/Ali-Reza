import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// توثيق رقم الهاتف برمزٍ يصل واتساب.
///
/// **وهي شرطٌ لا اقتراح.** كانت تُتخطّى بزرّ «لاحقاً»، فكانت تُنتج
/// حسابات لا هاتفها موثَّق ولا بريدها — ولمن نسي كلمته منهم لا قناة
/// تصله بها. فصار الدخول يشترط قناةً واحدة موثَّقة على الأقل.
///
/// وتُفتح في موضعين: بوابة التسجيل (بـ`onDone`) فلا مخرج منها إلا
/// التوثيق أو الخروج، ومن «حسابي» طوعاً فيرجع منها بزرّ الرجوع.
class VerifyPhoneScreen extends ConsumerStatefulWidget {
  const VerifyPhoneScreen({super.key, this.onDone});

  /// يُستدعى بعد التوثيق أو التخطّي. فارغ = نرجع للخلف.
  final VoidCallback? onDone;

  @override
  ConsumerState<VerifyPhoneScreen> createState() => _VerifyPhoneScreenState();
}

class _VerifyPhoneScreenState extends ConsumerState<VerifyPhoneScreen> {
  final _code = TextEditingController();

  bool _sending = false;
  bool _verifying = false;
  bool _sent = false;
  String? _error;
  String? _phone;

  /// ثوانٍ حتى يُسمح بطلب رمزٍ جديد. **عدّادٌ مرئيّ لا رفضٌ مفاجئ:** من
  /// يضغط «أعد الإرسال» فيُرفض بلا سبب ظاهر يظنّ التطبيق معطوباً.
  int _cooldown = 0;
  Timer? _ticker;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
    // نطلب الرمز فور فتح الشاشة — من فتحها يريده.
    WidgetsBinding.instance.addPostFrameCallback((_) => _request());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _ticker?.cancel();
    setState(() => _cooldown = seconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _request() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final v = await _sb.rpc('request_phone_code');
      final m = (v as Map).cast<String, dynamic>();
      if (mounted) {
        setState(() {
          _sent = true;
          _phone = m['phone'] as String?;
        });
        _startCooldown(60);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _clean('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final ok = await _sb
          .rpc('verify_phone_code', params: {'p_code': _code.text.trim()});

      if (ok == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تمّ توثيق رقمك ✓')),
        );
        _done();
      } else {
        setState(() => _error = 'الرمز غير صحيح. تحقّق وأعد المحاولة.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = _clean('$e'));
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _done() {
    if (widget.onDone != null) {
      widget.onDone!();
      return;
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  /// **رسالة القاعدة لا نصّ الاستثناء.** المستخدم لا يفهم
  /// `PostgrestException(message: …)` ولا يجب أن يراها.
  static String _clean(String raw) {
    final m = RegExp(r'message:\s*([^,)]+)').firstMatch(raw);
    return m?.group(1)?.trim() ?? raw;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('توثيق رقمك'),
        // **زرّ رجوعٍ لا تخطٍّ.** الفرق ليس شكلياً: التخطّي كان
        // يُدخل المستخدم بحسابٍ غير موثَّق، والرجوع يُخرجه من الجلسة
        // فيعود إلى الدخول. فمن تعطّل الإرسال عنده ينصرف ولا يُحبس،
        // ولا يدخل أحدٌ بلا توثيق أبداً.
        //
        // والصمّام في اللوحة: إطفاء `otp_enabled` يمنع البوابة كلها،
        // فعطلٌ عند مزوّد الرسائل لا يُقفل باب التسجيل.
        leading: widget.onDone == null
            ? null
            : IconButton(
                icon: const BackButtonIcon(),
                tooltip: 'رجوع',
                onPressed: () => _sb.auth.signOut(),
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 20),

          Text(
            'أرسلنا رمزاً إلى واتساب',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            _phone == null
                ? 'على رقمك المسجَّل'
                : 'على الرقم $_phone',
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            'وإن لم يكن لديك واتساب، تصلك رسالة نصّية.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),

          const SizedBox(height: 32),
          TextField(
            controller: _code,
            autofocus: true,
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(fontSize: 30, letterSpacing: 14),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              hintText: '••••••',
              counterText: '',
            ),
            onSubmitted: (_) {
              if (_code.text.trim().length == 6) _verify();
            },
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error)),
          ],

          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_verifying || _code.text.trim().length < 6)
                ? null
                : _verify,
            child: _verifying
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('تأكيد'),
          ),

          const SizedBox(height: 12),
          TextButton(
            onPressed: (_sending || _cooldown > 0) ? null : _request,
            child: Text(
              _sending
                  ? 'جارٍ الإرسال…'
                  : _cooldown > 0
                      ? 'أعد الإرسال بعد $_cooldown ثانية'
                      : _sent
                          ? 'أعد إرسال الرمز'
                          : 'أرسل الرمز',
            ),
          ),

          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'التوثيق يضمن وصول رقمك للسائق عند الحاجة، وللمنصة '
                    'عند تحويل الأموال — وهو طريقك لاستعادة كلمة المرور '
                    'إن نسيتها.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
