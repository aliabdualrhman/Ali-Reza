import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// قناة وصول المستخدم إلينا — تُسأل مرة واحدة عند التسجيل.
///
/// **سؤالٌ بفائدتين لا واحدة:**
///
///   ١) **بحثٌ تسويقي مجاني.** يخبرك أيّ قناة تجلب فعلاً قبل أن تنفق
///      ديناراً. ويظهر في ملف المستخدم لدى المدير.
///
///   ٢) **بابُ الدعوة.** من يختار «صديق» يُسأل عن رمزه في اللحظة التي
///      يتذكّر فيها صديقه — لا في شاشةٍ لاحقة قد لا يفتحها أبداً.
///
/// **ولماذا لا نعرض حقل الرمز دائماً؟** لأن حقلاً فارغاً في شاشة تسجيل
/// طويلة يُتجاهَل، ويجعل الشاشة أطول على من لا دعوة له — وهم الأكثرية.
class HeardFromField extends StatefulWidget {
  const HeardFromField({
    super.key,
    required this.onChanged,
  });

  /// يُستدعى عند كل تغيير: القناة، والملاحظة، ورمز الدعوة.
  final void Function(String? source, String? note, String? code) onChanged;

  @override
  State<HeardFromField> createState() => _HeardFromFieldState();
}

class _HeardFromFieldState extends State<HeardFromField> {
  static const _options = <String, String>{
    'friend': 'صديق دعاني',
    'ad': 'إعلان',
    'street': 'رأيته في الشارع',
    'other': 'مصدر آخر',
  };

  String? _source;
  final _note = TextEditingController();
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _note.addListener(_emit);
    _code.addListener(_emit);
  }

  @override
  void dispose() {
    _note.dispose();
    _code.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(
        _source,
        _source == 'other' ? _note.text : null,
        _source == 'friend' ? _code.text : null,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _source,
          decoration: const InputDecoration(
            labelText: 'من أين سمعت عن زنبور؟',
            prefixIcon: Icon(Icons.help_outline),
          ),
          items: [
            for (final e in _options.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            setState(() => _source = v);
            _emit();
          },
        ),

        // ---- صديق: نطلب الرمز ----
        if (_source == 'friend') ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            textDirection: TextDirection.ltr,
            maxLength: 6,
            inputFormatters: [
              // الرمز حروفٌ وأرقام فقط — نمنع ما لا يُقبل أصلاً بدل أن
              // نردّه بخطأ بعد إرسال النموذج كاملاً.
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
            ],
            decoration: const InputDecoration(
              labelText: 'رمز الدعوة (اختياري)',
              hintText: 'ABC123',
              prefixIcon: Icon(Icons.card_giftcard),
              counterText: '',
              helperText: 'اطلبه من صديقك ليحصل على رصيد مجاني',
              helperMaxLines: 2,
            ),
          ),

          // **لا نُفشل التسجيل برمز خاطئ.** الرجل واقفٌ في الشارع، ورمزٌ
          // نُسي أو كُتب خطأً لا يجوز أن يمنعه من إنشاء حسابه. ونقول له
          // ذلك صراحةً كي لا يتردّد.
          const SizedBox(height: 6),
          Text(
            'تستطيع إدخاله لاحقاً من صفحة حسابك.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],

        // ---- مصدر آخر: نسأل ما هو ----
        if (_source == 'other') ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'اذكره باختصار (اختياري)',
              prefixIcon: Icon(Icons.edit_outlined),
            ),
          ),
        ],
      ],
    );
  }
}
