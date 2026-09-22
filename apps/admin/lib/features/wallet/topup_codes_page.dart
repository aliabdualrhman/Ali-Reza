import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/perms.dart';
import '../../core/theme.dart';
import '../trips/trips_page.dart' show fmtDateTime;

/// مفتاح البحث: الحالة والنص معاً. سجلّان منفصلان كانا سيعيدان الجلب
/// مرتين عند كل تغيير.
class CodesQuery {
  const CodesQuery(this.used, this.text);
  final bool? used;
  final String text;
  @override
  bool operator ==(Object other) =>
      other is CodesQuery && other.used == used && other.text == text;
  @override
  int get hashCode => Object.hash(used, text);
}

/// وصولات زين كاش — السجلّ الذي يمنع استعمال وصلٍ مرتين.
final zainReceiptsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, q) => ref.watch(adminRepositoryProvider).zainReceipts(query: q),
);

final topupCodesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, CodesQuery>(
  (ref, q) => ref
      .watch(adminRepositoryProvider)
      .topupCodes(used: q.used, query: q.text),
);

/// رموز التعبئة: توليدها، نسخها، وإبطال ما ضاع منها.
///
/// **لماذا نولّدها دفعةً بقيمة واحدة؟** لأن هذه هي طريقة استعمالها فعلاً:
/// نطبع عشرين رمزاً بخمسة آلاف ونوزّعها على السائقين. رمزٌ رمز بقيمة
/// مختلفة يعني عشرين عملية بدل واحدة.
class TopupCodesPage extends ConsumerStatefulWidget {
  const TopupCodesPage({super.key});

  @override
  ConsumerState<TopupCodesPage> createState() => _TopupCodesPageState();
}

