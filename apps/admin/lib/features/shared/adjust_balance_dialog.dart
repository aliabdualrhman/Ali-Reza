import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';

/// تعديل رصيد سائق أو راكب.
///
/// **لماذا نافذة واحدة لأربعة أفعال؟** (إضافة فعلي، إضافة هدية، خصم
/// فعلي، خصم هدية) — لأنها فعلٌ واحد بمعاملين. وأربعة أزرار في صفحة
/// السائق تعني أربعة مسارات تتباعد بالصيانة، وأربع فرص للخلط.
///
/// **والنوع سؤالٌ لا افتراض.** كان الحقن يضيف إلى الرصيد الفعلي دائماً،
/// وهو القابل للسحب. فمنحةٌ تحفيزية تُضاف سهواً إليه تخرج نقداً من
/// الخزينة بلا أن يلاحظ أحد. الاختيار هنا إجباري ومرئي.
///
/// يعيد `true` إن حُفظ التعديل.
Future<bool?> showAdjustBalanceDialog(
  BuildContext context, {
  required String userId,
  required String fullName,
  required bool isDriver,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _AdjustBalanceDialog(
        userId: userId,
        fullName: fullName,
        isDriver: isDriver,
      ),
    );

class _AdjustBalanceDialog extends ConsumerStatefulWidget {
  const _AdjustBalanceDialog({
    required this.userId,
    required this.fullName,
    required this.isDriver,
  });

  final String userId;
  final String fullName;
  final bool isDriver;

  @override
  ConsumerState<_AdjustBalanceDialog> createState() =>
      _AdjustBalanceDialogState();
}

class _AdjustBalanceDialogState extends ConsumerState<_AdjustBalanceDialog> {
  final _amount = TextEditingController();
  final _note = TextEditingController();

  bool _isBonus = false;
  bool _isDeduction = false;
  int _expiresDays = 30;

  bool _busy = false;
  String? _error;

  static const _quick = [5000, 10000, 25000, 50000];

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _value => int.tryParse(_amount.text.trim()) ?? 0;
  bool get _valid => _value > 0 && _note.text.trim().isNotEmpty;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(adminRepositoryProvider).adjustBalance(
            userId: widget.userId,
            isDriver: widget.isDriver,
            amount: _isDeduction ? -_value : _value,
            isBonus: _isBonus,
            note: _note.text.trim(),
            expiresDays:
                (!widget.isDriver && _isBonus && !_isDeduction)
                    ? _expiresDays
                    : null,
          );

      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '${_isDeduction ? 'خُصم' : 'أُضيف'} $_value دينار '
          '(${_isBonus ? 'هدية' : 'فعلي'}) — '
          'الفعلي ${r.real.round()} · الهدية ${r.bonus.round()}',
        ),
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
      title: Text('رصيد ${widget.fullName}'),
      content: SizedBox(
        width: Breaks.dialogWidth(context, 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- إضافة أم خصم ----
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: false,
                      label: Text('إضافة'),
                      icon: Icon(Icons.add)),
                  ButtonSegment(
                      value: true,
                      label: Text('خصم'),
                      icon: Icon(Icons.remove)),
                ],
                selected: {_isDeduction},
                onSelectionChanged: _busy
                    ? null
                    : (s) => setState(() => _isDeduction = s.first),
              ),
              const SizedBox(height: 16),

              // ---- نوع الرصيد ----
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: false,
                      label: Text('فعلي'),
                      icon: Icon(Icons.payments_outlined)),
                  ButtonSegment(
                      value: true,
                      label: Text('هدية'),
                      icon: Icon(Icons.card_giftcard)),
                ],
                selected: {_isBonus},
                onSelectionChanged:
                    _busy ? null : (s) => setState(() => _isBonus = s.first),
              ),
              const SizedBox(height: 10),

              // **الفرق مكتوب لا مفترَض.** من يضغط «هدية» يجب أن يعرف
              // أنه يمنح مالاً لا يُسترد نقداً، ومن يضغط «فعلي» أنه
              // يمنح ما يُسحب.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isBonus ? Icons.card_giftcard : Icons.payments_outlined,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _isBonus
                            ? 'رصيد هدية — يُنفق داخل التطبيق ولا يُسحب '
                                'نقداً أبداً.'
                            : 'رصيد فعلي — يملكه صاحبه ويستطيع سحبه نقداً.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),

              // ---- صلاحية الهدية: للراكب وعند الإضافة فقط ----
              if (!widget.isDriver && _isBonus && !_isDeduction) ...[
                const SizedBox(height: 16),
                Text('تنتهي بعد', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final d in [7, 30, 90])
                      ChoiceChip(
                        label: Text('$d يوماً'),
                        selected: _expiresDays == d,
                        onSelected: (_) => setState(() => _expiresDays = d),
                      ),
                  ],
                ),
              ],

              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in _quick)
                    ChoiceChip(
                      label: Text('$q'),
                      selected: _value == q,
                      onSelected: (_) => setState(() => _amount.text = '$q'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'المبلغ',
                  suffixText: 'دينار',
                ),
              ),

              const SizedBox(height: 16),
              TextField(
                controller: _note,
                decoration: InputDecoration(
                  labelText: 'السبب',
                  helperText: 'مطلوب — يظهر في سجلّ التدقيق',
                  hintText: _isDeduction
                      ? 'مخالفة، تصحيح خطأ…'
                      : 'تعبئة نقدية، تحفيز، تعويض…',
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
          onPressed: (_busy || !_valid) ? null : _save,
          style: _isDeduction
              ? FilledButton.styleFrom(backgroundColor: AdminTheme.danger)
              : null,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_isDeduction ? 'اخصم' : 'أضِف'),
        ),
      ],
    );
  }
}

