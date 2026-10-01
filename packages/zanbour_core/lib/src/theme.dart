import 'package:flutter/material.dart';

import 'mesh_background.dart';

/// هوية زنبور البصرية — **مأخوذةٌ من «محاكي زنبور» رقماً برقم.**
///
/// كل لونٍ ونصف قطرٍ ومسافةٍ هنا له مقابلٌ في متغيّرات `:root` في
/// المحاكي، بالاسم نفسه تقريباً (`--amber-wash` ← [ZColors.amberWash]).
/// فمن أراد أن يعرف لماذا زرٌّ ما بهذا الشكل، يفتح المحاكي ويجد الجواب.
///
/// **ولماذا لوحةٌ مكتوبة لا `ColorScheme.fromSeed`؟** البذرة تشتقّ درجاتها
/// بنفسها، فتخرج خلفيةٌ رماديةٌ باردة وأزرارٌ صفراءُ باهتة لا تشبه شيئاً
/// ممّا وافق عليه علي. والمكتوبة تعطي ما في المحاكي بالضبط.
class ZanbourTheme {
  ZanbourTheme._();

  static const Color amber = Color(0xFFF5B301);
  static const Color ink = Color(0xFF1A1611);

  /// ألوان دلالية — قيم المحاكي في الوضع الفاتح.
  ///
  /// **ثابتةٌ عمداً** لأن سبعاً وعشرين شاشة تقرؤها `const`. وفي الداكن
  /// تُقرأ من [ZColors] (`context.z.ok` …) — انظر التعليق هناك.
  static const Color success = Color(0xFF1B7A3E);
  static const Color warning = Color(0xFFB35A00);
  static const Color danger = Color(0xFFC0281F);

  /// خطّ الواجهة — **IBM Plex Sans Arabic**، خطّ المحاكي.
  ///
  /// رُسم للواجهات لا للكتب: ارتفاعاتٌ متساوية وفراغاتٌ واسعة تبقى
  /// مقروءةً بحجم ١٢ على شاشة جوّالٍ تحت الشمس. ويُشحن مع التطبيق لا
  /// يُنزَّل — انظر `pubspec.yaml` في التطبيقين.
  static const String fontFamily = 'IBMPlexSansArabic';

  // ---- أنصاف الأقطار والمسافات — `--r-*` و`--s*` في المحاكي ----
  static const double rSm = 10;
  static const double r = 14;
  static const double rLg = 20;
  static const double rXl = 26;

  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;

