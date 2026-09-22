import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';

/// إرسال إشعار — لجمهورٍ كامل أو لشخصٍ واحد.
///
/// **ولماذا معاينةٌ وعددٌ قبل الزر؟** رسالةٌ فيها خطأ إملائي تصل خمسمئة
/// هاتف ولا تُسترد. ورؤية «سترسل إلى ٥١٢ سائقاً» تجعل المدير يقرأ نصّه
/// مرة أخرى — وهو كل ما نريد.
///
/// يعيد `true` إن أُرسل.
Future<bool?> showSendNotificationDialog(
  BuildContext context, {
  String? audience,
  String? userId,
  String? userName,
  String title = '',
  String body = '',
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _SendDialog(
        audience: audience,
        userId: userId,
        userName: userName,
        initialTitle: title,
        initialBody: body,
      ),
    );

class _SendDialog extends ConsumerStatefulWidget {
  const _SendDialog({
    this.audience,
    this.userId,
    this.userName,
    required this.initialTitle,
    required this.initialBody,
  });

  final String? audience;
  final String? userId;
  final String? userName;
  final String initialTitle;
  final String initialBody;

  @override
  ConsumerState<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends ConsumerState<_SendDialog> {
  late final _title = TextEditingController(text: widget.initialTitle);
  late final _body = TextEditingController(text: widget.initialBody);

  bool _approvedOnly = false;
  bool _busy = false;
  String? _error;

  bool get _direct => widget.userId != null;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
    _body.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _valid =>
      _title.text.trim().length >= 2 && _body.text.trim().length >= 2;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(adminRepositoryProvider);
      if (_direct) {
        await repo.sendDirect(
          userId: widget.userId!,
          title: _title.text.trim(),
          body: _body.text.trim(),
        );
      } else {
        await repo.sendBroadcast(
          title: _title.text.trim(),
          body: _body.text.trim(),
          audience: widget.audience!,
          approvedOnly: _approvedOnly,
        );
      }

      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_direct
            ? 'أُرسل إلى ${widget.userName ?? 'المستخدم'}'
            : 'أُرسل الإشعار — تابع «وصلت» في القائمة بعد دقيقة'),
        duration: const Duration(seconds: 5),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = _direct
        ? null
        : ref.watch(audienceCountProvider(
            (audience: widget.audience!, approvedOnly: _approvedOnly)));

    return AlertDialog(
      title: Text(_direct
          ? 'إشعار إلى ${widget.userName ?? 'المستخدم'}'
          : 'إشعار إلى كل '
              '${widget.audience == 'driver' ? 'السائقين' : 'الركّاب'}'),
      content: SizedBox(
        width: Breaks.dialogWidth(context, 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'العنوان',
                  hintText: 'تحديث الأسعار',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _body,
                maxLines: 4,
                maxLength: 300,
                decoration: const InputDecoration(
                  labelText: 'النص',
                  hintText: 'اكتب الرسالة كما ستظهر على الهاتف…',
                ),
              ),

              if (!_direct) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _approvedOnly,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _approvedOnly = v ?? false),
                  title: const Text('المعتمدون فقط'),
                  subtitle: const Text(
                      'استبعاد من لم تُراجَع وثائقه بعد'),
                ),
              ],

              const SizedBox(height: 12),

              // ---- المعاينة ----
              // **يراها كما ستظهر على الهاتف.** نصٌّ في حقلٍ عريض يبدو
              // مختلفاً عنه في إشعارٍ ضيّق، والاقتطاع لا يُكتشف إلا بعد
              // الإرسال.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.notifications_active_outlined,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text('زنبور',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _title.text.trim().isEmpty
                          ? 'العنوان…'
                          : _title.text.trim(),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      _body.text.trim().isEmpty ? 'النص…' : _body.text.trim(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),

              if (!_direct) ...[
                const SizedBox(height: 16),
                count!.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (n) => Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AdminTheme.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 18, color: AdminTheme.warning),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'سيصل إلى $n شخصاً. لا يمكن التراجع بعد '
                            'الإرسال — اقرأ النص مرة أخرى.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 16),
                SelectableText(_error!,
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton.icon(
          onPressed: (_busy || !_valid) ? null : _send,
          icon: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send, size: 18),
          label: const Text('أرسل'),
        ),
      ],
    );
  }
}

