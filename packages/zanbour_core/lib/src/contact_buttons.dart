import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// زرّا التواصل مع الطرف الآخر: واتساب واتصال.
///
/// **لماذا واتساب أولاً؟** هو وسيلة التواصل الأولى في العراق. السائق الذي
/// لا يجد العنوان يرسل موقعه على واتساب، والراكب يرد بصورة للمدخل. مكالمة
/// وهما على دراجة في الشارع أصعب.
///
/// **قيد تقني يجب أن يبقى مكتوباً:** واتساب لا يتيح رابطاً رسمياً لبدء
/// **مكالمة**. الحيل المتداولة تعتمد معرّفاً داخلياً في جهات الاتصال،
/// تكسرها تحديثات واتساب وتفشل إن لم يكن الرقم محفوظاً. فلا نبنيها.
/// الزرّان هنا يعملان على كل جهاز بلا استثناء، ومن داخل المحادثة يضغط
/// المستخدم أيقونة السماعة بنفسه إن أراد مكالمة واتساب.
class ContactButtons extends StatelessWidget {
  const ContactButtons({
    super.key,
    required this.phone,
    this.message,
    this.compact = false,
  });

  /// الرقم كما تخزّنه القاعدة بصيغة E.164 — مثل `+9647701234567`.
  final String phone;

  /// رسالة جاهزة تُملأ في خانة الكتابة. تختصر على السائق كتابة التعريف
  /// بنفسه وهو واقف بدراجته.
  final String? message;

  /// نسخة مضغوطة بأيقونتين بلا نص — للبطاقات الضيقة.
  final bool compact;

  /// واتساب يقبل الرقم بأرقامه فقط: بلا `+` ولا مسافات ولا شَرَطات.
  /// **الصيغة الدولية ولو كُتب الرقم محلياً.** أرقام المستلمين في طلب
  /// المندوب يكتبها التاجر كما يعرفها — `0770…` — ورابط واتساب بلا رمز
  /// الدولة يفتح محادثةً مع رقمٍ غير موجود.
  String get _waNumber =>
      iraqiE164(phone).replaceAll(RegExp(r'[^0-9]'), '');

  Future<void> _openWhatsApp() async {
    final text = message == null ? '' : '?text=${Uri.encodeComponent(message!)}';
    final uri = Uri.parse('https://wa.me/$_waNumber$text');
    // LaunchMode.externalApplication يفتح تطبيق واتساب نفسه لا متصفحاً
    // داخل تطبيقنا — الأخير يُظهر صفحة "افتح في التطبيق" ويطلب ضغطة زائدة.
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _call() async {
    await launchUrl(Uri.parse('tel:$phone'));
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filledTonal(
            onPressed: _openWhatsApp,
            icon: const Icon(Icons.chat),
            tooltip: 'واتساب',
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: _call,
            icon: const Icon(Icons.phone),
            tooltip: 'اتصال',
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: _openWhatsApp,
            icon: const Icon(Icons.chat, size: 18),
            label: const Text('واتساب'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: _call,
            icon: const Icon(Icons.call, size: 18),
            label: const Text('اتصال'),
          ),
        ),
      ],
    );
  }
}

/// رقم عراقي بالصيغة الدولية `+964…` أيّاً كانت كتابته.
///
///     0770 123 4567   → +9647701234567
///     009647701234567 → +9647701234567
///     9647701234567   → +9647701234567
///
/// وما لا يشبه رقماً عراقياً يعود كما هو بلا مسافات — لا نخمّن.
String iraqiE164(String raw) {
  final s = raw.replaceAll(RegExp(r'[\s-]'), '');
  if (s.startsWith('+')) return s;
  if (s.startsWith('00')) return '+${s.substring(2)}';
  if (s.startsWith('964')) return '+$s';
  if (s.startsWith('0') && s.length == 11) return '+964${s.substring(1)}';
  if (s.startsWith('7') && s.length == 10) return '+964$s';
  return s;
}
