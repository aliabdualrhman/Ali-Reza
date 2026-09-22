import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// شاشة «ادعُ صديقاً» — مشتركة بين الراكب والسائق.
///
/// **النصوص والمبالغ كلها من الخادم لا من الكود.** المكافأة وعدد الرحلات
/// والسقف تتغيّر من لوحة المدير، ولو كتبناها هنا لعرضت الشاشة رقماً
/// والقاعدة تصرف آخر — وهو أسوأ من ألا نعرض شيئاً.
class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key, required this.isDriver});

  final bool isDriver;

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await _sb.rpc('my_referrals');
      if (mounted) setState(() => _data = (v as Map).cast<String, dynamic>());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// **يُولَّد عند أول طلب لا عند التسجيل.** أكثر المستخدمين لن يدعوا
  /// أحداً، فلا معنى لرمزٍ لكل حساب.
  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      await _sb.rpc('my_referral_code');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// رمزٌ جديد يُبطل ما قبله.
  ///
  /// **لمن نشره في مكانٍ عام ثم ندم.** والتأكيد لازم: من يضغطه ظنّاً
  /// أنه «تحديث» يقطع دعوةً أرسلها قبل دقيقة.
  Future<void> _rotate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('رمز جديد'),
        content: const Text(
            'يُبطل رمزك الحالي فوراً. من أرسلتَ له الرمز القديم ولم '
            'يستعمله بعد لن يستطيع.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('أنشئ رمزاً جديداً')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await _sb.rpc('rotate_referral_code');
      await _load();
      _toast('رمزك الجديد جاهز');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _data;

    final code = d?['code'] as String?;
    final reward = (d?['reward'] as num?)?.round() ?? 0;
    final trips = (d?['required_trips'] as num?)?.toInt() ?? 3;
    final cap = (d?['cap'] as num?)?.toInt() ?? 2;
    final rewarded = (d?['rewarded'] as num?)?.toInt() ?? 0;
    final pending = (d?['pending'] as num?)?.toInt() ?? 0;
    final earned = (d?['earned'] as num?)?.round() ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('ادعُ صديقاً')),
      body: _data == null && _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_error != null) ...[
                  SelectableText(_error!,
                      style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 16),
                ],

                // ---- الرمز ----
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(Icons.card_giftcard,
                            size: 44, color: theme.colorScheme.primary),
                        const SizedBox(height: 12),
                        Text(
                          'ادعُ ${widget.isDriver ? 'سائقاً' : 'صديقاً'} '
                          'واكسب $reward دينار',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 20),

                        if (code == null)
                          FilledButton.icon(
                            onPressed: _busy ? null : _generate,
                            icon: const Icon(Icons.qr_code),
                            label: const Text('أنشئ رمز الدعوة'),
                          )
                        else ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 16, horizontal: 28),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: SelectableText(
                              code,
                              textDirection: TextDirection.ltr,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 6,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            alignment: WrapAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: () => _copy(code, reward, trips),
                                icon: const Icon(Icons.copy, size: 18),
                                label: const Text('نسخ الدعوة'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: code));
                                  _toast('نُسخ الرمز');
                                },
                                icon: const Icon(Icons.tag, size: 18),
                                label: const Text('نسخ الرمز فقط'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // **القاعدة مكتوبة تحت الرمز لا في صفحة شروط.**
                          // من لا يعرف أنه لشخصٍ واحد يرميه في مجموعة
                          // واتساب، فيأخذه أوّل من قرأ ويغضب الباقون.
                          Text(
                            'هذا الرمز لشخصٍ واحد. حين يستعمله أحد '
                            'يتجدّد تلقائياً برمزٍ جديد.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                          TextButton.icon(
                            onPressed: _busy ? null : _rotate,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('أنشئ رمزاً جديداً الآن'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // ---- كيف تعمل ----
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('كيف تكسب؟', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 14),
                        _Step(1, 'أرسل رمزك إلى '
                            '${widget.isDriver ? 'سائق' : 'صديق'} لم يسجّل بعد.'),
                        _Step(2, 'يكتبه عند التسجيل، أو من صفحة حسابه '
                            'قبل أول رحلة له.'),
                        _Step(3, 'بعد $trips رحلات مكتملة له، '
                            'يصلك $reward دينار رصيد هدية.'),
                        const SizedBox(height: 14),

                        // **الشرط مكتوب لا مخفيّ.** من يكتشف أن هديته لا
                        // تُسحب بعد أن كسبها يشعر أنه خُدع؛ ومن يعرف
                        // ذلك من البداية يستعملها راضياً.
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 18,
                                  color: theme.colorScheme.onSurfaceVariant),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  widget.isDriver
                                      ? 'رصيد الهدية يُخصم من عمولاتك ولا '
                                          'يُسحب نقداً. وتستطيع كسبه من '
                                          '$cap دعوات.'
                                      : 'رصيد الهدية يُخصم من أجرة رحلاتك '
                                          'ولا يُسحب نقداً. وتستطيع كسبه من '
                                          '$cap دعوات.',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // ---- حصيلتي ----
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('دعواتي', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 36,
                          runSpacing: 14,
                          children: [
                            _Stat('نجحت', '$rewarded من $cap'),
                            _Stat('قيد الإكمال', '$pending'),
                            _Stat('كسبتَ', '$earned دينار'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  void _copy(String code, int reward, int trips) {
    // **رسالة جاهزة لا رمزٌ عارٍ.** من ينسخ رمزاً وحده يرسله بلا شرح،
    // فيسأل صديقه «ما هذا؟» وتموت الدعوة في السؤال.
    final text = 'حمّل تطبيق زنبور واستعمل رمز الدعوة: $code\n'
        'zanbour.iq';
    Clipboard.setData(ClipboardData(text: text));
    _toast('نُسخت الدعوة — أرسلها لصديقك');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text('$n',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(value,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// نافذة إدخال رمز دعوة — تُفتح من «حسابي» خلال مهلة السماح.
///
/// **ولماذا مهلة سماح؟** لأن الرمز يُنسى وقت التسجيل: الرجل واقفٌ في
/// الشارع يسجّل ولا يتذكّر أن يتصل بصديقه. والمهلة تكسب ثلث الدعوات
/// الضائعة بلا كلفة.
Future<bool?> showRedeemCodeDialog(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (_) => const _RedeemCodeDialog(),
    );

class _RedeemCodeDialog extends StatefulWidget {
  const _RedeemCodeDialog();

  @override
  State<_RedeemCodeDialog> createState() => _RedeemCodeDialogState();
}

class _RedeemCodeDialogState extends State<_RedeemCodeDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await Supabase.instance.client
          .rpc('redeem_referral_code', params: {'p_code': _code.text.trim()});
      final m = (v as Map).cast<String, dynamic>();

      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('قُبل رمز ${m['inviter']} — أكمل '
            '${m['required_trips']} رحلات ليحصل على مكافأته.'),
        duration: const Duration(seconds: 6),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = _clean('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// **رسالة القاعدة لا نصّ الاستثناء.** المستخدم لا يفهم
  /// `PostgrestException(message: ...)` ولا يجب أن يراها.
  static String _clean(String raw) {
    final m = RegExp(r'message:\s*([^,)]+)').firstMatch(raw);
    return m?.group(1)?.trim() ?? raw;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('رمز دعوة'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('إن دعاك صديق، اكتب رمزه هنا ليحصل على مكافأته '
              'بعد إكمالك رحلاتك الأولى.'),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            maxLength: 6,
            style: const TextStyle(fontSize: 22, letterSpacing: 6),
            inputFormatters: [
              // الرمز حروفٌ كبيرة وأرقام فقط — نمنع ما لا يُقبل أصلاً
              // بدل أن نردّه بخطأ بعد الإرسال.
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
            ],
            decoration: const InputDecoration(
              hintText: 'ABC123',
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: (_busy || _code.text.trim().length < 6) ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('تأكيد'),
        ),
      ],
    );
  }
}
