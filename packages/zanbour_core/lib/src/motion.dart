import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// رقمٌ يتدحرج إلى قيمته — `.odo` في المحاكي.
///
/// **العين ترى الانتقال فتقرؤه زيادة.** رقمٌ يُستبدل بآخر فجأةً يُقرأ
/// رقماً جديداً؛ ورقمٌ يصعد إليه يُقرأ «كسبتُ». وهذا هو الشعور الذي يريده
/// السائق حين تنتهي رحلته وتتحدّث أرباح يومه.
///
/// يبدأ من القيمة السابقة لا من الصفر: تحديثٌ من ١٨٬٠٠٠ إلى ٢٢٬٥٠٠ يتدحرج
/// الفرق وحده، ولا يعيد العدّ كلّه في كل بناء.
class ZCountUp extends StatefulWidget {
  const ZCountUp(
    this.value, {
    super.key,
    this.style,
    this.suffix = '',
    this.duration = const Duration(milliseconds: 900),
  });

  final num value;
  final TextStyle? style;
  final String suffix;
  final Duration duration;

  @override
  State<ZCountUp> createState() => _ZCountUpState();
}

class _ZCountUpState extends State<ZCountUp> {
  num _from = 0;

  @override
  void didUpdateWidget(ZCountUp old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _from = old.value;
  }

  /// فاصل الآلاف `٬` كما في المحاكي وكما يُكتب المال في العراق.
  static String _fmt(num n) {
    final s = n.round().abs().toString();
    final b = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write('٬');
      b.write(s[i]);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: _from.toDouble(), end: widget.value.toDouble()),
      duration: widget.duration,
      curve: const Cubic(0.2, 0.9, 0.25, 1),
      builder: (_, v, _) => Text(
        '${_fmt(v)}${widget.suffix}',
        style: (widget.style ?? const TextStyle())
            .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// طفوٌ خفيف صعوداً وهبوطاً — `@keyframes float` في المحاكي.
///
/// **يقول «أنا أعمل» بلا كلمة.** مركبةٌ ساكنة في بطاقةٍ كهرمانية تبدو
/// صورة؛ ومركبةٌ تطفو تبدو حيّة — والسائق يعرف من طرف عينه أنه متّصل.
/// وحين يُطفأ ([enabled] = false) تسكن.
class ZFloat extends StatefulWidget {
  const ZFloat({
    super.key,
    required this.child,
    this.enabled = true,
    this.distance = 6,
  });

  final Widget child;
  final bool enabled;
  final double distance;

  @override
  State<ZFloat> createState() => _ZFloatState();
}

class _ZFloatState extends State<ZFloat> {
  // **بمؤقّتٍ لا بـ`AnimationController`.** المتحكّم يطلب إطاراً مع كلّ
  // تحديثٍ للشاشة — ١٢٠ مرّة في الثانية — ويُعيد رسم رئيسية السائق كلّها،
  // خريطتها وزجاجها، بلا توقّف (انظر `ZMeshBackground`). وطفوُ ستّة بكسلات
  // في ثلاث ثوانٍ يبدو ناعماً بثلاثين.
  static const _step = Duration(milliseconds: 33);
  static const _period = 3200;

  final _y = ValueNotifier<double>(0);
  final _clock = Stopwatch();
  Timer? _timer;
  ValueListenable<TickerModeData>? _visible;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = TickerMode.getValuesNotifier(context);
    if (!identical(v, _visible)) {
      _visible?.removeListener(_sync);
      _visible = v..addListener(_sync);
    }
    _sync();
  }

  @override
  void didUpdateWidget(ZFloat old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.enabled && (_visible?.value.enabled ?? true);
    if (run && _timer == null) {
      _clock.start();
      _timer = Timer.periodic(_step, (_) {
        // ذهابٌ وإيابٌ: ٠ → ١ → ٠ كلّ ضعفِ المدّة، بمنحنى ناعم.
        final p = (_clock.elapsedMilliseconds % (_period * 2)) / _period;
        _y.value = Curves.easeInOut.transform(p <= 1 ? p : 2 - p);
      });
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _clock.stop();
      if (!widget.enabled) _y.value = 0; // يسكن في مكانه حين يُطفأ
    }
  }

  @override
  void dispose() {
    _visible?.removeListener(_sync);
    _timer?.cancel();
    _y.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: _y,
      builder: (_, y, child) => Transform.translate(
        offset: Offset(0, -widget.distance * y),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// ظهورٌ متتابع — `.rv` في المحاكي: كلّ عنصرٍ يرتفع ١٦ بكسلاً ويظهر،
/// متأخّراً عن سابقه ٥٥ ملّي ثانية.
///
/// **الترتيب يقود العين.** قائمةٌ تظهر دفعةً واحدة تُقرأ كتلة؛ وقائمةٌ
/// يظهر أولها أوّلاً تقول للعين من أين تبدأ.
class ZRise extends StatelessWidget {
  const ZRise({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    final delay = (index.clamp(0, 9)) * 55;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 340 + delay),
      curve: Interval(delay / (340 + delay), 1,
          curve: const Cubic(0.22, 0.9, 0.3, 1)),
      builder: (_, t, c) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: c),
      ),
      child: child,
    );
  }
}

/// أيقونةٌ في مربّعٍ كهرمانيّ — الخيار «ب» الذي اختاره علي.
///
/// **أيقونةٌ ثابتة لا إيموجي.** الإيموجي يتغيّر شكله بين سامسونغ وشاومي
/// والآيفون، ولا يأخذ لون التطبيق ولا يتبدّل في الداكن. والمربّع يعطي
/// القائمة نظام المحاكي: كلّ سطرٍ يبدأ بعلامةٍ ملوّنة تُقرأ قبل النصّ.
class ZIconTile extends StatelessWidget {
  const ZIconTile(
    this.icon, {
    super.key,
    this.size = 36,
    this.color,
    this.child,
  });

