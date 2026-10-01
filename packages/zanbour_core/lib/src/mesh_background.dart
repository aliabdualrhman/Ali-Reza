import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// الخلفية الحيّة — `.mesh` في المحاكي: ثلاث بقعٍ لونية تنجرف ببطء.
///
/// **لماذا حيّة؟** الزجاج بلا معنى فوق سطحٍ ساكن؛ يُرى حين يتحرّك ما
/// تحته. والانجراف بطيءٌ (٢٦ ثانية ذهاباً) حتى لا يُلحَظ حركةً بل حياة.
///
/// **وكيف لا تأكل البطارية؟** اختار علي أن تكون «في كل مكان»، والسائق
/// يُبقي التطبيق مفتوحاً ساعات. فثلاثة قيود:
///   ١. **بلا ضبابيةٍ مرسومة.** المحاكي يضبّب بـ`blur(46px)` — أثقل ما في
///      الرسم. وهنا التدرّج الشعاعي نفسه ناعم الحواف، فلا فلتر.
///   ٢. **أربع لوحاتٍ في الثانية — بمؤقّتٍ لا بـ`Ticker`.** كان هنا
///      `Ticker` يرجع مبكّراً ليرسم «١٢ لوحة»، لكنّ الـ`Ticker` يطلب إطاراً
///      مع **كلّ** تحديثٍ للشاشة: ١٢٠ مرّة في الثانية على جوالٍ حديث.
///      فكان التطبيق يُعيد رسم الشاشة كلّها — والشريط الزجاجي فوقها —
///      بلا توقّفٍ والشاشة ساكنة، والعودة إليه تتقطّع. قِيس على جوال علي
///      (2026-10-01): كلُّ إطارٍ ٨–١٤ ملّي ثانية رسماً، وميزانه ٨٫٣.
///      والانجراف بكسلٌ واحد في الثانية، فأربعُ خطواتٍ ربعُ بكسلٍ لا تُرى.
///   ٣. **تتوقّف وحدها** حين تُغطّى الشاشة بأخرى (`TickerMode`) أو يخرج
///      التطبيق إلى الخلفية — فلا تُرسم خلفيةٌ لا يراها أحد.
class ZMeshBackground extends StatefulWidget {
  const ZMeshBackground({super.key, required this.child});

  final Widget child;

  @override
  State<ZMeshBackground> createState() => _ZMeshBackgroundState();
}

class _ZMeshBackgroundState extends State<ZMeshBackground>
    with WidgetsBindingObserver {
  final _t = ValueNotifier<double>(0);
  final _clock = Stopwatch();
  Timer? _timer;
  ValueListenable<TickerModeData>? _visible;
  bool _foreground = true;

  static const _period = 26000; // ملّي ثانية — ذهاباً
  static const _step = Duration(milliseconds: 250); // ٤ لوحات/ثانية

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `TickerMode` يُطفأ حين تعلو الشاشةَ شاشةٌ أخرى — نتبعه بلا Ticker.
    final v = TickerMode.getValuesNotifier(context);
    if (!identical(v, _visible)) {
      _visible?.removeListener(_sync);
      _visible = v..addListener(_sync);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final run = _foreground && (_visible?.value.enabled ?? true);
    if (run && _timer == null) {
      _clock.start();
      _timer = Timer.periodic(_step, (_) => _tick());
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _clock.stop();
    }
  }

  void _tick() {
    // ذهابٌ وإيابٌ ناعم: ٠ → ١ → ٠ كل ٥٢ ثانية.
    final p = (_clock.elapsedMilliseconds % (_period * 2)) / _period;
    _t.value = p <= 1 ? p : 2 - p;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _visible?.removeListener(_sync);
    _timer?.cancel();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _MeshPainter(_t, z, dark),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _MeshPainter extends CustomPainter {
  _MeshPainter(this.t, this.z, this.dark) : super(repaint: t);

  final ValueNotifier<double> t;
  final ZColors z;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = z.bg);

    // `@keyframes drift`: ٠٪ مكانه، ٥٠٪ (+٣٪، −٣٪) ×١٫١، ١٠٠٪ (−٣٪، +٣٪) ×١٫٠٥
    final v = Curves.easeInOut.transform(t.value);
    final dx = (v < 0.5 ? v * 2 * 0.03 : 0.03 - (v - 0.5) * 2 * 0.06) * w;
    final dy = (v < 0.5 ? -v * 2 * 0.03 : -0.03 + (v - 0.5) * 2 * 0.06) * h;
    final scale = v < 0.5 ? 1 + v * 2 * 0.1 : 1.1 - (v - 0.5) * 2 * 0.05;

    // شدّة الطبقة كلّها — `opacity:.55` في المحاكي، وأخفّ في الداكن حيث
    // يصرخ اللون على الأسود.
    final k = dark ? 0.32 : 0.55;

    void blob(double cx, double cy, double rx, double ry, Color c, double a) {
      final center = Offset(cx * w + dx, cy * h + dy);
      final rect = Rect.fromCenter(
          center: center, width: rx * w * 2 * scale, height: ry * h * 2 * scale);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [c.withValues(alpha: a * k), c.withValues(alpha: 0)],
          stops: const [0, 1],
        ).createShader(rect);
      canvas.drawRect(Offset.zero & size, paint);
    }

    blob(0.22, 0.26, 0.46, 0.36, z.amber, 0.62);
    blob(0.78, 0.18, 0.42, 0.34, const Color(0xFFFF8A3D), 0.46);
    blob(0.62, 0.82, 0.50, 0.40, const Color(0xFF4DA3FF), 0.34);
  }

  @override
  bool shouldRepaint(_MeshPainter old) => old.z != z || old.dark != dark;
}
