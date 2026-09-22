import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'text.dart';

/// أدوات التخطيط المتجاوب للوحة.
///
/// **لماذا؟** اللوحة كُتبت لشاشة عريضة: صفوف فيها عنوان ومرشّح وبحث جنباً
/// إلى جنب. على هاتف بعرض ٣٦٠ نقطة يخرج نصف الصف من الشاشة — فيختفي زر
/// «كل الرحلات» ولا يبقى للمدير سبيل إليه. لا نبني لوحةً ثانية للجوال؛
/// نجعل الصفّ يلتفّ والشريط الجانبي يصير درجاً.
class Breaks {
  /// دون هذا العرض نعدّ الشاشة هاتفاً: الشريط الجانبي يختفي في درج،
  /// وصفوف الأدوات تلتفّ.
  static const compact = 760.0;

  static bool isCompact(BuildContext c) =>
      MediaQuery.sizeOf(c).width < compact;

  /// هوامش الصفحة: ٢٨ على الشاشة العريضة تتنفّس، وعلى الهاتف تلتهم
  /// سُدس العرض بلا فائدة.
  static double pad(BuildContext c) => isCompact(c) ? 14 : 28;

  /// عرض نافذة حوارية لا يتجاوز الشاشة. `SizedBox(width: 460)` داخل
  /// `AlertDialog` على هاتف يقصّ المحتوى من الجانبين.
  static double dialogWidth(BuildContext c, double preferred) {
    final w = MediaQuery.sizeOf(c).width - 80;
    return w < preferred ? (w < 240 ? 240 : w) : preferred;
  }
}

/// رأس الصفحة: عنوان، ووصف اختياري، وأدوات تلتفّ على الهاتف.
///
/// الأدوات تُمرَّر قائمةً لا صفّاً جاهزاً، لأن `Wrap` هي التي تقرّر أين
/// ينكسر السطر — وهذا ما يمنع اختفاء زرٍّ خارج الشاشة.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = Breaks.isCompact(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title,
              style: (compact
                      ? theme.textTheme.titleLarge
                      : theme.textTheme.headlineSmall)
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            ...actions,
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

/// حقل بحث بعرض ثابت على الشاشة العريضة، وبعرض الشاشة كاملاً على الهاتف.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    this.width = 280,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSubmitted;
  final double width;

  @override
  Widget build(BuildContext context) {
    final compact = Breaks.isCompact(context);
    return SizedBox(
      width: compact ? MediaQuery.sizeOf(context).width - 2 * Breaks.pad(context) : width,
      child: TextField(
        controller: controller,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: onSubmitted,
      ),
    );
  }
}

/// مرشّح مقطعي يصير قائمة منسدلة على الهاتف.
///
/// `SegmentedButton` بثلاثة خيارات عربية أعرض من شاشة الهاتف، فينكسر
/// أو يختفي. القائمة المنسدلة تعرض نفس الخيارات في مساحة زر واحد.
class FilterChoice<T> extends StatelessWidget {
  const FilterChoice({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    if (Breaks.isCompact(context)) {
      // قائمة لا `DropdownButton`: بعض المرشّحات قيمتها `null` تعني «الكل»،
      // و`DropdownButton` يقرأ `null` أنه «بلا اختيار» فيعرض فراغاً.
      final i = options.indexWhere((o) => o.$1 == value);
      final label = i < 0 ? options.first.$2 : options[i].$2;
      return PopupMenuButton<int>(
        initialValue: i < 0 ? 0 : i,
        onSelected: (k) => onChanged(options[k].$1),
        itemBuilder: (_) => [
          for (var k = 0; k < options.length; k++)
            PopupMenuItem(value: k, child: Text(options[k].$2)),
        ],
        child: Chip(
          label: Text(label),
          avatar: const Icon(Icons.filter_list, size: 18),
        ),
      );
    }
    return SegmentedButton<T>(
      segments: [
        for (final (v, label) in options)
          ButtonSegment(value: v, label: Text(label)),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// عرض خطأ يُقرأ على الهاتف: نصّ ملتفّ قابل للنسخ داخل تمرير.
///
/// `Center(child: Text('$e'))` كان يقصّ رسالة PostgREST الطويلة فلا يبقى
/// منها ما يدلّ على السبب.
class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 40),
        Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
        const SizedBox(height: 12),
        Text('تعذّر التحميل',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText('$error',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        if (onRetry != null) ...[
          const SizedBox(height: 20),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ),
        ],
      ],
    );
  }
}

/// رمز الرحلة ظاهراً وقابلاً للنسخ.
///
/// **رقم واحد يربط الثلاثة.** الراكب يشتكي من «رحلة ١٠٤٣٢»، والسائق يرى
/// الرقم نفسه في سجلّه، والمدير يبحث به هنا. لذلك يظهر في كل سجلّ لا في
/// صفحة التفاصيل وحدها — والنسخ بلمسة لأنه يُلصق في محادثة الدعم.
class TripCodeBadge extends StatelessWidget {
  const TripCodeBadge({super.key, required this.number, this.compact = false});

  final Object? number;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = tripCode(number);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: label.replaceAll('#', '')));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('نُسخ رمز الرحلة $label')),
          );
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 12, vertical: compact ? 3 : 7),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textDirection: TextDirection.ltr,
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            fontSize: compact ? 12 : 16,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

/// رسالة القاعدة لا نصّ الاستثناء الكامل — `raise exception` بالعربية
/// هو ما يجب أن يقرأه المدير، لا `PostgrestException(message: …, code: …)`.
String adminError(Object e) {
  final m = RegExp(r'message:\s*([^,)]+)').firstMatch('$e');
  return m?.group(1)?.trim() ?? '$e';
}