class _TopupCodesPageState extends ConsumerState<TopupCodesPage> {
  /// null = الكل، false = غير مستعمل، true = مستعمل
  bool? _filter = false;
  String _text = '';
  /// **تبويبان لا صفحتان.** الرموز والوصولات وجهان لعملٍ واحد: من يولّد
  /// رمزاً بوصل يسأل بعدها «هل استُعمل هذا الوصل؟».
  bool _receipts = false;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codes = ref.watch(topupCodesProvider(CodesQuery(_filter, _text)));
    // **فارغةٌ حتى تصل.** لا نُظهر زرّاً ثم نُخفيه — نُظهره حين نعرف.
    // **بائعان:** كاش يولّد بلا وصل، وزين كاش لا يولّد إلا به (0102).
    final canGenerate =
        canAny(ref, ['topups.generate', 'topups.generate_zaincash']);
    final canDelete = can(ref, 'topups.delete');

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: _receipts ? 'وصولات زين كاش' : 'رموز التعبئة',
            actions: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('الرموز')),
                  ButtonSegment(value: true, label: Text('وصولات زين كاش')),
                ],
                selected: {_receipts},
                showSelectedIcon: false,
                onSelectionChanged: (v) =>
                    setState(() => _receipts = v.first),
              ),
              if (!_receipts)
              FilterChoice<bool?>(
                value: _filter,
                options: const [
                  (false, 'غير مستعملة'),
                  (true, 'مستعملة'),
                  (null, 'الكل'),
                ],
                onChanged: (v) => setState(() => _filter = v),
              ),
              SearchField(
                controller: _search,
                hint: _receipts
                    ? 'ابحث برقم عملية زين كاش'
                    : 'رقم الرمز أو ملاحظة الدفعة',
                onSubmitted: (v) => setState(() => _text = v),
              ),
              // **الكنس بجوار التوليد.** من يولّد دفعةً هو من يرى
              // الجدول يمتلئ بما مات، فالفعلان يُطلبان في اللحظة نفسها.
              if (canDelete && !_receipts)
                OutlinedButton.icon(
                  onPressed: () => _purge(context, ref),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('حذف الميّتة'),
                ),
              // **وصلٌ بلا رمز.** المال يصل بطرقٍ لا تمرّ برمز: شحنٌ
              // مباشر من صفحة السائق، أو تسديد دَين. وتسجيله هنا يمنع
              // عودة الوصل نفسه بعد أسبوع.
              if (canGenerate && _receipts)
                FilledButton.icon(
                  onPressed: () => _addReceiptDialog(context, ref),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('تسجيل وصل يدوياً'),
                ),
              if (canGenerate && !_receipts)
                FilledButton.icon(
                  onPressed: () => _generateDialog(context, ref),
                  icon: const Icon(Icons.add),
                  // **هذا مكان تسجيل الوصل.** الاسم يقوله صراحةً: من
                  // وصله وصلٌ من سائق يفتح هذه النافذة ويُدخل رقمه.
                  label: const Text('توليد رمز / تسجيل وصل'),
                ),
            ],
          ),
          const SizedBox(height: 20),
          if (_receipts)
            Expanded(child: _Receipts(query: _text))
          else
          Expanded(
            child: codes.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(e,
                  onRetry: () => ref.invalidate(topupCodesProvider)),
              data: (rows) {
                if (rows.isEmpty) {
                  return const Center(child: Text('لا توجد رموز'));
                }
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      final used = r['redeemed_by'] != null;
                      final void_ = r['is_void'] == true;
                      return ListTile(
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: Breaks.isCompact(context) ? 10 : 16),
                        leading: Icon(
                          void_
                              ? Icons.block
                              : used
                                  ? Icons.check_circle
                                  : Icons.confirmation_number_outlined,
                          color: void_
                              ? theme.colorScheme.error
                              : used
                                  ? theme.colorScheme.primary
                                  : null,
                        ),
                        // على الهاتف: خطّ أصغر وتباعد أقلّ. ست عشرة خانة
                        // بمسافات وتباعد ١٫٥ أعرض من شاشة ٣٦٠ نقطة، فيُقصّ
                        // آخر الرمز — وهو ما ينسخه المدير ليرسله لسائق.
                        title: SelectableText(
                          _pretty('${r['code']}'),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: Breaks.isCompact(context) ? 14 : 17,
                            letterSpacing:
                                Breaks.isCompact(context) ? 0.5 : 1.5,
                          ),
                        ),
                        subtitle: Text([
                          '${(r['amount_iqd'] as num).round()} دينار',
                          if ('${r['batch_note'] ?? ''}'.isNotEmpty)
                            '${r['batch_note']}',
                          'ولّده ${_creatorName(r) ?? '—'}'
                              '  ${fmtDateTime(r['created_at'])}',
                          // من استهلكه ومتى: "استُعمل" وحدها لا تكفي حين
                          // يسأل سائق عن رمز أرسلناه إليه فوجدناه مستهلَكاً.
                          if (used)
                            'عبّأه ${_redeemerName(r) ?? '—'}'
                                '  ${fmtDateTime(r['redeemed_at'])}',
                          if (r['trans_id'] != null)
                            'زين كاش ${r['trans_id']}',
                          if (void_) 'مُلغى',
                        ].join('  ·  ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.copy),
                              tooltip: 'نسخ',
                              onPressed: () async {
                                await Clipboard.setData(
                                    ClipboardData(text: '${r['code']}'));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('نُسخ الرمز')),
                                  );
                                }
                              },
                            ),
                            if (canGenerate && !used && !void_)
                              IconButton(
                                icon: const Icon(Icons.block),
                                tooltip: 'إبطال',
                                onPressed: () async {
                                  await ref
                                      .read(adminRepositoryProvider)
                                      .voidCode(r['id'] as String);
                                  ref.invalidate(topupCodesProvider);
                                },
                              ),
                            // **الحذف للميّت وحده.** الصالح يُبطَل أولاً،
                            // فقد يكون في هاتف سائقٍ ينتظر أن يعبّئ به.
                            if (canDelete && (used || void_))
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'حذف',
                                onPressed: () =>
                                    _deleteOne(context, ref, r),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// رسالة القاعدة لا نصّ الاستثناء الكامل.