  final IconData? icon;
  final double size;

  /// لونٌ دلاليّ بدل الكهرماني — أخضر لـ«مقبول»، أحمر لـ«مرفوض».
  final Color? color;

  /// محتوى بدل الأيقونة — مجسّم المركبة مثلاً.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final c = color ?? z.amberDeep;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color == null ? z.amberWash : c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: child ?? Icon(icon, size: size * 0.56, color: c),
    );
  }
}

/// قصاصاتٌ ملوّنة تتساقط مرّةً واحدة — `.conf` في المحاكي.
///
/// **مرّةً لا تكراراً.** الاحتفال لحظة؛ وقصاصاتٌ تتساقط بلا نهاية تصير
/// ضجيجاً فوق نموذج التقييم. تنتهي في أقل من ثانيتين وتختفي من الرسم.
///
/// **ولا تعترض لمسة.** طبقةٌ فوق الشاشة لا تحت الأصابع — `IgnorePointer`.
class ZConfetti extends StatefulWidget {
  const ZConfetti({super.key, this.count = 42});

  final int count;

  @override
  State<ZConfetti> createState() => _ZConfettiState();
}

class _ZConfettiState extends State<ZConfetti>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..forward();

  // بذرةٌ ثابتة لكلّ قصاصة: الموضع والانحراف والدوران واللون.
  late final List<List<double>> _bits = List.generate(widget.count, (i) {
    double r(int k) => ((i * 9301 + k * 49297 + 233280) % 233280) / 233280;
    return [r(1), r(2), r(3), r(4), r(5)];
  });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final colors = [z.amber, z.amber2, z.ok, const Color(0xFFFF8A3D),
        const Color(0xFF4DA3FF)];
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => _c.isCompleted
            ? const SizedBox.shrink()
            : CustomPaint(
                size: Size.infinite,
                painter: _ConfettiPainter(_c.value, _bits, colors),
              ),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.t, this.bits, this.colors);
  final double t;
  final List<List<double>> bits;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final fall = Curves.easeIn.transform(t);
    for (var i = 0; i < bits.length; i++) {
      final b = bits[i];
      final x = b[0] * size.width + (b[1] - 0.5) * 80 * t;
      final y = -20 + b[2] * size.height * 0.25 + fall * size.height * 0.85;
      final paint = Paint()
        ..color = colors[i % colors.length]
            .withValues(alpha: (1 - t).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate((b[3] * 2 - 1) * 11 * t);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: 8, height: 14),
            const Radius.circular(2)),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
