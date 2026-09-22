import 'package:flutter/material.dart';

/// سمة لوحة التحكم.
///
/// تشترك مع التطبيقين في لون الهوية، لكنها **لا تستعمل `zanbour_core`**:
/// تلك الحزمة تعتمد `geolocator` و`http` وحزماً لا معنى لها في لوحة ويب،
/// وربطها هنا يجرّ تبعيات ثقيلة بلا فائدة.
///
/// وسمة اللوحة تختلف عمداً عن سمة الجوال: كثافة أعلى وحشوات أضيق. اللوحة
/// تُستعمل بفأرة على شاشة عريضة، والتطبيق بإبهام على هاتف في الشارع.
class AdminTheme {
  AdminTheme._();

  static const Color amber = Color(0xFFF5B301);
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFE65100);
  static const Color danger = Color(0xFFC62828);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: amber,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.comfortable,

      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 46),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),

      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        headingTextStyle: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  static ThemeData get light => _base(Brightness.light);
  static ThemeData get dark => _base(Brightness.dark);
}
