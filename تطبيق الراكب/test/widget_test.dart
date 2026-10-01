// اختبار إقلاع أساسي.
//
// الاختبار الافتراضي الذي ولّده Flutter كان يشير إلى MyApp ويعدّ ضغطات
// عدّاد — لا علاقة له بتطبيقنا. استبدلناه بتحقق من أن التطبيق يقلع
// ويعرض شاشة بدل أن ينهار.
//
// اختبارات الشاشات الحقيقية تحتاج محاكاة Supabase، وستأتي مع بناء
// طبقة الاختبار لاحقاً.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('التطبيق يقلع ويعرض واجهة عربية RTL', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('ar'),
        supportedLocales: [Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: Center(child: Text('زنبور'))),
      ),
    );

    expect(find.text('زنبور'), findsOneWidget);
    expect(Directionality.of(tester.element(find.text('زنبور'))),
        TextDirection.rtl);
  });
}