  static ThemeData _base(ZColors z, Brightness b) {
    final scheme = ColorScheme(
      brightness: b,
      primary: z.amber,
      onPrimary: z.onAmber,
      primaryContainer: z.amberWash,
      onPrimaryContainer: z.amberDeep,
      secondary: z.amberDeep,
      onSecondary: b == Brightness.light ? Colors.white : z.onAmber,
      secondaryContainer: z.amberWash,
      onSecondaryContainer: z.amberDeep,
      tertiary: z.warn,
      onTertiary: Colors.white,
      error: z.bad,
      onError: Colors.white,
      errorContainer: z.bad.withValues(alpha: 0.12),
      onErrorContainer: z.bad,
      surface: z.surface,
      onSurface: z.ink,
      onSurfaceVariant: z.inkDim,
      surfaceContainerLowest: z.surface,
      surfaceContainerLow: z.surface,
      surfaceContainer: z.surface2,
      surfaceContainerHigh: z.surface2,
      surfaceContainerHighest: z.surface2,
      outline: z.inkDim.withValues(alpha: 0.7),
      outlineVariant: z.line,
      inverseSurface: z.ink,
      onInverseSurface: z.surface,
      inversePrimary: z.amberDeep,
      shadow: Colors.black,
      scrim: Colors.black,
      surfaceTint: Colors.transparent,
    );

    RoundedRectangleBorder rr(double r) =>
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

    OutlineInputBorder field(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(r),
          borderSide: BorderSide(color: c, width: w),
        );

    final base = b == Brightness.light
        ? Typography.material2021().black
        : Typography.material2021().white;
    final text = base.apply(
      fontFamily: fontFamily,
      bodyColor: z.ink,
      displayColor: z.ink,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      extensions: [z],
      // **الخطّ على مستوى السمة وحدها.** فتأخذه الشاشات كلّها بلا أن نلمس
      // واحدةً منها.
      fontFamily: fontFamily,
      textTheme: text.copyWith(
        // `h1.t` في المحاكي: ٢٥ عريضاً بتباعدٍ سالب خفيف.
        headlineSmall: text.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        bodySmall: text.bodySmall?.copyWith(color: z.inkDim, height: 1.55),
      ),
      // **شفّافةٌ لتظهر الخلفية الحيّة تحتها.** والخلفية نفسها تُرسم في
      // انتقال الصفحة ([_ZSlideTransition]) لا في كل شاشة — فتأخذها الشاشات
      // كلّها بلا أن نلمس واحدة، وكلُّ صفحةٍ معتمةٌ بخلفيتها فلا تُرى
      // صفحتان متراكبتان أثناء الانتقال.
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: z.bg,
      dividerColor: z.line,
      splashFactory: InkSparkle.splashFactory,

      // حجم لمس أكبر من الافتراضي: كثير من مستخدمينا يضغطون بيد واحدة
      // وهم واقفون في الشارع، لا بإصبعين على مكتب.
      materialTapTargetSize: MaterialTapTargetSize.padded,

      // **دخول الشاشة بانزلاقٍ قصير وتلاشٍ** — `@keyframes slide` في المحاكي.
      // **كلّ المنصّات لا أندرويد وآيفون وحدهما.** الخلفية الحيّة تُرسم في
      // هذا الانتقال؛ ومنصّةٌ تُنسى هنا تفتح شاشاتها بخلفيةٍ بيضاء فارغة —
      // وقد وقع ذلك في معاينة الويب على ويندوز.
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: _ZSlideTransition(),
        TargetPlatform.iOS: _ZSlideTransition(),
        TargetPlatform.windows: _ZSlideTransition(),
        TargetPlatform.macOS: _ZSlideTransition(),
        TargetPlatform.linux: _ZSlideTransition(),
        TargetPlatform.fuchsia: _ZSlideTransition(),
      }),

