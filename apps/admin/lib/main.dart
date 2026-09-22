import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_router.dart';
import 'core/shell_push.dart';
import 'core/theme.dart';

/// سبب فشل الإقلاع إن وُجد.
String? bootError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await initializeDateFormatting('ar');

    // ---------------------------------------------------------------------
    // المفاتيح مضمّنة وقت الترجمة لا في ملف .env.
    //
    // السبب: هذه لوحة ويب. أي ملف نضعه بجانبها يستطيع أي زائر تنزيله
    // بكتابة مساره في المتصفح — فملف .env على الويب ليس سراً بأي معنى.
    //
    // ولا ضرر: المفتاح العام مصمَّم للنشر، وسياسات RLS هي الحماية
    // الفعلية. مستخدم عادي يفتح اللوحة لن يرى صفاً واحداً.
    //
    // تُمرَّر عند البناء:
    //   flutter build web --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
    // ---------------------------------------------------------------------
    const url = String.fromEnvironment('SUPABASE_URL');
    const key = String.fromEnvironment('SUPABASE_KEY');

    if (url.isEmpty || key.isEmpty) {
      bootError = 'لم تُمرَّر مفاتيح Supabase وقت البناء.\n'
          'استعمل --dart-define=SUPABASE_URL=... و --dart-define=SUPABASE_KEY=...';
    } else {
      await Supabase.initialize(url: url, publishableKey: key);
      // إشعارات المدير حين تُفتح اللوحة داخل تطبيق المدير
      ShellPush.start(Supabase.instance.client);
    }
  } catch (e) {
    bootError = e.toString();
  }

  runApp(const ProviderScope(child: AdminApp()));
}

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (bootError != null) return _BootError(message: bootError!);

    return MaterialApp.router(
      title: 'زنبور — لوحة التحكم',
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(routerProvider),

      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      theme: AdminTheme.light,
      darkTheme: AdminTheme.dark,
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AdminTheme.light,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 72),
                const SizedBox(height: 16),
                const Text('تعذّر تشغيل اللوحة',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                SelectableText(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