///
/// **ولا نستورد `AppError`.** اللوحة لا تعتمد `zanbour_core` عمداً
/// (انظر `core/theme.dart`)، فسطران هنا أرخص من تبعيةٍ كاملة.
String _msg(Object e) {
  final m = RegExp(r'message:\s*([^,)]+)').firstMatch('$e');
  return m?.group(1)?.trim() ?? '$e';
}

/// حذف رمزٍ واحد بعد تأكيد.
///
/// **بتأكيدٍ لا بلمسة.** أيقونة الحذف تجاور أيقونة النسخ، والضغطة
/// الخاطئة تمحو سطراً يُسأل عنه لاحقاً حين يختلف سائق على رمز.
Future<void> _deleteOne(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> row,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('حذف الرمز'),
      content: Text([
        'يُحذف نهائياً من السجلّ:',
        '',
        _pretty('${row['code']}'),
        '${(row['amount_iqd'] as num).round()} دينار',
      ].join('\n')),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error),
          child: const Text('احذف'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  try {
    await ref.read(adminRepositoryProvider).deleteCode(row['id'] as String);
    ref.invalidate(topupCodesProvider);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_msg(e))));
    }
  }
}

/// كنس المستهلكة والملغاة دفعةً.
Future<void> _purge(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('حذف الرموز الميّتة'),
      content: const Text(
          'تُحذف كل الرموز المستهلكة والملغاة نهائياً. '
          'الرموز الصالحة لا تُمسّ.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error),
          child: const Text('احذفها'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  try {
    final n = await ref.read(adminRepositoryProvider).purgeCodes();
    ref.invalidate(topupCodesProvider);
    if (context.mounted) {
      // **العدد لا «تمّ».** «حُذف صفر» و«حُذف ثلاثمئة» خبران مختلفان.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(n == 0 ? 'لا رموز ميّتة' : 'حُذف $n رمزاً')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_msg(e))));
    }
  }
}

/// اسم من عبّأ الرمز. قفزتان: `redeemed_by` → `drivers` → `profiles`.
/// من ولّد الرمز. `null` لرموزٍ قديمة حُذف حساب مولّدها.
String? _creatorName(Map<String, dynamic> row) =>
    (row['creator'] as Map<String, dynamic>?)?['full_name'] as String?;

String? _redeemerName(Map<String, dynamic> row) {
  final d = row['redeemer'] as Map<String, dynamic>?;
  final p = d?['profile'] as Map<String, dynamic>?;
  return p?['full_name'] as String?;
}

/// نعرض الرمز في أربع مجموعات: ست عشرة خانة متلاصقة تُقرأ خطأً حين
/// تُملى على سائق في الهاتف.
String _pretty(String code) {
  final b = StringBuffer();
  for (var i = 0; i < code.length; i++) {
    if (i > 0 && i % 4 == 0) b.write(' ');
    b.write(code[i]);
  }
  return b.toString();
}


// =============================================================================
Future<void> _generateDialog(BuildContext context, WidgetRef ref) async {
  // **بائع كاش** يولّد دفعاتٍ بلا وصل. **وبائع زين كاش** لا يولّد إلا
  // رمزاً واحداً برقم عملية. والقاعدة تفرض الاثنين — هذا يُظهر ما ستقبله.
  final cashSeller = can(ref, 'topups.generate');
  final count = TextEditingController(text: cashSeller ? '10' : '1');
  final amount = TextEditingController(text: '5000');
  final note = TextEditingController();
  final trans = TextEditingController();
  var busy = false;
  String? error;

  // حالة فحص رقم العملية: null = لم يُفحص، وإلا ما ردّته القاعدة.
  Map<String, dynamic>? check;
  var checking = false;
  var checkSeq = 0;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final hasTrans = trans.text.trim().isNotEmpty;
        final used = check?['used'] == true;
        // **الوصل يولّد رمزاً واحداً.** العدد يُقفل على ١ حين يُكتب رقم.
        final countLocked = hasTrans || !cashSeller;

        Future<void> runCheck() async {
          final seq = ++checkSeq;
          final v = trans.text.trim();
          if (v.isEmpty) {
            setLocal(() => check = null);
            return;
          }
          setLocal(() => checking = true);
          try {
            final r = await ref.read(adminRepositoryProvider).checkTransId(v);
            // ردٌّ متأخر لنصٍّ تغيّر بعده — نتجاهله.
            if (seq == checkSeq) setLocal(() => check = r);
          } catch (_) {
            if (seq == checkSeq) setLocal(() => check = null);
          } finally {
            if (seq == checkSeq) setLocal(() => checking = false);
          }
        }

        return AlertDialog(
          title: Text(cashSeller ? 'توليد رموز' : 'توليد رمز — زين كاش'),
          content: SizedBox(
            width: Breaks.dialogWidth(ctx, 400),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: trans,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: cashSeller
                          ? 'رقم عملية زين كاش (اختياري للكاش)'
                          : 'رقم عملية زين كاش (Trans ID)',
                      helperText: 'كما يظهر في وصل التحويل',
                      suffixIcon: checking
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            )
                          : check == null
                              ? null
                              : Icon(
                                  used
                                      ? Icons.error_outline
                                      : Icons.check_circle_outline,
                                  color: used ? Colors.red : Colors.green,
                                ),
                    ),
                    onChanged: (v) {
                      // خارج البناء لا داخله: تعديل المتحكّم أثناء البناء
                      // يستدعي `setState` في حقلٍ يُبنى — خطأ إطار.
                      if (v.trim().isNotEmpty) count.text = '1';
                      setLocal(() => check = null);
                      runCheck();
                    },
                  ),
                  if (used) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade300),
                      ),
                      child: Text(
                        'رقم العملية مستخدم — وُلّد به رمز بقيمة '
                        '${(check!['amount'] as num).round()} دينار '
                        'بواسطة ${check!['by'] ?? '—'} '
                        '${fmtDateTime(check!['at'])}',
                        style: TextStyle(color: Colors.red.shade800),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: count,
                    enabled: !countLocked,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'عدد الرموز',
                      helperText: countLocked
                          ? 'رقم العملية يولّد رمزاً واحداً'
                          : 'حتى ٢٠٠ في الدفعة',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText:
                          hasTrans ? 'المبلغ المحوَّل في الوصل' : 'قيمة كل رمز',
                      suffixText: 'دينار',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: note,
                    decoration: const InputDecoration(
                      labelText: 'ملاحظة (اختيارية)',
                      hintText: 'مثال: اسم السائق أو دفعة الناصرية',
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!,
                        style:
                            TextStyle(color: Theme.of(ctx).colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              // **لا توليد بلا وصل لبائع زين كاش، ولا بوصلٍ مستعمل.** القاعدة
              // ترفض أيضاً؛ الزرّ المعطّل يوفّر ضغطةً تنتهي برفض.
              onPressed: busy || used || checking || (!cashSeller && !hasTrans)
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(ctx);
                      setLocal(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final made =
                            await ref.read(adminRepositoryProvider).generateCodes(
                                  count: int.tryParse(count.text) ?? 0,
                                  amount: int.tryParse(amount.text) ?? 0,
                                  note: note.text.trim().isEmpty
                                      ? null
                                      : note.text.trim(),
                                  transId: hasTrans ? trans.text.trim() : null,
                                );
                        ref.invalidate(topupCodesProvider);
                        if (ctx.mounted) Navigator.pop(ctx);
                        messenger.showSnackBar(SnackBar(
                            content: Text(made.length == 1
                                ? 'وُلّد الرمز'
                                : 'وُلّد ${made.length} رمزاً')));
                      } catch (e) {
                        setLocal(() {
                          error = e is PostgrestException ? e.message : '$e';
                          busy = false;
                        });
                        // لعلّ الرقم استُعمل في اللحظة نفسها من جلسةٍ أخرى.
                        runCheck();
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2))
                  : const Text('توليد'),
            ),
          ],
        );
      },
    ),
  );

  count.dispose();
  amount.dispose();
  note.dispose();
  trans.dispose();
}