      appBarTheme: AppBarTheme(
        // **شفّافٌ حتى يمرّ المحتوى تحته، ثم زجاجٌ معتمٌ قليلاً.** شريطٌ
        // بلون الخلفية الثابت يقطع الخلفية الحيّة بشريطٍ ساكن؛ وشفّافٌ
        // دائماً يجعل العنوان يتراكب مع القائمة حين تُمرَّر.
        backgroundColor: WidgetStateColor.resolveWith((s) =>
            s.contains(WidgetState.scrolledUnder)
                ? z.bg.withValues(alpha: 0.94)
                : Colors.transparent),
        foregroundColor: z.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: z.ink,
        ),
      ),

      // `.field .box` — سطحٌ ثانٍ بحدٍّ رفيع، وحدٌّ كهرمانيّ عند التركيز.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: z.surface2,
        border: field(z.line),
        enabledBorder: field(z.line),
        disabledBorder: field(z.line.withValues(alpha: 0.5)),
        focusedBorder: field(z.amber, 1.6),
        errorBorder: field(z.bad, 1.4),
        focusedErrorBorder: field(z.bad, 1.8),
        labelStyle: TextStyle(color: z.inkDim, fontWeight: FontWeight.w600),
        floatingLabelStyle:
            TextStyle(color: z.amberDeep, fontWeight: FontWeight.w700),
        hintStyle: TextStyle(color: z.inkDim.withValues(alpha: 0.7)),
        helperStyle: TextStyle(color: z.inkDim, fontSize: 12),
        prefixIconColor: z.inkDim,
        suffixIconColor: z.inkDim,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),

      // `.btn` — كهرمانيّ ممتلئ، عريض، ١٦، نصف قطر ١٤.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: z.amber,
          foregroundColor: z.onAmber,
          disabledBackgroundColor: z.line,
          disabledForegroundColor: z.inkDim,
          minimumSize: const Size.fromHeight(54),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: rr(r),
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
        ),
      ),

      // `.btn.ghost` — شفّاف بحدٍّ ١٫٥.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: z.ink,
          minimumSize: const Size.fromHeight(54),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          side: BorderSide(color: z.line, width: 1.5),
          shape: rr(r),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: z.amberDeep,
          shape: rr(r),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: z.ink),
      ),

      // `.card` — سطحٌ أبيض، حدٌّ رفيع، نصف قطر ٢٠، بلا ظلّ.
      cardTheme: CardThemeData(
        elevation: 0,
        color: z.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rLg),
          side: BorderSide(color: z.line),
        ),
        margin: EdgeInsets.zero,
      ),

      // `.chip` — حبّةٌ على السطح الثاني؛ المختارة كهرمانيةٌ باهتة.
      chipTheme: ChipThemeData(
        backgroundColor: z.surface2,
        selectedColor: z.amberWash,
        disabledColor: z.surface2,
        side: BorderSide(color: z.line),
        shape: const StadiumBorder(),
        labelStyle: TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
          fontSize: 13,
          color: z.ink,
        ),
        secondaryLabelStyle: TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w700,
          fontSize: 13,
          color: z.amberDeep,
        ),
        checkmarkColor: z.amberDeep,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? z.amber : z.surface2),
          foregroundColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? z.onAmber : z.inkDim),
          side: WidgetStatePropertyAll(BorderSide(color: z.line)),
          textStyle: const WidgetStatePropertyAll(TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w700,
          )),
        ),
      ),

      // `.toggle` — مسارٌ كهرمانيّ ومقبضٌ أبيض، بلا حدّ.
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) {
            return z.line.withValues(alpha: 0.5);
          }
          return s.contains(WidgetState.selected) ? z.amber : z.line;
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? z.amber : Colors.transparent),
        checkColor: WidgetStatePropertyAll(z.onAmber),
        side: BorderSide(color: z.inkDim, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),

      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? z.amber : z.inkDim),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: z.amber,
        linearTrackColor: z.surface2,
        circularTrackColor: Colors.transparent,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: z.amberDeep,
        textColor: z.ink,
        shape: rr(r),
      ),

      dividerTheme: DividerThemeData(color: z.line, thickness: 1, space: 1),

      // `.sheet` — نصف قطر ٢٦ من الأعلى.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: z.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: z.line,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(rXl)),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: z.surface,
        surfaceTintColor: Colors.transparent,
        shape: rr(rLg),
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: z.ink,
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: z.ink,
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: z.bg,
          fontWeight: FontWeight.w600,
        ),
        shape: rr(r),
      ),

      // شريط التنقّل السفلي — `.nav` في المحاكي: زجاجيّ، والنشط كهرمانيّ.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: z.amberWash,
        indicatorShape: rr(r),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontFamily: fontFamily,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: s.contains(WidgetState.selected) ? z.amberDeep : z.inkDim,
            )),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected) ? z.amberDeep : z.inkDim,
            )),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: z.ink,
          borderRadius: BorderRadius.circular(rSm),
        ),
        textStyle: TextStyle(fontFamily: fontFamily, color: z.bg),
      ),
    );
  }

  static ThemeData get light => _base(ZColors.light, Brightness.light);
  static ThemeData get dark => _base(ZColors.dark, Brightness.dark);
}

/// ألوان المحاكي التي لا مكان لها في `ColorScheme`.
///
/// **تُقرأ هكذا:** `context.z.amberWash`. وتتبدّل وحدها بين الفاتح والداكن
/// لأنها معلّقةٌ على السمة لا مكتوبةٌ في الشاشة.
///
/// **ولماذا `ok`/`warn`/`bad` هنا وثوابتُها في [ZanbourTheme] أيضاً؟** الثوابت
/// قيمُ الفاتح وتبقى لأن شاشاتٍ تقرؤها `const`؛ وهذه تتبع الوضع. أخضرُ
/// الفاتح (#1B7A3E) يغرق في خلفيةٍ شبه سوداء، فالداكن يأخذ #4ADE80.
@immutable
class ZColors extends ThemeExtension<ZColors> {
  const ZColors({
    required this.amber,
    required this.amber2,
    required this.amberDeep,
    required this.amberWash,
    required this.onAmber,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.ink,
    required this.inkDim,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.glass,
    required this.glassLine,
  });

