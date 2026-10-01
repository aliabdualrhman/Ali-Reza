import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';

/// كم سلّمك الراكب؟ — وما زاد يعود إلى محفظته.
///
/// **مشكلةٌ يوميّة في سوقٍ نقديّ.** الأجرة ١٥٠٠ والراكب يحمل ٢٠٠٠ وليس
/// معك فكّة. فإمّا أن يخسر خمسمئة، أو تقفان في الشارع تبحثان عن صرّاف.
/// وكلاهما يُفقدنا راكباً.
///
/// **فالباقي يصير رصيداً** ينتقل من محفظتك إلى محفظته في اللحظة نفسها.
///
/// **والزرّ الأول هو «بالضبط».** أكثر الرحلات تُدفع تماماً، فلا يجوز أن
/// تكلّف كتابةَ رقمٍ في كل مرة — خطوةٌ زائدة على كل رحلة تُتجاوَز
/// بالضغط العشوائي، فتفسد البيانات كلها.
///
/// **ولا اقتراحاتٍ جاهزة.** كانت رقائق ١٠٠٠ و٥٠٠٠ و١٠٠٠٠، وهي تصلح
/// لأجرةٍ كبيرة وتُعيق أجرةً صغيرة: من أجرته ٧٥٠ لا يجد فيها ما يناسبه،
/// ومن استلم ٩٠٠ لا يجد رقمه. والكتابة تقبل كل مبلغ.
class CashChangeScreen extends ConsumerStatefulWidget {
  const CashChangeScreen({
    super.key,
    required this.tripId,
    required this.cashDue,
    required this.onDone,
  });

  final String tripId;
  final num cashDue;
  final VoidCallback onDone;

  @override
  ConsumerState<CashChangeScreen> createState() => _CashChangeState();
}

class _CashChangeState extends ConsumerState<CashChangeScreen> {
  final _custom = TextEditingController();

  /// **المستحقّ يُقرأ حيّاً لا لحظةَ الفتح.** مُشغّل القاعدة يضيف ثمن
  /// البضاعة إلى `cash_due_iqd` بعد الإكمال بلحظة؛ وشاشةٌ التقطت الرقم
  /// قبلها تبقى على الأجرة وحدها — فيُرجع السائق ثمن البضاعة من جيبه.
  Map<String, dynamic>? get _live => ref.watch(pendingCashProvider);

  num get _due => (_live?['_due'] as num?) ?? widget.cashDue;
  num get _goods =>
      (_live?['goods_actual_iqd'] as num?) ??
      (_live?['goods_estimate_iqd'] as num?) ??
      0;
  num get _fare => (_due - _goods) < 0 ? 0 : _due - _goods;
  bool get _isShopping => _live?['kind'] == 'shopping';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  num? get _value {
    final v = num.tryParse(_custom.text.trim());
    return (v == null || v <= 0) ? null : v;
  }

  num get _change {
    final v = _value;
    if (v == null) return 0;
    return v - _due < 0 ? 0 : v - _due;
  }

  /// **السبب مكتوبٌ لا مُلمَّح إليه.** زرٌّ رماديّ بلا سببٍ ظاهر يجعل
  /// السائق يظنّ الحقل يرفض الأرقام، فيعيد الكتابة مراراً ثم يتصل
  /// بالدعم — وقد وقع ذلك فعلاً.
  String? get _why {
    final v = _value;
    if (v == null) return null;

    if (v < _due) {
      return 'هذا أقلّ من المستحقّ (${_due.round()} دينار). '
          'إن سلّمك أقلّ، فالباقي عليه لا عليك — تواصل مع الدعم.';
    }
    return null;
  }

  Future<void> _submit(num received) async {
    // **يؤكّد قبل أن يُخصم.** رقمٌ يُكتب بإصبعٍ على شاشةٍ في الشارع
    // يُخطئ، و«٢٠٠٠٠» بدل «٢٠٠٠» تُخرج من رصيدك ثمانية عشر ألفاً.
    final change = received - _due;
    if (change > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تأكيد الباقي'),
          content: Text(
            'استلمتَ ${received.round()} دينار، والمستحقّ '
            '${widget.cashDue.round()}.\n\n'
            'سيُخصم ${change.round()} دينار من رصيدك ويدخل محفظة الراكب.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('تراجع')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('نعم، أرجِع الباقي')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(driverRepositoryProvider)
          .settleCashChange(tripId: widget.tripId, received: received);
      if (mounted) widget.onDone();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AppError.message(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = _due.round();

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                Icon(Icons.payments_outlined,
                    size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 18),
                Text('المستحقّ نقداً',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text('$due دينار',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall
                        ?.copyWith(fontWeight: FontWeight.bold)),

                // **التفصيل قبل المجموع.** السائق دفع ثمن البضاعة من
                // جيبه، فحقّه أن يرى أنه يستردّه — ورقمٌ واحد مجموعٌ
                // لا يقول له إن ماله عاد إليه.
                if (_isShopping && _goods > 0) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        _Line('ثمن البضاعة', _goods.round(), theme),
                        const SizedBox(height: 6),
                        _Line('أجرة التوصيل', _fare.round(), theme),
                        const Divider(height: 18),
                        _Line('المجموع', due, theme, bold: true),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _busy ? null : () => _submit(_due),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(60)),
                  child: const Text('استلمتُ المبلغ بالضبط',
                      style: TextStyle(fontSize: 17)),
                ),

                const SizedBox(height: 24),
                Text('أو سلّمك أكثر ولا فكّة معك:',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'اكتب ما سلّمك بالضبط.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _custom,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  textDirection: TextDirection.ltr,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'المبلغ الذي سلّمك',
                    suffixText: 'دينار',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),

                if (_why != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 18,
                            color: theme.colorScheme.onErrorContainer),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_why!,
                              style: TextStyle(
                                  color:
                                      theme.colorScheme.onErrorContainer)),
                        ),
                      ],
                    ),
                  ),
                ],

                // **الباقي مكتوبٌ قبل الضغط لا بعده.** من يرى الرقم
                // يراجعه؛ ومن لا يراه يكتشفه في رصيده.
                if (_change > 0 && _why == null) ...[
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'يعود ${_change.round()} دينار إلى محفظة الراكب، '
                      'ويُخصم من رصيدك.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],

                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error)),
                ],

                const SizedBox(height: 22),
                FilledButton.tonal(
                  onPressed:
                      (_busy || _value == null || _change <= 0 || _why != null)
                          ? null
                          : () => _submit(_value!),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56)),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4))
                      : const Text('أرجِع الباقي إلى محفظته',
                          style: TextStyle(fontSize: 17)),
                ),

                const SizedBox(height: 10),
                Text(
                  'يصل الراكب إشعارٌ باسمك وبالمبلغ.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// سطرٌ في تفصيل المستحقّ.
class _Line extends StatelessWidget {
  const _Line(this.label, this.value, this.theme, {this.bold = false});

  final String label;
  final int value;
  final ThemeData theme;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)
        : theme.textTheme.bodyMedium;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: style),
        Text('$value دينار', style: style),
      ],
    );
  }
}