// =============================================================================
/// جدول وصولات زين كاش المستعملة.
///
/// **يُقرأ ولا يُكتب ولا يُحذف.** لو حُذف وصلٌ منه لعاد صالحاً للاستعمال —
/// وهذا بابُ من يرسل الوصل نفسه مرتين (0102).
class _Receipts extends ConsumerWidget {
  const _Receipts({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(zainReceiptsProvider(query));

    return rows.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          ErrorView(e, onRetry: () => ref.invalidate(zainReceiptsProvider)),
      data: (list) {
        if (list.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'لا توجد وصولات بعد. كل رمزٍ يُولَّد برقم عملية زين كاش '
                'يُسجَّل هنا، ولا يُقبل الرقم مرةً ثانية.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = list[i];
              final by = (r['creator'] as Map?)?['full_name'];
              return ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: SelectableText(
                  '${r['trans_id']}',
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 15, letterSpacing: 1),
                ),
                subtitle: Text([
                  '${(r['amount_iqd'] as num).round()} دينار',
                  if ((r['code_count'] as num?)?.toInt() == 0) 'يدويّ',
                  'سجّله ${by ?? '—'}',
                  fmtDateTime(r['created_at']),
                  if ('${r['note'] ?? ''}'.isNotEmpty) '${r['note']}',
                ].join('  ·  ')),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: 'نسخ',
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: '${r['trans_id']}'));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('نُسخ رقم العملية')),
                          );
                        }
                      },
                    ),
                    if (can(ref, 'topups.receipt_delete'))
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'حذف الوصل',
                        onPressed: () =>
                            _deleteReceipt(context, ref, r),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// =============================================================================
