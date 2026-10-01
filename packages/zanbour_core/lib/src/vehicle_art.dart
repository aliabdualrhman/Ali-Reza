import 'package:flutter/material.dart';

/// مجسّم مركبة السائق — دراجة أو تكتك أو ستوتة، بخطّ المحاكي.
///
/// **يُرسم لا يُحمَّل.** صورةٌ لكل مركبة تعني ثلاثة ملفّات بثلاث كثافات
/// شاشة، وتتشوّه حين تُكبَّر، ولا تأخذ لون السمة في الوضع الداكن. والرسم
/// بالخطوط يأخذ أيّ لونٍ وأيّ حجمٍ بلا ملفٍّ واحد.
///
/// والقياسات منقولةٌ من SVG المعتمد (عرض ١٢٠ × ارتفاع ٧٦) كما وافق عليها
/// علي، فالمجسّم هنا هو ما رآه في المعاينة.
class ZVehicleArt extends StatelessWidget {
  const ZVehicleArt({
    super.key,
    required this.kind,
    this.width = 104,
    this.color,
    this.background,
  });

  /// `bike` · `tuktuk` · `stoota` — قيم `vehicle_kind` في القاعدة.
  /// وأيّ قيمةٍ أخرى (أو `null`) تُرسم دراجة: الأكثر بين السائقين.
  final String? kind;
  final double width;
  final Color? color;

  /// لون ما خلف العجلات — تُملأ به ليخفي الخطوط التي تمرّ تحتها.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? Colors.black;
    return SizedBox(
      width: width,
      height: width * 76 / 120,
      child: CustomPaint(
        painter: _VehiclePainter(kind ?? 'bike', c, background),
      ),
    );
  }
}

class _VehiclePainter extends CustomPainter {
  _VehiclePainter(this.kind, this.color, this.bg);

  final String kind;
  final Color color;
  final Color? bg;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 120, size.height / 76);

    Paint stroke(double w, {double opacity = 1}) => Paint()
      ..color = color.withValues(alpha: color.a * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;

    void wheel(double x, double y, double r, double w, {bool hub = false}) {
      if (bg != null) canvas.drawCircle(Offset(x, y), r, Paint()..color = bg!);
      canvas.drawCircle(Offset(x, y), r, stroke(w));
      if (hub) canvas.drawCircle(Offset(x, y), 3.5, fill);
    }

    switch (kind) {
      case 'tuktuk':
        canvas.drawPath(
          Path()
            ..moveTo(16, 52)
            ..lineTo(16, 24)
            ..quadraticBezierTo(16, 12, 28, 12)
            ..lineTo(78, 12)
            ..quadraticBezierTo(88, 12, 91, 22)
            ..lineTo(98, 46),
          stroke(4),
        );
        canvas.drawPath(
          Path()
            ..moveTo(12, 52)
            ..lineTo(106, 52)
            ..lineTo(106, 46)
            ..lineTo(98, 44),
          stroke(4),
        );
        canvas.drawLine(const Offset(62, 12), const Offset(62, 52), stroke(4));
        canvas.drawRect(const Rect.fromLTRB(24, 22, 54, 40), stroke(3));
        canvas.drawLine(const Offset(82, 28), const Offset(92, 28), stroke(4));
        wheel(34, 60, 11, 4);
        wheel(96, 61, 9, 4);

      case 'stoota':
        canvas.drawPath(
          Path()
            ..moveTo(8, 28)
            ..lineTo(8, 50)
            ..lineTo(60, 50)
            ..lineTo(60, 28),
          stroke(4),
        );
        canvas.drawLine(
            const Offset(14, 36), const Offset(54, 36), stroke(2.5, opacity: .7));
        canvas.drawPath(
          Path()
            ..moveTo(60, 46)
            ..lineTo(78, 46)
            ..lineTo(96, 60),
          stroke(4),
        );
        canvas.drawPath(
          Path()
            ..moveTo(96, 60)
            ..lineTo(86, 26)
            ..lineTo(78, 26),
          stroke(4),
        );
        canvas.drawLine(const Offset(64, 38), const Offset(78, 38), stroke(4));
        canvas.drawLine(const Offset(72, 38), const Offset(76, 24), stroke(4));
        canvas.drawCircle(const Offset(77, 15), 7, fill);
        wheel(28, 60, 11, 4);
        wheel(96, 60, 11, 4);

      default: // bike
        // الواقيان
        canvas.drawPath(
          Path()
            ..moveTo(16, 40)
            ..quadraticBezierTo(10, 44, 12, 52),
          stroke(3),
        );
        canvas.drawPath(
          Path()
            ..moveTo(86, 44)
            ..quadraticBezierTo(97, 37, 108, 45),
          stroke(3),
        );
        // الذراع الخلفي والمحرّك والعادم
        canvas.drawLine(const Offset(26, 57), const Offset(46, 50), stroke(4));
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              const Rect.fromLTWH(44, 42, 20, 13), const Radius.circular(3)),
          stroke(3.5),
        );
        canvas.drawLine(
            const Offset(48, 50), const Offset(60, 50), stroke(2, opacity: .7));
        canvas.drawPath(
          Path()
            ..moveTo(40, 60)
            ..lineTo(64, 61)
            ..lineTo(70, 58),
          stroke(3),
        );
        // الهيكل والخزّان والمقعد
        canvas.drawLine(const Offset(64, 44), const Offset(80, 32), stroke(4));
        final tank = Path()
          ..moveTo(50, 38)
          ..quadraticBezierTo(55, 27, 70, 28)
          ..quadraticBezierTo(78, 29, 80, 33)
          ..lineTo(76, 38)
          ..close();
        canvas.drawPath(tank, fill);
        canvas.drawPath(tank, stroke(3));
        canvas.drawPath(
          Path()
            ..moveTo(20, 37)
            ..quadraticBezierTo(32, 31, 50, 36),
          stroke(5.5),
        );
        // الشوكة والمقود والضوء
        canvas.drawLine(const Offset(81, 25), const Offset(96, 57), stroke(4.5));
        canvas.drawPath(
          Path()
            ..moveTo(76, 22)
            ..quadraticBezierTo(80, 19, 86, 21),
          stroke(4),
        );
        canvas.drawCircle(const Offset(89, 33), 3.8, fill);
        wheel(26, 57, 14, 4.5, hub: true);
        wheel(96, 57, 14, 4.5, hub: true);
    }
  }

  @override
  bool shouldRepaint(_VehiclePainter old) =>
      old.kind != kind || old.color != color || old.bg != bg;
}
