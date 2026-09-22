// اختبار إقلاع أساسي للوحة التحكم.
//
// **الاتجاه يأتي من مندوبي الترجمة لا من `locale` وحدها.** كان الاختبار
// يمرّر `locale: ar` بلا `localizationsDelegates` فيبقى الاتجاه LTR —
// يفحص شيئاً لا تفعله اللوحة الحقيقية.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('اللوحة تعرض واجهة عربية RTL', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('ar'),
        supportedLocales: [Locale('ar'), Locale('en')],
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: Center(child: Text('زنبور'))),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('زنبور'), findsOneWidget);
    expect(Directionality.of(tester.element(find.text('زنبور'))),
        TextDirection.rtl);
  });
}
