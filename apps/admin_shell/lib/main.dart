import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// قشرةٌ حول لوحة المدير.
///
/// **لا منطق فيها ولا بيانات.** اللوحة نفسها تبقى واحدة على الويب،
/// وهذا التطبيق نافذةٌ عليها. فما نُصلحه في اللوحة يصل هذا التطبيق
/// بلا بناءٍ ولا نشرٍ ولا مراجعة متجر — وهو أهمّ ما في هذا التصميم.
///
/// **والجلسة تبقى محفوظة.** Supabase يخزّنها في `localStorage`، وWebView
/// يحفظه بين التشغيلات — فلا يُطلب الدخول في كل فتحة.
const kAdminUrl = 'https://zanbour-admin.pages.dev';

void main() => runApp(const AdminShellApp());

class AdminShellApp extends StatelessWidget {
  const AdminShellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'زنبور — المدير',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD9A441),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      locale: const Locale('ar'),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      home: const AdminShell(),
    );
  }
}

class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  late final WebViewController _web;

  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();

    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFDF8F0))
      // **قناةٌ للتنزيل.** انظر `_downloadScript` أدناه.
      ..addJavaScriptChannel('ZanbourSave', onMessageReceived: _save)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() {
            _loading = true;
            _offline = false;
          }),
          onPageFinished: (_) async {
            await _web.runJavaScript(_downloadScript);
            // كل تحميلٍ للصفحة يمحو ما وضعناه فيها — فنعيده.
            await _injectToken();
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            // **الصفحة الرئيسية وحدها.** فشلُ صورةٍ أو ملفٍّ فرعيّ لا
            // يعني انقطاع الشبكة، وإظهار شاشة خطأ عنده يُخفي لوحةً
            // تعمل.
            if (e.isForMainFrame ?? true) {
              if (mounted) {
                setState(() {
                  _offline = true;
                  _loading = false;
                });
              }
            }
          },
          // **الروابط الخارجية تبقى داخل الشاشة.** لا شيء في اللوحة
          // يقصد موقعاً آخر، وما خرج عنها فهو خطأ أو تحويلٌ غير مقصود.
          onNavigationRequest: (r) => r.url.startsWith(kAdminUrl)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      )
      ..loadRequest(Uri.parse(kAdminUrl));

    _initPush();
  }

  // ---------------------------------------------------------------------------
  // الإشعارات
  // ---------------------------------------------------------------------------

  /// رمز هذا الهاتف عند Firebase.
  ///
  /// **التطبيق يملك الرمز، واللوحة تعرف صاحبه.** لا نعرف هنا من دخل
  /// اللوحة؛ فنضع الرمز في الصفحة، واللوحة (`core/shell_push.dart`)
  /// تسجّله باسم المدير الذي دخل. ومنها تصل إشعارات «متجرٌ ينتظر
  /// اعتمادك» و«سائقٌ جديد» كما تصل أيّ إشعارٍ في زنبور.
  String? _pushToken;

  Future<void> _initPush() async {
    try {
      await Firebase.initializeApp();
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission(alert: true, badge: true, sound: true);
      _pushToken = await fm.getToken();
      fm.onTokenRefresh.listen((t) {
        _pushToken = t;
        _injectToken();
      });

      // **والتطبيق مفتوح لا يعرض النظامُ الإشعار** — نعرضه نحن.
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n != null) _toast('${n.title ?? ''}\n${n.body ?? ''}');
      });

      await _injectToken();
    } catch (e) {
      // لم يُسجَّل التطبيق في Firebase بعد (لا google-services.json)، أو
      // جهازٌ بلا خدمات Google. اللوحة تعمل كاملةً بلا إشعارات.
      debugPrint('إشعارات المدير غير متاحة: $e');
    }
  }

  Future<void> _injectToken() async {
    final t = _pushToken;
    if (t == null) return;
    try {
      await _web.runJavaScript(
        'window.zanbourPushToken = ${jsonEncode(t)};'
        "window.dispatchEvent(new Event('zanbour-push-token'));",
      );
    } catch (_) {}
  }

  /// **يعترض التنزيل قبل أن يفشل صامتاً.**
  ///
  /// زرّ «تنزيل إكسل» في اللوحة يُنشئ الملفّ في ذاكرة المتصفّح
  /// (`blob:`) ثم يضغط رابطاً بخاصية `download`. والمتصفّح العادي يحفظه؛
  /// أما WebView فلا يفعل شيئاً **ولا يقول شيئاً** — يضغط المدير الزرّ
  /// مراراً ويظنّ اللوحة معطوبة.
  ///
  /// فنعترض ضغطة الرابط، ونقرأ محتواه، ونمرّره إلى دارت ليُكتب في ملفٍّ
  /// حقيقيّ ويُفتح بتطبيق الجداول.
  static const _downloadScript = r'''
(function () {
  if (window.__zanbourSaveHooked) return;
  window.__zanbourSaveHooked = true;

  document.addEventListener('click', function (ev) {
    var a = ev.target && ev.target.closest ? ev.target.closest('a[download]') : null;
    if (!a || !a.href) return;

    ev.preventDefault();
    ev.stopPropagation();

    var name = a.getAttribute('download') || 'zanbour.csv';

    fetch(a.href)
      .then(function (r) { return r.blob(); })
      .then(function (b) {
        var reader = new FileReader();
        reader.onload = function () {
          // النتيجة: data:<type>;base64,<...> — نأخذ ما بعد الفاصلة.
          var s = String(reader.result);
          var comma = s.indexOf(',');
          ZanbourSave.postMessage(JSON.stringify({
            name: name,
            data: comma < 0 ? '' : s.substring(comma + 1)
          }));
        };
        reader.readAsDataURL(b);
      })
      .catch(function (e) {
        ZanbourSave.postMessage(JSON.stringify({ error: String(e) }));
      });
  }, true);
})();
''';

  Future<void> _save(JavaScriptMessage message) async {
    try {
      final m = jsonDecode(message.message) as Map<String, dynamic>;
      if (m['error'] != null) {
        _toast('تعذّر التنزيل: ${m['error']}');
        return;
      }

      final bytes = base64Decode('${m['data']}');
      final name = '${m['name']}';

      // **مجلّد التنزيلات إن وُجد، وإلا مجلّد التطبيق.** الأول يجده
      // المدير في مدير الملفّات؛ والثاني لا يضيع الملفّ فيه على الأقل.
      Directory dir;
      try {
        dir = (await getDownloadsDirectory()) ??
            await getApplicationDocumentsDirectory();
      } catch (_) {
        dir = await getApplicationDocumentsDirectory();
      }

      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes);

      if (!mounted) return;
      // **يُفتح لا يُعلَن فقط.** رسالةٌ تقول «حُفظ في …» تترك المدير
      // يبحث عنه في مدير الملفّات؛ وفتحُه مباشرةً هو ما أراده أصلاً.
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done && mounted) {
        _toast('حُفظ في: ${file.path}');
      }
    } catch (e) {
      _toast('تعذّر حفظ الملفّ: $e');
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // **زرّ الرجوع يرجع في اللوحة لا يُغلق التطبيق.** من فتح صفحة
      // سائقٍ وضغط رجوع يقصد القائمة، لا الخروج من التطبيق كله.
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _web.canGoBack()) {
          await _web.goBack();
        } else if (context.mounted) {
          final leave = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('إغلاق اللوحة؟'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('تراجع')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('إغلاق')),
              ],
            ),
          );
          if (leave == true) await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              if (!_offline) WebViewWidget(controller: _web),

              if (_offline)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi_off, size: 56),
                        const SizedBox(height: 16),
                        const Text(
                          'تعذّر الوصول إلى اللوحة',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'تحقّق من اتصالك بالإنترنت ثم أعد المحاولة.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () =>
                              _web.loadRequest(Uri.parse(kAdminUrl)),
                          icon: const Icon(Icons.refresh),
                          label: const Text('أعد المحاولة'),
                        ),
                      ],
                    ),
                  ),
                ),

              if (_loading && !_offline)
                const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(minHeight: 3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
