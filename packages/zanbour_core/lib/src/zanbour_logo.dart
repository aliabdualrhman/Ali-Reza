import 'package:flutter/material.dart';

/// شعار زنبور المؤقت.
///
/// أيقونة دراجة داخل دائرة بلون الهوية. تُستبدل بشعار مصمَّم قبل الإطلاق،
/// لكنها تؤدي الغرض الآن ولا تعطّل بناء بقية الشاشات.
class ZanbourLogo extends StatelessWidget {
  const ZanbourLogo({super.key, this.size = 96, this.showName = true});

  final double size;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.two_wheeler,
            size: size * 0.56,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        if (showName) ...[
          const SizedBox(height: 12),
          Text(
            'زنبور',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ],
    );
  }
}
