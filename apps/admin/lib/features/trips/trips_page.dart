import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import 'trip_detail_page.dart';

class TripsQuery {
  const TripsQuery(
      {this.live = true, this.text = '', this.page = 0, this.kind = ''});
  final bool live;
  final String text;
  final int page;

  /// نوع الطلب: '' للكل، أو ride / shopping / delivery.
  final String kind;

  TripsQuery copy({bool? live, String? text, int? page, String? kind}) =>
      TripsQuery(
          live: live ?? this.live,
          text: text ?? this.text,
          page: page ?? this.page,
          kind: kind ?? this.kind);

  @override
  bool operator ==(Object other) =>
      other is TripsQuery &&
      other.live == live &&
      other.text == text &&
      other.page == page &&
      other.kind == kind;
  @override
  int get hashCode => Object.hash(live, text, page, kind);
}

const kPageSize = 50;

final tripsQueryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, TripsQuery>(
  (ref, q) => ref.watch(adminRepositoryProvider).trips(
      liveOnly: q.live,
      query: q.text,
      page: q.page,
      pageSize: kPageSize,
      kind: q.kind),
);

/// الرحلات: الجارية وحدها أو الكل، بصفحات وبحث.
///
/// **لماذا تبويبان لا قائمة واحدة؟** الجارية سؤال تشغيلي تُسأل الآن —
/// من ينتظر سائقاً، ومن على الطريق. والكل سؤال تدقيقي يُسأل لاحقاً.
/// خلطهما يجعل الصف المهم يضيع بين مئة صف منتهٍ.
class TripsPage extends ConsumerStatefulWidget {
  const TripsPage({super.key});

