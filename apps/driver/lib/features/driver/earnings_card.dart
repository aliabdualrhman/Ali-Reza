import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart' show supabaseProvider;
import 'driver_repository.dart';

/// الفترة المطلوبة: من (شاملة) إلى (غير شاملة)، بالتوقيت المحلي.
typedef EarningsRange = ({DateTime from, DateTime to});

/// **مفتاح العائلة سجلٌّ لا كائن.** السجلات في دارت تتساوى بقيمها، فطلبُ
/// الفترة نفسها مرتين يعيد النتيجة المحفوظة بدل استدعاء القاعدة ثانيةً.
final earningsProvider = FutureProvider.autoDispose
    .family<Earnings, EarningsRange>(
  (ref, r) => ref.watch(driverRepositoryProvider).earnings(r.from, r.to),
);

/// أعداد طلبات السائق في الفترة نفسها — `my_trip_stats` (0134).
final tripStatsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, EarningsRange>((ref, r) async {
  final rows = await ref.watch(supabaseProvider).rpc('my_trip_stats', params: {
    'p_from': r.from.toUtc().toIso8601String(),
    'p_to': r.to.toUtc().toIso8601String(),
  }) as List;
  return rows.isEmpty ? const {} : Map<String, dynamic>.from(rows.first as Map);
});

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
                            color: context.z.ok,
                          )),
                    ],
                  ),
                ],
              ),
            ),
            // **أعداد الطلبات للفترة نفسها** — طلبها علي: المقبولة،
            // والمكتملة، وما ألغاه هو، وما ألغاه الطرف الآخر. الإلغاء من
            // جهته يُحسب عليه، ومن الطرف الآخر لا — فالفصل بينهما عدل.
            const SizedBox(height: 16),
            _TripStats(range: range),

            // **أعمدة الأيام السبعة الأخيرة، تحت أيّ فترةٍ اختيرت.** الرقم
            // يقول كم كسب؛ والأعمدة تقول **متى** يكسب — أيّ يومٍ يستحقّ أن
            // يخرج فيه باكراً.
            const SizedBox(height: 20),
            const _WeekBars(),
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

/// أرباح آخر سبعة أيام، عمودٌ لكلّ يوم — اليوم كهرمانيٌّ ممتلئ.
///
/// **من `my_earnings` يوماً يوماً، لا من قائمة الرحلات.** القائمة تقف عند
/// خمسين رحلة فتنقص أيام السائق المشغول؛ والدالة تجمع في القاعدة (0088).
/// سبعة نداءاتٍ صغيرة تُحفظ في المزوّد ولا تُعاد إلا بالتحديث.
class _WeekBars extends ConsumerWidget {
  const _WeekBars();

  static const _days = ['الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final z = context.z;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [for (var i = 6; i >= 0; i--) today.subtract(Duration(days: i))];
    final values = [
      for (final d in days)
        ref
                .watch(earningsProvider(
                    (from: d, to: d.add(const Duration(days: 1)))))
                .value
                ?.gross ??
            0,
    ];
    final max = values.fold<num>(0, (a, b) => b > a ? b : a);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('آخر ٧ أيام',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        SizedBox(
          height: 128,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (values[i] > 0)
                          FittedBox(
                            child: Text(
                              values[i] >= 1000
                                  ? '${(values[i] / 1000).toStringAsFixed(values[i] % 1000 == 0 ? 0 : 1)}ألف'
                                  : '${values[i].round()}',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: z.inkDim),
                            ),
                          ),
                        const SizedBox(height: 3),
                        TweenAnimationBuilder<double>(
                          tween: Tween(
                              begin: 0,
                              end: max == 0 ? 0 : values[i] / max),
                          duration: Duration(milliseconds: 500 + i * 60),
                          curve: const Cubic(0.2, 0.9, 0.25, 1),
                          builder: (_, v, _) => Container(
                            height: 4 + 80 * v,
                            decoration: BoxDecoration(
                              color: i == 6 ? z.amber : z.amberWash,
                              borderRadius: BorderRadius.circular(6),
                              border: i == 6
                                  ? null
                                  : Border.all(color: z.line),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        FittedBox(
                          child: Text(
                            i == 6 ? 'اليوم' : _days[days[i].weekday - 1],
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  i == 6 ? FontWeight.w700 : FontWeight.w500,
                              color: i == 6 ? z.amberDeep : z.inkDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _d(DateTime d) => '${d.year}/${d.month}/${d.day}';

String _rangeLabel(EarningsRange r) {
  // `to` غير شاملة؛ يُعرض اليوم الذي قبلها
  final last = r.to.subtract(const Duration(days: 1));
  if (last == r.from) return _d(r.from);
  return 'من ${_d(r.from)} إلى ${_d(last)}';
}

/// أربعة أرقام: مقبولة · مكتملة · ألغيتُها · ألغاها الطرف الآخر.
class _TripStats extends ConsumerWidget {
  const _TripStats({required this.range});

  final EarningsRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final s = ref.watch(tripStatsProvider(range)).value;
    int n(String k) => (s?[k] as num?)?.toInt() ?? 0;

    Widget cell(String label, int v, Color c) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ZCountUp(v,
                    style: TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700, color: c)),
                const SizedBox(height: 2),
                FittedBox(
                  child: Text(label,
                      style: TextStyle(fontSize: 11, color: z.inkDim)),
                ),
              ],
            ),
          ),
        );

    return Row(
      children: [
        cell('مقبولة', n('accepted'), z.amberDeep),
        cell('مكتملة', n('completed'), z.ok),
        cell('ألغيتُها', n('cancelled_by_me'), z.bad),
        cell('ألغاها الطرف الآخر', n('cancelled_by_other'), z.warn),
      ],
    );
  }
}