/// تسجيل وصلٍ يدوياً — لمالٍ وصل بلا رمزٍ وُلّد له.
Future<void> _addReceiptDialog(BuildContext context, WidgetRef ref) async {
  final trans = TextEditingController();
  final amount = TextEditingController();
  final note = TextEditingController();
  var busy = false;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('تسجيل وصل زين كاش'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 400),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: trans,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'رقم عملية زين كاش (Trans ID)',
                    helperText: 'لن يُقبل هذا الرقم مرةً أخرى',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'المبلغ المحوَّل',
                    suffixText: 'دينار',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(
                    labelText: 'السبب (اختياري)',
                    hintText: 'مثال: شحن مباشر لحساب فلان',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setLocal(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await ref.read(adminRepositoryProvider).addReceipt(
                            transId: trans.text.trim(),
                            amount: int.tryParse(amount.text.trim()) ?? 0,
                            note: note.text.trim().isEmpty
                                ? null
                                : note.text.trim(),
                          );
                      ref.invalidate(zainReceiptsProvider);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      setLocal(() {
                        error = e is PostgrestException ? e.message : '$e';
                        busy = false;
                      });
                    }
                  },
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2))
                : const Text('سجّل'),
          ),
        ],
      ),
    ),
  );

  trans.dispose();
  amount.dispose();
  note.dispose();
}

/// حذف وصل — **يعيده قابلاً للاستعمال**، فالتأكيد يقول ذلك صراحةً.
Future<void> _deleteReceipt(
    BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('حذف الوصل؟'),
      content: Text(
        'رقم العملية ${row['trans_id']} — ${(row['amount_iqd'] as num).round()} دينار.\n\n'
        'بعد الحذف يصير هذا الوصل صالحاً للاستعمال من جديد، '
        'ويستطيع صاحبه أن يشحن به مرةً ثانية.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: AdminTheme.danger),
          child: const Text('احذف'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  try {
    await ref
        .read(adminRepositoryProvider)
        .deleteReceipt('${row['trans_id']}');
    ref.invalidate(zainReceiptsProvider);
    messenger.showSnackBar(const SnackBar(content: Text('حُذف الوصل')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(
        content: Text(e is PostgrestException ? e.message : '$e')));
  }
}