  final Color amber;
  final Color amber2;
  final Color amberDeep;
  final Color amberWash;
  final Color onAmber;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color line;
  final Color ink;
  final Color inkDim;
  final Color ok;
  final Color warn;
  final Color bad;
  final Color glass;
  final Color glassLine;

  static const light = ZColors(
    amber: Color(0xFFF5B301),
    amber2: Color(0xFFFFD35C),
    amberDeep: Color(0xFF8A6200),
    amberWash: Color(0xFFFFF4D6),
    onAmber: Color(0xFF241A00),
    bg: Color(0xFFEFEBE3),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF6F1E7),
    line: Color(0xFFE3DACA),
    ink: Color(0xFF1A1611),
    inkDim: Color(0xFF6C6458),
    ok: Color(0xFF1B7A3E),
    warn: Color(0xFFB35A00),
    bad: Color(0xFFC0281F),
    glass: Color(0x9EFFFFFF), // rgba(255,255,255,.62)
    glassLine: Color(0xB3FFFFFF), // rgba(255,255,255,.7)
  );

  static const dark = ZColors(
    amber: Color(0xFFFFC93C),
    amber2: Color(0xFFFFE08A),
    amberDeep: Color(0xFFFFC93C),
    amberWash: Color(0xFF2C2417),
    onAmber: Color(0xFF241A00),
    bg: Color(0xFF0B0A08),
    surface: Color(0xFF181511),
    surface2: Color(0xFF221E19),
    line: Color(0xFF37312A),
    ink: Color(0xFFF6F1E7),
    inkDim: Color(0xFF9A9286),
    ok: Color(0xFF4ADE80),
    warn: Color(0xFFFBBF24),
    bad: Color(0xFFF87171),
    glass: Color(0x941E1A14), // rgba(30,26,20,.58)
    glassLine: Color(0x1AFFFFFF), // rgba(255,255,255,.10)
  );

  @override
  ZColors copyWith() => this;

  @override
  ZColors lerp(ZColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return ZColors(
      amber: l(amber, other.amber),
      amber2: l(amber2, other.amber2),
      amberDeep: l(amberDeep, other.amberDeep),
      amberWash: l(amberWash, other.amberWash),
      onAmber: l(onAmber, other.onAmber),
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surface2: l(surface2, other.surface2),
      line: l(line, other.line),
      ink: l(ink, other.ink),
      inkDim: l(inkDim, other.inkDim),
      ok: l(ok, other.ok),
      warn: l(warn, other.warn),
      bad: l(bad, other.bad),
      glass: l(glass, other.glass),
      glassLine: l(glassLine, other.glassLine),
    );
  }
}

extension ZColorsX on BuildContext {
  /// ألوان المحاكي للوضع الحالي — `context.z.amberWash`.
  ZColors get z =>
      Theme.of(this).extension<ZColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? ZColors.dark
          : ZColors.light);
}

/// انتقالٌ بين الشاشات — `@keyframes slide` في المحاكي: انزلاقُ ١٤ بكسلاً
/// مع تلاشٍ، في ٣٢٠ ملّي ثانية بمنحنًى ينطلق سريعاً ويستقرّ ببطء.
///
/// **قصيرٌ عمداً.** الانتقال الافتراضي في أندرويد يُكبّر الشاشة كلّها،
/// ويبدو ثقيلاً حين يتنقّل السائق بين العرض والرحلة عشرين مرة في اليوم.
class _ZSlideTransition extends PageTransitionsBuilder {
  const _ZSlideTransition();

  static const _curve = Cubic(0.22, 0.9, 0.3, 1);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final a = CurvedAnimation(parent: animation, curve: _curve);
    // الاتجاه من «البداية»: من اليمين في العربية.
    final dx = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    return FadeTransition(
      opacity: a,
      child: AnimatedBuilder(
        animation: a,
        builder: (_, c) => Transform.translate(
          offset: Offset(dx * 14 * (1 - a.value), 0),
          child: c,
        ),
        child: ZMeshBackground(child: child),
      ),
    );
  }
}
