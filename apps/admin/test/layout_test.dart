// رأس الصفحة على شاشة هاتف: لا شيء يخرج خارج الحدّ.
//
// هذا ما انكسر فعلاً: صفٌّ واحد فيه العنوان والمرشّح والبحث كان يدفع زر
// «كل الرحلات» خارج شاشة ٣٦٠ نقطة، فلا يبقى للمدير سبيل إليه — وبدت
// اللوحة كأنها لا تعرض الرحلات وهي تعرض الجارية وحدها.

import 'package:zanbour_admin/core/layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, Size size) => MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        locale: const Locale('ar'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(body: child),
        ),
      ),
    );

void main() {
  final phone = const Size(360, 800);
  final desktop = const Size(1440, 900);

  testWidgets('رأس الرحلات يلتفّ على الهاتف بلا فيضان', (tester) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final search = TextEditingController();
    addTearDown(search.dispose);

    await tester.pumpWidget(_wrap(
      Padding(
        padding: const EdgeInsets.all(14),
        child: PageHeader(
          title: 'الرحلات',
          actions: [
            FilterChoice<bool>(
              value: true,
              options: const [(true, 'الجارية'), (false, 'كل الرحلات')],
              onChanged: (_) {},
            ),
            SearchField(
              controller: search,
              width: 320,
              hint: 'رقم الرحلة أو عنوان',
              onSubmitted: (_) {},
            ),
          ],
        ),
      ),
      phone,
    ));

    expect(tester.takeException(), isNull);
    // المرشّح موجود ومرئي — لا مدفوعاً خارج الشاشة.
    expect(find.text('الجارية'), findsOneWidget);
  });

  testWidgets('المرشّح يبقى أزراراً مقطعية على الشاشة العريضة',
      (tester) async {
    tester.view.physicalSize = desktop;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(
      FilterChoice<bool?>(
        value: null,
        options: const [(false, 'غير مستعملة'), (true, 'مستعملة'), (null, 'الكل')],
        onChanged: (_) {},
      ),
      desktop,
    ));

    expect(find.byType(SegmentedButton<bool?>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('قيمة null تعني «الكل» ولا تُعرض فارغة على الهاتف',
      (tester) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(
      FilterChoice<bool?>(
        value: null,
        options: const [(false, 'غير مستعملة'), (true, 'مستعملة'), (null, 'الكل')],
        onChanged: (_) {},
      ),
      phone,
    ));

    expect(find.text('الكل'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('عرض الحوار لا يتجاوز شاشة الهاتف', (tester) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late double width;
    await tester.pumpWidget(_wrap(
      Builder(builder: (c) {
        width = Breaks.dialogWidth(c, 520);
        return const SizedBox();
      }),
      phone,
    ));

    expect(width, lessThan(360));
  });
}
