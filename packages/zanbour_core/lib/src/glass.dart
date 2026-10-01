import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';


/// أسطحٌ زجاجية تطفو فوق ما تحتها.
///
/// **لماذا زجاجٌ لا لونٌ معتم؟** لأن شاشاتنا الرئيسية خرائطُ في جوهرها،
/// والسطح المعتم فوق خريطةٍ حيّة يقطعها فتبدو الشاشة شاشتين. والزجاج
/// يُبقي الشارع مرئياً تحته، فتُقرأ الطبقات على حقيقتها: لوحٌ يعلو
/// الخريطة لا جدارٌ يسدّها.
///
/// **والحدُّ الرفيع ليس زينة.** `BackdropFilter` وحده يجعل الحافّة تذوب
/// فيما تحتها فلا يُعرف أين يبدأ اللوح؛ والخطُّ الفاتح يرسمها كما ترسمها
/// حافّة الزجاج الحقيقي.

/// كم يضبّب الزجاج فعلاً — في مكانٍ واحد للتطبيقين.
///
/// **نصفُ ما يُطلب.** الألواح معتمةٌ بنسبة ٧٢–٨٦٪، فما وراءها لا يُرى إلا
/// خيالاً؛ والضبابية فوق ذلك لا تكاد تُلحظ، وثمنها كبير: فوق خريطةٍ تتحرّك
/// يُعاد حسابها مع كلّ إطار، لكلّ لوح. وكلفتها تكبر مع شدّتها. فنصفُها
/// يبقي الشكل نفسه للعين ويخفّف الإطار.
///
/// **ولا ضبابية إن طلب المستخدم «تقليل الحركة».** هذا ما يفعله أصحاب
/// الأجهزة الضعيفة؛ فيُعطى لوحاً أشدّ عتمةً بلا كلفة.
double zGlassSigma(BuildContext context, double requested) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
        ? 0
        : requested * 0.5;

/// يلفّ اللوح بالضبابية، أو يتركه بلا مرشّحٍ إن كانت صفراً.
Widget zGlassBlur(BuildContext context, double requested, Widget child) {
  final s = zGlassSigma(context, requested);
  if (s <= 0) return child;
  return BackdropFilter(
    filter: ImageFilter.blur(sigmaX: s, sigmaY: s),
    child: child,
  );
}

/// سطحٌ زجاجيّ بزوايا.
class ZGlass extends StatelessWidget {
  const ZGlass({
    super.key,
    required this.child,
    this.radius = 18,
    this.topOnly = false,
    this.blur = 22,
    this.opacity = 0.72,
    this.padding,
  });

  final Widget child;
  final double radius;
  final bool topOnly;
  final double blur;
  final double opacity;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = topOnly
        ? BorderRadius.vertical(top: Radius.circular(radius))
        : BorderRadius.circular(radius);

    final plain = zGlassSigma(context, blur) <= 0;

    return ClipRRect(
      borderRadius: shape,
      child: zGlassBlur(
        context,
        blur,
        DecoratedBox(
          decoration: BoxDecoration(
            // بلا ضبابيةٍ يُعتَّم اللوح أكثر، فيبقى مقروءاً فوق الخريطة.
            color: scheme.surface
                .withValues(alpha: plain ? (opacity + 0.18).clamp(0, 0.96) : opacity),
            borderRadius: shape,
            border: Border.all(
              color: scheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          child: padding == null
              ? child
              : Padding(padding: padding!, child: child),
        ),
      ),
    );
  }
}

/// غلافٌ زجاجيّ دائري — لأيقونةٍ أو زرٍّ يطفو فوق الخريطة.
///
/// **الشريط الشفّاف يبتلع أيقوناته:** الداكنة تختفي على الأسفلت الفاتح،
/// والفاتحة تختفي على الحدائق. والقرص يفصلها عمّا تحتها فتُرى على أيّ
/// خلفية — وهو ما تفعله تطبيقات الخرائط كلّها.
class ZGlassCircle extends StatelessWidget {
  const ZGlassCircle({super.key, required this.child, this.size = 40});

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ClipOval(
      child: zGlassBlur(
        context,
        14,
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.80),
            shape: BoxShape.circle,
            border: Border.all(
              color: scheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// بطاقةٌ زجاجية — بديلُ `Card` حيث تحتها شيءٌ يستحقّ أن يُرى.
///
/// **ولا تُستعمل على خلفيةٍ صمّاء.** الزجاج فوق لونٍ ثابت يبدو رمادياً
/// باهتاً بلا سبب؛ قيمتُه في أن يُظهر ما تحته.
class ZGlassCard extends StatelessWidget {
  const ZGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ZGlass(
      radius: 20,
      opacity: 0.66,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// قائمةٌ زجاجية — صفوفٌ يفصلها خطٌّ رفيع داخل سطحٍ واحد.
///
/// **سطحٌ واحد لا بطاقةٌ لكل صفّ.** البطاقات المتجاورة تصنع حوافَّ كثيرة
/// تُتعب العين؛ والسطح الواحد يجمعها ويجعل الفواصل هي التي تفرّق.
class ZGlassList extends StatelessWidget {
  const ZGlassList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];

    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(
          height: 1,
          thickness: 1,
          color: scheme.onSurface.withValues(alpha: 0.06),
        ));
      }
      rows.add(children[i]);
    }

    return ZGlass(
      radius: 20,
      opacity: 0.66,
      child: Material(
        color: Colors.transparent,
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    );
  }
}