// =============================================================================
/// حفظ رسالة جاهزة.
Future<bool?> showSaveTemplateDialog(
  BuildContext context, {
  required String audience,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _TemplateDialog(audience: audience),
    );

class _TemplateDialog extends ConsumerStatefulWidget {
  const _TemplateDialog({required this.audience});
  final String audience;

  @override
  ConsumerState<_TemplateDialog> createState() => _TemplateDialogState();
}

class _TemplateDialogState extends ConsumerState<_TemplateDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
    _body.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _valid =>
      _title.text.trim().length >= 2 && _body.text.trim().length >= 2;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('رسالة جاهزة'),
      content: SizedBox(
        width: Breaks.dialogWidth(context, 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('تُحفظ ولا تُرسل الآن. أرسلها متى شئت، أو اجعلها '
                'مجدولة تتكرر وحدها.'),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: true,
              maxLength: 80,
              decoration: const InputDecoration(
                  labelText: 'العنوان', counterText: ''),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              maxLines: 4,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'النص'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              SelectableText(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: (_busy || !_valid)
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    await ref.read(adminRepositoryProvider).saveTemplate(
                          title: _title.text.trim(),
                          body: _body.text.trim(),
                          audience: widget.audience,
                        );
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        _error = '$e';
                        _busy = false;
                      });
                    }
                  }
                },
          child: const Text('احفظ'),
        ),
      ],
    );
  }
}

// =============================================================================
/// جدولة رسالة محفوظة.
Future<bool?> showScheduleDialog(
  BuildContext context, {
  required String templateId,
  required String audience,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) =>
          _ScheduleDialog(templateId: templateId, audience: audience),
    );

class _ScheduleDialog extends ConsumerStatefulWidget {
  const _ScheduleDialog({required this.templateId, required this.audience});

  final String templateId;
  final String audience;

  @override
  ConsumerState<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends ConsumerState<_ScheduleDialog> {
  String _frequency = 'daily';
  int _hour = 9;
  int _weekday = 5; // الجمعة
  bool _busy = false;
  String? _error;

  static const _days = [
    'الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء',
    'الخميس', 'الجمعة', 'السبت',
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('جدولة الرسالة'),
      content: SizedBox(
        width: Breaks.dialogWidth(context, 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'daily', label: Text('يومياً')),
                ButtonSegment(value: 'weekly', label: Text('أسبوعياً')),
                ButtonSegment(value: 'once', label: Text('مرة')),
              ],
              selected: {_frequency},
              onSelectionChanged: (s) =>
                  setState(() => _frequency = s.first),
            ),
            const SizedBox(height: 20),

            if (_frequency == 'weekly') ...[
              DropdownButtonFormField<int>(
                initialValue: _weekday,
                decoration: const InputDecoration(labelText: 'اليوم'),
                items: [
                  for (var i = 0; i < 7; i++)
                    DropdownMenuItem(value: i, child: Text(_days[i])),
                ],
                onChanged: (v) => setState(() => _weekday = v ?? 5),
              ),
              const SizedBox(height: 16),
            ],

            DropdownButtonFormField<int>(
              initialValue: _hour,
              decoration: const InputDecoration(
                labelText: 'الساعة',
                helperText: 'بتوقيت بغداد',
              ),
              items: [
                for (var h = 0; h < 24; h++)
                  DropdownMenuItem(
                      value: h,
                      child: Text('${h.toString().padLeft(2, '0')}:00')),
              ],
              onChanged: (v) => setState(() => _hour = v ?? 9),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              SelectableText(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    await ref.read(adminRepositoryProvider).saveSchedule(
                          templateId: widget.templateId,
                          audience: widget.audience,
                          frequency: _frequency,
                          hour: _hour,
                          weekday: _frequency == 'weekly' ? _weekday : null,
                        );
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        _error = '$e';
                        _busy = false;
                      });
                    }
                  }
                },
          child: const Text('جدولها'),
        ),
      ],
    );
  }
}
