import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';

/// الفترة المطلوبة: من (شاملة) إلى (غير شاملة)، بالتوقيت المحلي.
typedef EarningsRange = ({DateTime from, DateTime to});

/// **مفتاح العائلة سجلٌّ لا كائن.** السجلات في دارت تتساوى بقيمها، فطلبُ
/// الفترة نفسها مرتين يعيد النتيجة المحفوظة بدل استدعاء القاعدة ثانيةً.
final earningsProvider = FutureProvider.autoDispose
    .family<Earnings, EarningsRange>(
  (ref, r) => ref.watch(driverRepositoryProvider).earnings(r.from, r.to),
);

enum _Period { today, week, month, custom }

/// قسم الأرباح أعلى «رحلاتي».
///
/// **الأجور والصافي معاً لا أحدهما.** السائق يقبض الأجرة كاملةً بيده،
/// وحصة الشركة تُقيَّد ديناً في محفظته. عرضُ الأجور وحدها يوهمه أنه كسب
/// أكثر مما كسب، وعرضُ الصافي وحده يجعله يظن أن المال الذي في جيبه
/// زائدٌ عن حقه.
class EarningsCard extends ConsumerStatefulWidget {
  const EarningsCard({super.key});

  @override
  ConsumerState<EarningsCard> createState() => _EarningsCardState();
}

class _EarningsCardState extends ConsumerState<EarningsCard> {
  _Period _period = _Period.today;
  DateTimeRange? _custom;

  EarningsRange _range() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    switch (_period) {
      case _Period.today:
        return (from: today, to: tomorrow);
      case _Period.week:
        // **الأسبوع في العراق يبدأ السبت.** `weekday`: الاثنين ١ … الأحد ٧،
        // فالسبت ٦؛ نرجع إليه.
        final back = (today.weekday - DateTime.saturday) % 7;
        return (from: today.subtract(Duration(days: back)), to: tomorrow);
      case _Period.month:
        return (from: DateTime(now.year, now.month), to: tomorrow);
      case _Period.custom:
        final c = _custom!;
        // نهاية الفترة **شاملة** عند السائق: «إلى ١٥» تعني حتى آخر ١٥.
        return (
          from: DateTime(c.start.year, c.start.month, c.start.day),
          to: DateTime(c.end.year, c.end.month, c.end.day)
              .add(const Duration(days: 1)),
        );
    }
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2025),
      lastDate: now,
      initialDateRange: _custom ??
          DateTimeRange(
            start: now.subtract(const Duration(days: 6)),
            end: now,
          ),
      helpText: 'اختر الفترة',
      saveText: 'عرض',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _custom = picked;
      _period = _Period.custom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final range = _range();
    final data = ref.watch(earningsProvider(range));

    Widget chip(_Period p, String label) => ChoiceChip(
          label: Text(label),
          selected: _period == p,
          onSelected: (_) {
            if (p == _Period.custom) {
              _pickCustom();
            } else {
              setState(() => _period = p);
            }
          },
        );

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('الأرباح',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                chip(_Period.today, 'اليوم'),
                chip(_Period.week, 'الأسبوع'),
                chip(_Period.month, 'الشهر'),
                chip(_Period.custom, 'فترة محددة'),
              ],
            ),
            const SizedBox(height: 8),
            // التاريخان ظاهران دائماً: «الأسبوع» وحده لا يقول أيّ أسبوع.
            Text(
              _rangeLabel(range),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            data.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(AppError.message(e),
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
              data: (e) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _line(theme, 'عدد الرحلات المكتملة', '${e.trips}'),
                  _line(theme, 'الأرباح الكلية', _iqd(e.gross)),
                  _line(theme, 'نسبة الشركة', '− ${_iqd(e.commission)}',
                      muted: true),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text('الأرباح الصافية',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                      Text(_iqd(e.net),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: ZanbourTheme.success,
                          )),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(ThemeData theme, String label, String value,
      {bool muted = false}) {
    final color = muted ? theme.colorScheme.onSurfaceVariant : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: theme.textTheme.bodyLarge?.copyWith(color: color)),
          ),
          Text(value,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

String _iqd(num v) => '${v.round()} دينار';

String _d(DateTime d) => '${d.year}/${d.month}/${d.day}';

String _rangeLabel(EarningsRange r) {
  // `to` غير شاملة؛ يُعرض اليوم الذي قبلها
  final last = r.to.subtract(const Duration(days: 1));
  if (last == r.from) return _d(r.from);
  return 'من ${_d(r.from)} إلى ${_d(last)}';
}
