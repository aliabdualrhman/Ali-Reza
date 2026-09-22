import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// خيارات التقييم — تتبدّل مع عدد النجوم.
///
/// **نجومٌ بلا سبب لا تُصلح شيئاً.** ثلاثُ نجومٍ تقول إن شيئاً ساء ولا
/// تقول ما هو، فلا المدير يعرف ماذا يفعل ولا السائق ماذا يصحّح.
///
/// **والخيارات من الخادم لا من الكود.** تُحرَّر من لوحة المدير بلا بناءٍ
/// ولا نشرٍ ولا مراجعة متجر — كما كل إعداداتنا.
class RatingTagsField extends StatefulWidget {
  const RatingTagsField({
    super.key,
    required this.stars,
    required this.onChanged,
  });

  /// صفر = لم يختر نجوماً بعد، فلا خيارات.
  final int stars;

  /// الأسباب المختارة والمبلغ — والثاني فارغ ما لم يُطلب.
  final void Function(List<String> codes, num? amount) onChanged;

  @override
  State<RatingTagsField> createState() => _RatingTagsFieldState();
}

class _RatingTagsFieldState extends State<RatingTagsField> {
  final _amount = TextEditingController();
  final _selected = <String>{};

  List<Map<String, dynamic>> _options = const [];
  int _loadedFor = -1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RatingTagsField old) {
    super.didUpdateWidget(old);
    // **تتبدّل القائمة مع النجوم لا مع كل ضغطة.** من نزل من ٥ إلى ٢
    // يجب أن يرى أسباباً سلبية، ومن تنقّل بين ٤ و٥ لا شيء يتغيّر عنده.
    if (widget.stars != old.stars) _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  bool get _needsAmount => _options.any(
      (o) => o['needs_amount'] == true && _selected.contains(o['code']));

  Future<void> _load() async {
    final stars = widget.stars;
    if (stars <= 0) {
      setState(() {
        _options = const [];
        _loadedFor = -1;
      });
      return;
    }

    // **الطلب مرةً لكل ضفّة.** ٤ و٥ إيجابيتان، فلا نُتعب الشبكة
    // بطلبٍ جديد كلما تنقّل بينهما.
    final side = stars <= 3 ? 0 : 1;
    if (side == _loadedFor) return;

    setState(() => _busy = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('rating_options', params: {'p_stars': stars});
      if (!mounted) return;
      setState(() {
        _options = List<Map<String, dynamic>>.from(rows as List);
        _loadedFor = side;
        // أسبابُ الرضا لا تصلح أسباباً للسخط: نبدأ من جديد.
        _selected.clear();
        _amount.clear();
      });
      _emit();
    } catch (_) {
      // **الخيارات زينةٌ لا شرط.** قاعدةٌ لم تُرحَّل أو شبكةٌ منقطعة
      // يجب ألّا تمنع تقييماً بالنجوم.
      if (mounted) setState(() => _options = const []);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _emit() {
    final amount = num.tryParse(_amount.text.trim());
    widget.onChanged(_selected.toList(), _needsAmount ? amount : null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_busy && _options.isEmpty) return const SizedBox.shrink();
    if (_options.isEmpty) return const SizedBox.shrink();

    final negative = widget.stars <= 3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Text(
          negative ? 'ما الذي لم يعجبك؟' : 'ما الذي أعجبك؟',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'اختر ما ينطبق — أو تجاوزها.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),

        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in _options)
              FilterChip(
                label: Text('${o['label']}'),
                selected: _selected.contains(o['code']),
                onSelected: (on) {
                  setState(() {
                    on
                        ? _selected.add('${o['code']}')
                        : _selected.remove('${o['code']}');
                    if (!_needsAmount) _amount.clear();
                  });
                  _emit();
                },
              ),
          ],
        ),

        // **المبلغ يظهر عند الحاجة وحدها.** حقلٌ دائمٌ يربك من لا يقصده.
        if (_needsAmount) ...[
          const SizedBox(height: 14),
          TextField(
            controller: _amount,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'كم المبلغ؟',
              suffixText: 'دينار',
              helperText: 'يقارنه المدير بما سجّله الطرف الآخر',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _emit(),
          ),
        ],
      ],
    );
  }
}
