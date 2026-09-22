import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import 'settings_page.dart' show settingsProvider;
import '../../core/perms.dart';

/// أيّهما إجباري عند التسجيل: الهاتف أم البريد؟
///
/// **بطاقةٌ مستقلّة لا سطرٌ في قائمة الإعدادات.** القيمة نصٌّ في القاعدة
/// (`phone` أو `email`)، ومربّعُ نصٍّ يقبل أيّ كلمة: خطأٌ مطبعيّ واحد
/// يُنتج وضعاً لا يعرفه التطبيق، فيسقط الحاجزان معاً أو يرتفعان معاً
/// بلا أن يفهم أحد لماذا.
///
/// والاختيار من زرّين يجعل الخطأ مستحيلاً، ويعرض أثر كل وضع قبل اختياره.
class VerificationModeCard extends ConsumerWidget {
  const VerificationModeCard({super.key, required this.settings});

  /// صفوف `public_settings` كما وصلت — نقرأ منها ولا نُعيد الجلب.
  final List<Map<String, dynamic>> settings;

  String _value(String key, String fallback) {
    for (final r in settings) {
      if (r['key'] == key) return '${r['value']}'.trim().toLowerCase();
    }
    return fallback;
  }

  bool get _otpOn {
    final v = _value('otp_enabled', '1');
    return v == '1' || v == 'true' || v == 'yes' || v == 'on';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = _value('verification_mode', 'email');
    final isPhone = mode == 'phone';

    Future<void> set(String key, String value) async {
      await ref.read(adminRepositoryProvider).saveSetting(key, value);
      ref.invalidate(settingsProvider);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text('التوثيق الإجباري عند التسجيل',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'واحدٌ فقط يكون إجبارياً — والآخر يؤكّده المستخدم لاحقاً من '
              'صفحة حسابه.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),

            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'email',
                  label: Text('البريد'),
                  icon: Icon(Icons.mail_outline),
                ),
                ButtonSegment(
                  value: 'phone',
                  label: Text('الهاتف — واتساب'),
                  icon: Icon(Icons.chat_bubble_outline),
                ),
              ],
              selected: {mode == 'phone' ? 'phone' : 'email'},
              onSelectionChanged: !can(ref, 'settings.manage') ? null : (s) => set('verification_mode', s.first),
            ),

            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ما يحدث الآن:', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  _Rule(
                    on: isPhone,
                    text: isPhone
                        ? 'الهاتف إجباري — يصل رمز على واتساب عند التسجيل.'
                        : 'البريد إجباري — يصل رابط تأكيد عند التسجيل.',
                  ),
                  _Rule(
                    on: false,
                    text: isPhone
                        ? 'البريد اختياري — يؤكّده لاحقاً من إعداداته.'
                        : 'الهاتف اختياري — يوثّقه لاحقاً من إعداداته.',
                  ),
                ],
              ),
            ),

            // **لا إعداد خارج هذه اللوحة.** كان الوضع يتطلّب إطفاء
            // «Confirm email» من لوحة Supabase — إعدادٌ في موقعٍ آخر
            // بحسابٍ آخر لا يعرفه من يدير المنصة يوماً بعدنا. فألغينا
            // الحاجة إليه: مُشغّلٌ يؤكّد البريد لحظة الإنشاء حين يكون
            // الهاتف هو الوضع (0064).

            const Divider(height: 32),

            // **مفتاح إطفاءٍ منفصل.** رصيد المزوّد ينفد ليلاً، أو تتوقف
            // خدمته — وحينها يقف كل مستخدمٍ جديد أمام شاشةٍ لا يصلها رمز.
            // وهذا المفتاح يفتح الباب في ثانية بلا بناءٍ ولا نشر.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _otpOn,
              onChanged: !can(ref, 'settings.manage') ? null : (v) => set('otp_enabled', v ? '1' : '0'),
              title: const Text('إرسال رموز الهاتف مفعَّل'),
              subtitle: Text(
                _otpOn
                    ? 'أطفئه إن نفد رصيد المزوّد — يدخل الجميع فوراً بلا '
                        'انتظار رمز.'
                    : '🔴 مطفأ — لا يُطلب توثيق الهاتف من أحد.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule({required this.on, required this.text});

  final bool on;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(on ? Icons.lock_outline : Icons.lock_open,
              size: 16,
              color: on
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
