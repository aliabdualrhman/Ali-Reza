import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'errors.dart';

/// استعادة كلمة المرور — خطوتان: من أنت، ثم إلى أين نرسل.
///
/// **ولماذا نسأل عن الوجهة أصلاً؟** لأن أكثر من يوثّق في وضع الهاتف لا
/// يفتح بريده. ولو أرسلنا إلى البريد وحده لبقي حسابه مقفلاً وهو يملك
/// رقماً موثَّقاً في يده.
///
/// **وغير الموثَّق لا يُرسَل إليه.** رقمٌ لم يُوثَّق قد لا يملكه صاحب
/// الحساب — فإرسال رمزٍ إليه تسليمُ الحساب لغريب. لذلك يظهر رمادياً
/// ولا يُضغط، ومكتوبٌ تحته لماذا.
class ForgotPasswordFlow extends ConsumerStatefulWidget {
  const ForgotPasswordFlow({
    super.key,
    required this.onEmailChosen,
    required this.onDone,
  });

  /// يُنادى بالبريد بعد إرسال رمز GoTrue — ينقل إلى شاشة الرمز القائمة.
  final void Function(String email) onEmailChosen;

  /// بعد نجاح الاستعادة بالواتساب.
  final VoidCallback onDone;

  @override
  ConsumerState<ForgotPasswordFlow> createState() => _FlowState();
}

class _FlowState extends ConsumerState<ForgotPasswordFlow> {
  final _id = TextEditingController();

  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _channels;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await _sb.rpc('reset_channels',
          params: {'p_identifier': _id.text.trim()});
      final m = (v as Map).cast<String, dynamic>();

      if (m['found'] != true) {
        setState(() => _error = 'لا يوجد حساب بهذا الرقم أو البريد');
        return;
      }
      if (m['phone_ok'] != true && m['email_ok'] != true) {
        // لا يقع بعد أن صار التوثيق شرطاً للدخول، ويبقى ممكناً لحسابات
        // أُنشئت قبل ذلك. ولا نتركه بلا رسالة.
        setState(() => _error =
            'لا توجد قناة موثَّقة في هذا الحساب. تواصل مع الإدارة.');
        return;
      }
      setState(() => _channels = m);
    } catch (e) {
      setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendEmail() async {
    final email = _channels?['email'] as String?;
    if (email == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _sb.auth.resetPasswordForEmail(email);
      if (mounted) widget.onEmailChosen(email);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendPhone() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _sb.rpc('request_reset_code',
          params: {'p_identifier': _id.text.trim()});
      if (!mounted) return;

      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => _PhoneResetScreen(
            identifier: _id.text.trim(),
            masked: '${_channels?['phone_masked'] ?? ''}',
          ),
        ),
      );
      if (ok == true) widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _channels;

    return Scaffold(
      appBar: AppBar(title: const Text('استعادة كلمة المرور')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (c == null) ...[
              Text('اكتب رقم هاتفك أو بريدك المسجَّل',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              TextField(
                controller: _id,
                autofocus: true,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  hintText: '07XXXXXXXXX',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _busy ? null : _lookup(),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _lookup,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('متابعة'),
              ),
            ] else ...[
              Text('إلى أين نرسل الرمز؟',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'يصلك رمزٌ من ستة أرقام، تكتبه ثم تختار كلمة مرور جديدة.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),

              _ChannelTile(
                icon: Icons.chat_bubble_outline,
                title: 'واتساب',
                subtitle: '${c['phone_masked'] ?? ''}',
                enabled: c['phone_ok'] == true && !_busy,
                disabledNote: 'رقم هذا الحساب غير موثَّق',
                onTap: _sendPhone,
              ),
              const SizedBox(height: 12),
              _ChannelTile(
                icon: Icons.mail_outline,
                title: 'البريد',
                subtitle: '${c['email_masked'] ?? ''}',
                enabled: c['email_ok'] == true && !_busy,
                disabledNote: 'بريد هذا الحساب غير موثَّق',
                onTap: _sendEmail,
              ),

              const SizedBox(height: 20),
              TextButton(
                onPressed: _busy ? null : () => setState(() => _channels = null),
                child: const Text('تغيير الرقم أو البريد'),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 18),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// خيارُ قناة — يُضغط أو يُعطَّل مع سببٍ مكتوب.
///
/// **ولا يُخفى المعطَّل.** من لا يرى الواتساب أصلاً يظنّه غير مدعوم؛
/// ومن يراه رمادياً مع سببه يعرف أن عليه توثيق رقمه.
class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.disabledNote,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final String disabledNote;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        enabled: enabled,
        leading: Icon(icon, color: enabled ? theme.colorScheme.primary : dim),
        title: Text(title,
            style: TextStyle(color: enabled ? null : dim)),
        subtitle: Text(
          enabled ? subtitle : disabledNote,
          textDirection: enabled ? TextDirection.ltr : null,
          style: TextStyle(color: dim),
        ),
        trailing: enabled ? const Icon(Icons.chevron_left) : null,
        onTap: enabled ? onTap : null,
      ),
    );
  }
}

// =============================================================================
/// رمز الواتساب وكلمة المرور الجديدة — في شاشةٍ واحدة.
///
/// **خطوةٌ لا خطوتان.** من يكتب الرمز ثم يُنقل إلى شاشةٍ أخرى قد يجد
/// رمزه انتهى وهو يفكّر في كلمته. والاثنان يُرسلان معاً في نداءٍ واحد.
class _PhoneResetScreen extends StatefulWidget {
  const _PhoneResetScreen({required this.identifier, required this.masked});

  final String identifier;
  final String masked;

  @override
  State<_PhoneResetScreen> createState() => _PhoneResetState();
}

class _PhoneResetState extends State<_PhoneResetScreen> {
  final _code = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _ready =>
      _code.text.trim().length == 6 &&
      _pass.text.length >= 8 &&
      _pass.text == _confirm.text;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // **دالةٌ طرفية لا نداءٌ من التطبيق.** تغيير كلمة مرورٍ بلا جلسة
      // يحتاج صلاحية المشرف، ومفتاحها لا يجوز أن يمرّ بالتطبيق.
      final res = await Supabase.instance.client.functions.invoke(
        'reset-password',
        body: {
          'identifier': widget.identifier,
          'code': _code.text.trim(),
          'password': _pass.text,
        },
      );

      final data = (res.data as Map?)?.cast<String, dynamic>() ?? const {};
      if (data['ok'] != true) {
        setState(() => _error = '${data['error'] ?? 'تعذّر تغيير كلمة المرور'}');
        return;
      }

      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تغيّرت كلمة المرور — سجّل دخولك')),
      );
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
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('أرسلنا رمزاً إلى واتساب ${widget.masked}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),

          TextField(
            controller: _code,
            autofocus: true,
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(fontSize: 26, letterSpacing: 12),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              hintText: '••••••',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),

          const SizedBox(height: 20),
          TextField(
            controller: _pass,
            obscureText: !_show,
            decoration: InputDecoration(
              labelText: 'كلمة المرور الجديدة',
              helperText: 'ثمانية أحرف على الأقل',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _confirm,
            obscureText: !_show,
            decoration: InputDecoration(
              labelText: 'تأكيد كلمة المرور',
              border: const OutlineInputBorder(),
              errorText: _confirm.text.isNotEmpty && _confirm.text != _pass.text
                  ? 'لا تطابق'
                  : null,
            ),
            onChanged: (_) => setState(() {}),
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error)),
          ],

          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_busy || !_ready) ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('تغيير كلمة المرور'),
          ),
        ],
      ),
    );
  }
}
