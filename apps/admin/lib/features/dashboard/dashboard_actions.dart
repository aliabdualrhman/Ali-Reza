import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web/web.dart' as web;

import '../../core/admin_repository.dart';
import 'dashboard_page.dart';

/// تصفير اللوحة وتصديرها — كلاهما خلف رمز المدير.
///
/// **ولماذا رمزٌ إن كان داخلاً بحساب مشرف أصلاً؟** لأن الجلسة تبقى
/// مفتوحة على شاشةٍ تُترك، وموظفٌ يمرّ باللوحة يستطيع أن يصفّرها بضغطة
/// أو ينزّل أرقام الشركة كاملةً. والرمز يجعل الفعل قصداً لا صدفة.
///
/// **والرمز لا يُقارَن هنا.** يُرسَل إلى القاعدة فتقارنه بمُجزَّئه —
/// فملفّ اللوحة يُنزَّل في متصفّح أيّ زائر، وأيّ نصٍّ فيه يُقرأ.
Future<String?> _askCode(BuildContext context, String action) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(action),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('اكتب رمز المدير للمتابعة.'),
          const SizedBox(height: 14),
          TextField(
            controller: ctrl,
            autofocus: true,
            obscureText: true,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('تراجع'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text),
          child: const Text('متابعة'),
        ),
      ],
    ),
  );
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// **تحذيرٌ قبل الرمز لا بعده.** من يُطلب منه رمزٌ أولاً يظنّ الفعل
/// إجراءً روتينياً، فيكتبه ثم يفاجأ.
Future<void> resetDashboard(BuildContext context, WidgetRef ref) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تصفير اللوحة'),
      content: const Text(
          'تبدأ الأرقام من الآن: الرحلات والعمولات والرصيد المولَّد '
          'والمعبَّأ.\n\n'
          'ولا يُحذف شيء — البيانات تبقى في القاعدة، واللوحة وحدها '
          'تنسى ما قبل هذه اللحظة. ويمكنك التراجع.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error),
          child: const Text('صفّر اللوحة'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return;

  final code = await _askCode(context, 'تصفير اللوحة');
  if (code == null || code.isEmpty || !context.mounted) return;

  try {
    await ref.read(adminRepositoryProvider).resetDashboard(code);
    ref.invalidate(dashboardProvider);
    if (context.mounted) _toast(context, 'صُفّرت اللوحة — تبدأ الأرقام من الآن');
  } catch (e) {
    if (context.mounted) _toast(context, _msg(e));
  }
}

Future<void> undoReset(BuildContext context, WidgetRef ref) async {
  final code = await _askCode(context, 'إلغاء التصفير');
  if (code == null || code.isEmpty || !context.mounted) return;

  try {
    await ref.read(adminRepositoryProvider).undoDashboardReset(code);
    ref.invalidate(dashboardProvider);
    if (context.mounted) _toast(context, 'عادت الأرقام كاملةً');
  } catch (e) {
    if (context.mounted) _toast(context, _msg(e));
  }
}

/// تنزيل الرحلات ملفَّ إكسل.
///
/// **CSV بفاصلة منقوطة و«علامة الترتيب».** إكسل العربي يفصل الأعمدة
/// بالفاصلة المنقوطة لا بالفاصلة، ويقرأ الملف بترميز النظام ما لم تبدأ
/// الأحرف الثلاثة (BOM) — وبدونها تتحوّل العربية إلى رموز.
Future<void> exportDashboard(BuildContext context, WidgetRef ref) async {
  final code = await _askCode(context, 'تنزيل البيانات');
  if (code == null || code.isEmpty || !context.mounted) return;

  try {
    final rows = await ref.read(adminRepositoryProvider).exportTrips(code);
    if (rows.isEmpty) {
      if (context.mounted) _toast(context, 'لا توجد رحلات بعد نقطة الصفر');
      return;
    }

    final headers = rows.first.keys.toList();
    final buf = StringBuffer();
    buf.writeln(headers.map(_cell).join(';'));
    for (final r in rows) {
      buf.writeln(headers.map((h) => _cell(r[h])).join(';'));
    }

    // ﻿ أولاً — انظر أعلاه.
    final bytes = utf8.encode('﻿$buf');
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);

    final a = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = 'zanbour-trips-${_stamp()}.csv';
    a.click();
    web.URL.revokeObjectURL(url);

    if (context.mounted) _toast(context, 'نُزّلت ${rows.length} رحلة');
  } catch (e) {
    if (context.mounted) _toast(context, _msg(e));
  }
}

/// **الاقتباس إلزاميّ لا تجميليّ.** عنوانٌ فيه فاصلة منقوطة يكسر
/// الأعمدة كلها، واسمٌ فيه علامة اقتباس يكسر الصفّ.
String _cell(Object? v) {
  final s = '${v ?? ''}'.replaceAll('"', '""');
  return '"$s"';
}

String _stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}';
}

String _msg(Object e) {
  final m = RegExp(r'message:\s*([^,)]+)').firstMatch('$e');
  return m?.group(1)?.trim() ?? '$e';
}