  @override
  ConsumerState<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends ConsumerState<TripsPage> {
  var _q = const TripsQuery();
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = ref.watch(tripsQueryProvider(_q));

    final compact = Breaks.isCompact(context);
    final pad = Breaks.pad(context);

    return Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'الرحلات',
            actions: [
              FilterChoice<bool>(
                value: _q.live,
                options: const [(true, 'الجارية'), (false, 'كل الرحلات')],
                onChanged: (v) =>
                    setState(() => _q = _q.copy(live: v, page: 0)),
              ),
              FilterChoice<String>(
                value: _q.kind,
                options: const [
                  ('', 'كل الأنواع'),
                  ('ride', 'رحلات'),
                  ('shopping', 'تسوّق'),
                  ('delivery', 'مندوب'),
                ],
                onChanged: (v) =>
                    setState(() => _q = _q.copy(kind: v, page: 0)),
              ),
              SearchField(
                controller: _search,
                width: 320,
                hint: 'رقم الرحلة أو عنوان',
                onSubmitted: (v) => setState(() => _q = _q.copy(text: v, page: 0)),
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.refresh),
                tooltip: 'تحديث',
                onPressed: () => ref.invalidate(tripsQueryProvider(_q)),
              ),
            ],
          ),
          SizedBox(height: compact ? 14 : 20),
          Expanded(
            child: rows.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText('تعذّر التحميل: $e',
                      textAlign: TextAlign.center),
                ),
              ),
              data: (list) {
                if (list.isEmpty) {
                  // نفرّق بين «لا رحلات جارية الآن» و«لا رحلات إطلاقاً»:
                  // الأولى حالة طبيعية في ساعة هادئة، والثانية تعني خللاً.
                  // خلطهما جعل المدير يظن اللوحة معطّلة وهي تعمل.
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.route_outlined,
                              size: 56, color: theme.colorScheme.outline),
                          const SizedBox(height: 12),
                          Text(
                            _q.page > 0
                                ? 'لا مزيد من الرحلات'
                                : _q.text.isNotEmpty
                                    ? 'لا نتائج لـ"${_q.text}"'
                                    : _q.live
                                        ? 'لا توجد رحلات جارية الآن'
                                        : 'لا توجد رحلات بعد',
                            style: theme.textTheme.titleMedium,
                            textAlign: TextAlign.center,
                          ),
                          if (_q.live && _q.page == 0 && _q.text.isEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              'الرحلات المنتهية والملغاة لا تظهر هنا.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.tonalIcon(
                              onPressed: () => setState(
                                  () => _q = _q.copy(live: false, page: 0)),
                              icon: const Icon(Icons.history),
                              label: const Text('اعرض كل الرحلات'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => _TripRow(trip: list[i]),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _q.page == 0
                    ? null
                    : () => setState(() => _q = _q.copy(page: _q.page - 1)),
                icon: const Icon(Icons.chevron_right),
                label: const Text('السابق'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('صفحة ${_q.page + 1}'),
              ),
              OutlinedButton.icon(
                // نعطّله حين تعود الصفحة أقصر من حدّها: علامة أنها الأخيرة،
                // بلا استعلام عدٍّ إضافي على جدول ينمو بلا حدّ.
                onPressed: (rows.value?.length ?? 0) < kPageSize
                    ? null
                    : () => setState(() => _q = _q.copy(page: _q.page + 1)),
                icon: const Icon(Icons.chevron_left),
                label: const Text('التالي'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TripRow extends StatelessWidget {
  const _TripRow({required this.trip});
  final Map<String, dynamic> trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = '${trip['status']}';
    final driver = driverProfile(trip);
    final rider = trip['rider'] as Map<String, dynamic>?;
    final fare = (trip['fare_final_iqd'] ?? trip['fare_estimated_iqd']) as num?;

    final tags = <String>[
      if (trip['kind'] == 'delivery')
        switch (trip['vehicle_kind']) {
          'tuktuk' => 'مندوب · تكتك',
          'stoota' => 'مندوب · ستوتة',
          _ => 'مندوب',
        },
      if (trip['kind'] == 'shopping') 'تسوّق',
      if ((trip['stop_count'] as num? ?? 1) > 1) 'محطتان',
      if (trip['has_stopover'] == true) 'توقف',
      if (trip['coupon_id'] != null) 'كوبون',
    ];

    final compact = Breaks.isCompact(context);

    return ListTile(
      contentPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 20, vertical: 10),
      // رمز الرحلة في صدر الصف لا داخل دائرة ضيقة تقصّ خمس خانات منه.
      leading: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TripCodeBadge(number: trip['trip_number'], compact: true),
          const SizedBox(height: 4),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _statusColor(theme, status),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              '${trip['pickup_address'] ?? '—'}  ←  ${trip['dropoff_address'] ?? '—'}',
              maxLines: compact ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!compact)
            for (final t in tags)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Chip(
                  label: Text(t, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          [
            statusLabel(status),
            'راكب: ${rider?['full_name'] ?? '—'}',
            'سائق: ${driver?['full_name'] ?? 'لم يُسند'}',
            fmtDateTime(trip['requested_at']),
            if (compact) ...tags,
          ].join('  ·  '),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
      isThreeLine: compact,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fare != null)
            Text('${fare.round()} د',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          if (!compact) const SizedBox(width: 12),
          const Icon(Icons.chevron_left),
        ],
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TripDetailPage(tripId: trip['id'] as String),
      )),
    );
  }
}

// =============================================================================
// أدوات مشتركة بين صفحات الرحلات
// =============================================================================
Color _statusColor(ThemeData t, String s) => switch (s) {
      'completed' => t.colorScheme.primary,
      'cancelled' || 'no_drivers' => t.colorScheme.error,
      _ => t.colorScheme.tertiary,
    };

String statusLabel(String s) => switch (s) {
      'searching' => 'يبحث عن سائق',
      'no_drivers' => 'لم يجد سائقاً',
      'accepted' => 'السائق في الطريق',
      'driver_arrived' => 'السائق وصل',
      'in_progress' => 'جارية',
      'completed' => 'مكتملة',
      'cancelled' => 'ملغاة',
      _ => s,
    };

String fmtDateTime(Object? raw) {
  final d = DateTime.tryParse('$raw')?.toLocal();
  if (d == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}/${two(d.month)}/${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
}

/// ملف السائق داخل الرحلة.
///
/// **قفزتان لا واحدة:** `trips.driver_id` يشير إلى `drivers`، و`drivers.id`
/// هو نفسه مفتاح `profiles`. فالاسم يقع تحت `driver.profile` لا تحت
/// `driver` مباشرةً.
Map<String, dynamic>? driverProfile(Map<String, dynamic> trip) {
  final d = trip['driver'] as Map<String, dynamic>?;
  return d?['profile'] as Map<String, dynamic>?;
}