/// بطاقة الرصيدين — تُعرض في صفحة السائق والراكب.
///
/// **رقمان لا رقم واحد.** مجموعهما يخفي ما يهمّ فعلاً: كم يستطيع أن
/// يسحب، وكم منحناه.
class BalanceCard extends StatelessWidget {
  const BalanceCard({
    super.key,
    required this.real,
    required this.bonus,
    this.bonusExpiresAt,
    this.onAdjust,
  });

  final num real;
  final num bonus;
  final DateTime? bonusExpiresAt;
  final VoidCallback? onAdjust;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expired =
        bonusExpiresAt != null && bonusExpiresAt!.isBefore(DateTime.now());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('الرصيد', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (onAdjust != null)
                  TextButton.icon(
                    onPressed: onAdjust,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('تعديل'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 40,
              runSpacing: 16,
              children: [
                _Amount(
                  label: 'فعلي — قابل للسحب',
                  value: real,
                  // **السالب دَين لا رصيد.** عرضه كرقم سالب يربك؛
                  // وقوله صراحةً يجعل المدير يعرف أنه مطالِب لا مدين.
                  caption: real < 0 ? 'عليه ${real.abs().round()} دينار' : null,
                  color: real < 0 ? AdminTheme.danger : null,
                ),
                _Amount(
                  label: 'هدية — لا تُسحب',
                  value: bonus,
                  caption: bonusExpiresAt == null
                      ? null
                      : expired
                          ? 'انتهت صلاحيتها'
                          : 'تنتهي ${_fmt(bonusExpiresAt!)}',
                  color: expired ? theme.colorScheme.onSurfaceVariant : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/'
      '${d.day.toString().padLeft(2, '0')}';
}

class _Amount extends StatelessWidget {
  const _Amount({
    required this.label,
    required this.value,
    this.caption,
    this.color,
  });

  final String label;
  final num value;
  final String? caption;
  final Color? color;

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
        Text(
          '${value.round()} دينار',
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600, color: color),
        ),
        if (caption != null)
          Text(caption!,
              style: theme.textTheme.bodySmall?.copyWith(color: color)),
      ],
    );
  }
}
