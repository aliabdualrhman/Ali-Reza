import 'package:flutter/material.dart';

import 'errors.dart';
import 'rating_tags_field.dart';

/// شاشة التقييم — مشتركة بين التطبيقين.
///
/// **شاشة كاملة لا نافذة منبثقة، وهذا جوهر الإصلاح.** كانت النافذة تُفتح
/// من شاشة الرحلة، والموجّه ينقل المستخدم إلى الخريطة فور اكتمالها —
/// فتموت النافذة مع الشاشة التي فتحتها قبل أن يقرأها أحد.
///
/// الشاشة الكاملة يوجّه إليها الموجّه من **الحالة** لا من الفعل: ما دامت
/// هناك رحلة مكتملة لم تُقيَّم، فهذه وجهته. تصمد أمام التصغير والتكبير،
/// وإغلاق التطبيق وفتحه، بل وإعادة تشغيل الهاتف.
class RatingView extends StatefulWidget {
  const RatingView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onSubmit,
    required this.onSkip,
  });

  final String title;
  final String subtitle;

  /// يُستدعى بالنجوم والملاحظة والأسباب. أي استثناء يُعرض مترجماً.
  final Future<void> Function(
    int stars,
    String? comment,
    List<String> tags,
    num? amount,
  ) onSubmit;

  final VoidCallback onSkip;

  @override
  State<RatingView> createState() => _RatingViewState();
}

class _RatingViewState extends State<RatingView> {
  int _stars = 0;
  List<String> _tags = const [];
  num? _amount;
  final _comment = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_stars, _comment.text, _tags, _amount);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AppError.message(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      // لا رجوع بزر النظام: الخروج الصامت يترك الرحلة بلا تقييم ويعيد
      // الموجّه المستخدم إلى هنا فوراً — حلقة تبدو عطلاً. الخروج بـ"لاحقاً".
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          // **يمرّر ولا يفيض.** أُضيفت رقائق الأسباب تحت النجوم، وعمودٌ
          // ثابتٌ بها يفيض على الشاشات الصغيرة وفي الوضع الأفقي.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                Icon(Icons.check_circle,
                    size: 72, color: theme.colorScheme.primary),
                const SizedBox(height: 20),
                Text(widget.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(widget.subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 28),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 1; i <= 5; i++)
                      IconButton(
                        onPressed:
                            _busy ? null : () => setState(() => _stars = i),
                        iconSize: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        icon: Icon(
                          i <= _stars ? Icons.star : Icons.star_border,
                          color: Colors.amber,
                        ),
                      ),
                  ],
                ),

                // **الأسباب قبل الملاحظة.** اختيارُ سببٍ جاهز أسهل من
                // كتابة جملة، ومن وجد ما يصفه لا يترك الشاشة صامتاً.
                RatingTagsField(
                  stars: _stars,
                  onChanged: (codes, amount) {
                    _tags = codes;
                    _amount = amount;
                  },
                ),

                const SizedBox(height: 20),
                TextField(
                  controller: _comment,
                  maxLines: 2,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظة (اختيارية)',
                    border: OutlineInputBorder(),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error)),
                ],

                const SizedBox(height: 28),
                FilledButton(
                  // **معطّل حتى تُختار نجمة.** بدء العدّاد من خمس نجوم
                  // يجعل الضغط السريع يمنحها بلا قصد، فيتضخّم المتوسط
                  // ويصير التقييم بلا معنى.
                  onPressed: (_busy || _stars == 0) ? null : _submit,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56)),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4))
                      : const Text('إرسال التقييم',
                          style: TextStyle(fontSize: 18)),
                ),
                TextButton(
                  onPressed: _busy ? null : widget.onSkip,
                  child: const Text('لاحقاً'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
