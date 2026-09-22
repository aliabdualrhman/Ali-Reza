import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/theme.dart';
import 'settings_page.dart' show settingsProvider;
import '../../core/perms.dart';

/// الخدمات المتاحة — تُفتح وتُغلق من هنا.
///
/// **بطاقةٌ مستقلّة لا سطران في قائمة الإعدادات.** إغلاق خدمةٍ قرارٌ
/// يراه كل سائقٍ وكل راكبٍ في الحال، ولا يجوز أن يُتخذ بتعديل رقمٍ في
/// جدولٍ طويل بين خمسين إعداداً.
///
/// **والرسالة تُكتب هنا لا في الكود.** «قريباً» و«تحت الصيانة» و«نعود
/// غداً» كلمات تتغيّر بحسب السبب، وتثبيتها في التطبيق يعني بناءً ونشراً
/// لكل كلمة.
class ServicesCard extends ConsumerWidget {
  const ServicesCard({super.key, required this.settings});

  final List<Map<String, dynamic>> settings;

  String _raw(String key, String fallback) {
    for (final r in settings) {
      if (r['key'] == key) return '${r['value']}'.trim();
    }
    return fallback;
  }

  bool _on(String key) {
    final v = _raw(key, '1').toLowerCase();
    return v == '1' || v == 'true' || v == 'yes' || v == 'on';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

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
            Text('الخدمات المتاحة',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'المغلقة تختفي من التطبيقين، ومكانها الرسالة التي تكتبها. '
              'والقاعدة ترفض طلباتها أيضاً — فمن يحمل نسخةً قديمة لا '
              'يستطيع تجاوز الإغلاق.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),

            _Service(
              enabled: can(ref, 'settings.manage'),
              icon: Icons.two_wheeler,
              title: 'نقل الركّاب',
              open: _on('rides_enabled'),
              message: _raw('rides_closed_msg', ''),
              onToggle: (v) => set('rides_enabled', v ? '1' : '0'),
              onMessage: (v) => set('rides_closed_msg', v),
            ),

            const Divider(height: 32),

            _Service(
              enabled: can(ref, 'settings.manage'),
              icon: Icons.shopping_basket_outlined,
              title: 'التسوّق',
              open: _on('shopping_enabled'),
              message: _raw('shopping_closed_msg', ''),
              onToggle: (v) => set('shopping_enabled', v ? '1' : '0'),
              onMessage: (v) => set('shopping_closed_msg', v),
            ),

            const Divider(height: 32),

            // طلب المندوب (0091). المتاجر تُعتمد من صفحة «المتاجر».
            _Service(
              enabled: can(ref, 'settings.manage'),
              icon: Icons.local_shipping_outlined,
              title: 'طلب المندوب',
              open: _on('delivery_enabled'),
              message: _raw('delivery_closed_msg', ''),
              onToggle: (v) => set('delivery_enabled', v ? '1' : '0'),
              onMessage: (v) => set('delivery_closed_msg', v),
            ),
          ],
        ),
      ),
    );
  }
}

class _Service extends StatefulWidget {
  const _Service({
    required this.icon,
    required this.title,
    required this.open,
    required this.message,
    required this.onToggle,
    required this.onMessage,
    required this.enabled,
  });

  /// من يرى الإعدادات ولا يعدّلها: المفتاح والحقل يظهران معطّلين.
  final bool enabled;

  final IconData icon;
  final String title;
  final bool open;
  final String message;
  final Future<void> Function(bool) onToggle;
  final Future<void> Function(String) onMessage;

  @override
  State<_Service> createState() => _ServiceState();
}

class _ServiceState extends State<_Service> {
  late final TextEditingController _msg =
      TextEditingController(text: widget.message);
  bool _dirty = false;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          value: widget.open,
          contentPadding: EdgeInsets.zero,
          secondary: Icon(widget.icon,
              size: 28,
              color: widget.open
                  ? AdminTheme.success
                  : theme.colorScheme.outline),
          title: Text(widget.title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          subtitle: Text(
            widget.open ? 'مفتوحة — تعمل في التطبيقين' : 'مغلقة',
            style: theme.textTheme.bodySmall?.copyWith(
                color: widget.open
                    ? AdminTheme.success
                    : theme.colorScheme.error),
          ),
          onChanged: !widget.enabled ? null : (v) => widget.onToggle(v),
        ),

        // **حقل الرسالة يظهر عند الإغلاق وحده.** حقلٌ دائمٌ يُغري
        // بتعديل نصٍّ لا أحد يراه.
        if (!widget.open) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _msg,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'ما يراه المستخدمون',
              hintText: 'قريباً · تحت الصيانة · نعود غداً',
              border: const OutlineInputBorder(),
              // **يُحفظ بزرٍّ لا بكل حرف.** الحفظ مع كل ضغطة يُرسل
              // عشرين نداءً لجملةٍ واحدة، ويُظهر للمستخدمين نصّاً
              // نصفَ مكتوب.
              suffixIcon: _dirty
                  ? IconButton(
                      icon: const Icon(Icons.check),
                      tooltip: 'حفظ',
                      onPressed: !widget.enabled ? null : () async {
                        await widget.onMessage(_msg.text.trim());
                        if (mounted) setState(() => _dirty = false);
                      },
                    )
                  : null,
            ),
            onChanged: !widget.enabled ? null : (_) {
              if (!_dirty) setState(() => _dirty = true);
            },
          ),
        ],
      ],
    );
  }
}
