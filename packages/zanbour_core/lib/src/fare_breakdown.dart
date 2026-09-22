import 'package:flutter/material.dart';

/// تفصيل ما يدفعه الراكب — لا رقمٌ واحدٌ مبهم.
///
/// **الرقم الواحد كان يكفي في التوصيل ولا يكفي في التسوّق.** الراكب
/// الذي يرى «٤٠٠٠ دينار» على طلب تسوّق لا يعرف أثمن السلعة غالٍ أم
/// أجرة السائق، ولا كم منها يعود إلى المتجر — فيظنّ الأجرة أضعافها
/// ويشكو. والتفصيل يُنهي الشكوى قبل أن تبدأ.
///
/// **وسعر السلعة يتبدّل مرّةً واحدة في عمر الطلب:** يكتبه الراكب
/// تقديراً، ثم يستبدله السائق بما دفعه فعلاً في السوق. فالتسمية تتبدّل
/// معه — «تقريبي» ثم «فعلي» — وإلا ظنّ الراكب أننا غيّرنا الرقم عليه
/// خِلسةً.
class FareBreakdown extends StatelessWidget {
  const FareBreakdown({
    super.key,
    required this.fare,
    required this.total,
    this.discount = 0,
    this.creditUsed = 0,
    this.goods,
    this.goodsIsFinal = false,
    this.shopping = false,
    this.title,
    this.emphasise = true,
  });

  /// أجرة التوصيل وحدها.
  final double fare;

  /// المطلوب دفعه بعد كل خصم وإضافة.
  final double total;

  final double discount;
  final double creditUsed;

  /// ثمن البضاعة. `null` في رحلة الركاب.
  final double? goods;

  /// هل الثمن هو ما دفعه السائق فعلاً، أم تقدير الراكب؟
  final bool goodsIsFinal;

  final bool shopping;
  final String? title;

  /// هل يُبرز سطر المجموع؟ نُطفئه حين تكون البطاقة نفسها هي الإبراز.
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // **رحلة الركاب تبقى سطراً واحداً.** لا بضاعة فيها، والتفصيل بلا
    // ما يُفصَّل تعقيدٌ بلا فائدة.
    final rows = <Widget>[
      _line(theme, shopping ? 'أجرة التوصيل' : 'الأجرة', fare),
      if (shopping)
        _line(
          theme,
          goodsIsFinal ? 'ثمن السلعة (الفعلي)' : 'ثمن السلعة (تقريبي)',
          goods ?? 0,
        ),
      if (discount > 0) _line(theme, 'خصم الكوبون', -discount, good: true),
      if (creditUsed > 0) _line(theme, 'من رصيدك', -creditUsed, good: true),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Text(title!,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 10),
            ],
            ...rows,
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  // **«التقريبي» كلمةٌ تحمي.** ما دام السائق لم يشترِ
                  // فالرقم تخمين الراكب نفسه، وتقديمُه مؤكَّداً يجعل
                  // كلَّ فرقٍ بعده يبدو خيانة.
                  shopping && !goodsIsFinal ? 'المجموع التقريبي' : 'المجموع',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                Text(
                  '${total.round()} دينار',
                  style: (emphasise
                          ? theme.textTheme.headlineSmall
                          : theme.textTheme.titleLarge)
                      ?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(ThemeData theme, String label, double value,
      {bool good = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            '${value.round()} دينار',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: good ? Colors.green.shade700 : null,
            ),
          ),
        ],
      ),
    );
  }
}
