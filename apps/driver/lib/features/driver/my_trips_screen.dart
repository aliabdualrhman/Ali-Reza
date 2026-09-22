import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';
import 'earnings_card.dart';

final myTripsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(driverRepositoryProvider).tripHistory(),
);

/// رحلاتي — سجل ما أنجزه السائق.
///
/// **نعرض الأجرة والعمولة معاً.** السائق يقبض الأجرة نقداً بيده، وما
/// يهمّه فعلاً هو ما بقي له بعد حصة المنصة. عرض الأجرة وحدها يجعل كشف
/// الحساب يبدو مخالفاً لما في جيبه.
class MyTripsScreen extends ConsumerWidget {
  const MyTripsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trips = ref.watch(myTripsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('رحلاتي')),
      // شريط سفلي ثابت: السائق الذي يتصفّح رحلاته باحثاً عن خطأ في
      // أجرة يجب ألا يمرّر مئة صف ليجد الدعم.
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SupportButton(
            settingKey: 'support_whatsapp_driver',
            message: 'أنا كابتن زنبور، أحتاج مساعدة.',
            label: 'تواصل مع الدعم',
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myTripsProvider);
          ref.invalidate(earningsProvider);
        },
        child: trips.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(AppError.message(e))),
          data: (rows) {
            // **الأرباح أول ما يُرى، وتبقى حتى بلا رحلات.** قسمٌ يختفي
            // حين يكون الرقم صفراً يترك السائق يسأل: أين ذهب؟
            if (rows.isEmpty) {
              return ListView(
                children: const [
                  EarningsCard(),
                  SizedBox(height: 60),
                  Center(child: Text('لا توجد رحلات بعد')),
                ],
              );
            }
            return ListView.separated(
              itemCount: rows.length + 1,
              separatorBuilder: (_, i) =>
                  i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
              itemBuilder: (_, i) =>
                  i == 0 ? const EarningsCard() : _TripTile(trip: rows[i - 1]),
            );
          },
        ),
      ),
    );
  }
}

class _TripTile extends StatelessWidget {
  const _TripTile({required this.trip});
  final Map<String, dynamic> trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = '${trip['status']}';
    final done = status == 'completed';

    final fare = (trip['fare_final_iqd'] ?? trip['fare_estimated_iqd']) as num?;
    final km = ((trip['actual_distance_m'] ?? trip['estimated_distance_m'])
                as num? ??
            0) /
        1000;

    return ListTile(
      // **الصفّ يُفتح.** رقمٌ وسطران لا يكفيان حين يُسأل عن رحلةٍ
      // بعينها — ومن أجّل التقييم لا يجد بابه إلا هنا.
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TripDetailScreen(tripId: trip['id'] as String),
      )),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Icon(
        done ? Icons.check_circle : Icons.cancel_outlined,
        color: done ? theme.colorScheme.primary : theme.colorScheme.error,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text('${trip['dropoff_address'] ?? 'وجهة غير معروفة'}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          // رمز الرحلة في كل صف: هو ما يُملى على الدعم حين يُشتكى من
          // رحلة بعينها، وبغيره لا يجدها المدير في اللوحة.
          TripCodeBadge(number: trip['trip_number'], compact: true),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text('من ${trip['pickup_address'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            '${_date(trip['requested_at'])} · ${km.toStringAsFixed(1)} كم'
            '${done ? '' : ' · ${_statusLabel(status)}'}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      trailing: fare == null
          ? null
          : Text('${fare.round()} د',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
    );
  }
}

String _date(Object? raw) {
  final d = DateTime.tryParse('$raw')?.toLocal();
  if (d == null) return '';
  return '${d.year}/${d.month}/${d.day}';
}

String _statusLabel(String s) => switch (s) {
      'cancelled' => 'ملغاة',
      'no_drivers' => 'بلا سائق',
      'searching' => 'قيد البحث',
      _ => s,
    };
