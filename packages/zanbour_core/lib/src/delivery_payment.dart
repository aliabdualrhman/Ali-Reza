import 'package:flutter/material.dart';

import 'theme.dart';

/// اتفاق طريقة الدفع في طلب المندوب — يختار كلٌّ من الطرفين، ويُثبَّت
/// حين يتطابقان (0091 `choose_delivery_payment`).
///
/// **في الحزمة المشتركة لا في أحد التطبيقين.** التاجر والمندوب يقفان
/// متقابلين ينظران إلى الشاشة نفسها؛ نسختان تفترقان في نصٍّ واحد تجعلان
/// «المندوب يدفع الآن» عند أحدهما شيئاً آخر عند الثاني.
///
/// **يُعرض الاختياران معاً.** من يرى أن المتجر اختار غير ما اختاره يعرف
/// أن عليهما أن يتكلّما، لا أن الزرّ معطوب.
class PaymentAgreement extends StatelessWidget {
  const PaymentAgreement({
    super.key,
    required this.trip,
    required this.mine,
    required this.theirs,
    required this.theirsLabel,
    required this.busy,
    required this.onChoose,
  });

  final Map<String, dynamic> trip;
  final String? mine;
  final String? theirs;
  final String theirsLabel;
  final bool busy;
  final void Function(String mode) onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goods = ((trip['goods_actual_iqd'] ?? 0) as num).round();
    final agreed = trip['pay_mode'] as String?;

    Widget option(String mode, String title, String detail) {
      final selected = mine == mode;
      final other = theirs == mode;
      return Card(
        color: selected ? theme.colorScheme.primaryContainer : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: busy ? null : () => onChoose(mode),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(detail, style: theme.textTheme.bodySmall),
                      if (other) ...[
                        const SizedBox(height: 4),
                        Text('✓ $theirsLabel اختار هذا',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: ZanbourTheme.success,
                                fontWeight: FontWeight.bold)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('طريقة الدفع — يختار كلٌّ منكما',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        option('prepay', 'المندوب يدفع الثمن الآن',
            'يدفع $goods دينار للمتجر، ويأخذه من المستلم'),
        option('after', 'المندوب يعيد الثمن بعد التسليم',
            'يأخذ الثمن من المستلم، ثم يسلّمه للمتجر'),
        const SizedBox(height: 6),
        if (agreed != null)
          Row(
            children: [
              const Icon(Icons.check_circle, color: ZanbourTheme.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text('اتفقتما — يمكن استلام الطلب',
                    style: TextStyle(
                        color: ZanbourTheme.success,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          )
        else if (mine != null && theirs != null && mine != theirs)
          Text('اختياركما مختلف — تفاهما ثم اختارا الخيار نفسه',
              style: TextStyle(color: theme.colorScheme.error))
        else if (mine != null)
          Text('بانتظار اختيار $theirsLabel',
              style: theme.textTheme.bodySmall),
      ],
    );
  }
}
