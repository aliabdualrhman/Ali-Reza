import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// رمز الرحلة كما يُقرأ ويُملى: `#10432`.
///
/// **رقم واحد يعرفه الثلاثة.** الراكب يشتكي من «رحلة ١٠٤٣٢»، والسائق يرى
/// الرقم نفسه في سجلّه، والمدير يبحث به في اللوحة. بغيره لا يبقى بين
/// الشكوى والسجلّ رابط إلا التاريخ والعنوان — وهما لا يكفيان حين يكون
/// للسائق ثلاث رحلات في الشارع نفسه.
String tripCode(Object? number) {
  final n = number is num ? number.toInt() : int.tryParse('$number');
  return n == null ? '—' : '#$n';
}

/// رمز الرحلة ظاهراً وقابلاً للنسخ بلمسة — لأنه يُلصق في محادثة الدعم.
class TripCodeBadge extends StatelessWidget {
  const TripCodeBadge({super.key, required this.number, this.compact = false});

  final Object? number;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = tripCode(number);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        await Clipboard.setData(
            ClipboardData(text: label.replaceAll('#', '')));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('نُسخ رمز الرحلة $label')),
          );
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 12, vertical: compact ? 3 : 7),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textDirection: TextDirection.ltr,
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            fontSize: compact ? 12 : 15,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
