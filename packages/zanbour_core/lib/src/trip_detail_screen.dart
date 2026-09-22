import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'errors.dart';
import 'rating_view.dart';

/// تفاصيل رحلةٍ ماضية — للراكب والسائق معاً.
///
/// **بلا هاتفٍ ولا عنوانٍ للطرف الآخر.** بعد انتهاء الرحلة لم يبقَ سببٌ
/// لأن يعرف أحدهما كيف يصل إلى الآخر خارج التطبيق. والاسم والتقييم
/// يكفيان ليتذكّر من كان معه.
///
/// **ومنها يُقيَّم ما فات.** من ضغط «لاحقاً» يوم الرحلة يجد الباب
/// مفتوحاً هنا؛ ومن قيّم يجد تقييمه مثبَّتاً لا يُعاد.
class TripDetailScreen extends ConsumerStatefulWidget {
  const TripDetailScreen({super.key, required this.tripId});

  final String tripId;

  @override
  ConsumerState<TripDetailScreen> createState() => _TripDetailState();
}

class _TripDetailState extends ConsumerState<TripDetailScreen> {
  Map<String, dynamic>? _t;
  String? _error;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await _sb
          .rpc('my_trip_detail', params: {'p_trip_id': widget.tripId});
      if (mounted) setState(() => _t = (v as Map).cast<String, dynamic>());
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    }
  }

  Future<void> _rate() async {
    final t = _t!;
    final other = (t['other'] as Map?)?.cast<String, dynamic>();
    if (other == null) return;

    final rateeId = await _rateeId();
    if (rateeId == null || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => RatingView(
          title: 'تقييم متأخّر',
          subtitle: 'الرحلة رقم ${t['trip_number']} · ${other['name']}',
          onSubmit: (stars, comment, tags, amount) async {
            await _sb.from('ratings').insert({
              'trip_id': widget.tripId,
              'rater_id': _sb.auth.currentUser?.id,
              'ratee_id': rateeId,
              'stars': stars,
              'comment':
                  (comment ?? '').trim().isEmpty ? null : comment!.trim(),
              'tags': tags,
              'reported_change_iqd': ?amount,
            });
            if (ctx.mounted) Navigator.pop(ctx);
          },
          onSkip: () => Navigator.pop(ctx),
        ),
      ),
    );
    _load();
  }

  /// **معرّف الطرف الآخر يُقرأ من الرحلة لا من الشاشة.** الشاشة تعرض
  /// اسماً بلا معرّف عمداً؛ فنقرؤه من الصفّ الذي تسمح به السياسة.
  Future<String?> _rateeId() async {
    final row = await _sb
        .from('trips')
        .select('rider_id, driver_id')
        .eq('id', widget.tripId)
        .maybeSingle();
    if (row == null) return null;
    return _t!['i_am_rider'] == true
        ? row['driver_id'] as String?
        : row['rider_id'] as String?;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = _t;

    return Scaffold(
      appBar: AppBar(
        title: Text(t == null ? 'الرحلة' : 'الرحلة ${t['trip_number']}'),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : t == null
              ? const Center(child: CircularProgressIndicator())
              : _body(theme, t),
    );
  }

  Widget _body(ThemeData theme, Map<String, dynamic> t) {
    final other = (t['other'] as Map?)?.cast<String, dynamic>();
    final rated = t['rated'] == true;
    final iAmRider = t['i_am_rider'] == true;
    final change = (t['change'] as num?) ?? 0;
    final completed = t['status'] == 'completed';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        if (other != null) ...[
          Card(
            child: ListTile(
              leading: CircleAvatar(
                radius: 26,
                backgroundImage: (other['avatar'] as String?) == null
                    ? null
                    : NetworkImage('${other['avatar']}'),
                child: (other['avatar'] as String?) == null
                    ? const Icon(Icons.person)
                    : null,
              ),
              title: Text('${other['name'] ?? '—'}'),
              subtitle: iAmRider
                  ? Text([
                      if (other['rating'] != null)
                        '★ ${(other['rating'] as num).toStringAsFixed(1)}',
                      if (other['vehicle'] != null) '${other['vehicle']}',
                      if (other['color'] != null) '${other['color']}',
                      if (other['plate'] != null) '${other['plate']}',
                    ].join(' · '))
                  : null,
            ),
          ),
          const SizedBox(height: 16),
        ],

        _Card('المسار', [
          _Line('من', '${t['pickup'] ?? '—'}'),
          _Line('إلى', '${t['dropoff'] ?? '—'}'),
          if (t['distance_m'] != null)
            _Line('المسافة',
                '${((t['distance_m'] as num) / 1000).toStringAsFixed(1)} كم'),
          _Line('الوقت', _when(t['completed_at'] ?? t['requested_at'])),
        ]),

        const SizedBox(height: 16),
        _Card('الحساب', [
          _Line('الأجرة', _iqd(t['fare'])),
          if (((t['discount'] as num?) ?? 0) > 0)
            _Line('التخفيض', '− ${_iqd(t['discount'])}'),
          if (((t['credit_used'] as num?) ?? 0) > 0)
            _Line('من رصيدك', '− ${_iqd(t['credit_used'])}'),
          if (t['cash_due'] != null) _Line('نقداً', _iqd(t['cash_due'])),
          if (t['cash_received'] != null)
            _Line('سلّم', _iqd(t['cash_received'])),
          if (!iAmRider && t['earning'] != null)
            _Line('حصّتك', _iqd(t['earning'])),
        ]),

        // **الباقي مذكورٌ صراحةً.** رصيدٌ زاد بلا سببٍ مكتوب يُنسى، ثم
        // يُتّهم أحدهم بأنه لم يُعِده.
        if (change > 0) ...[
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      iAmRider
                          ? 'أُعيد ${change.round()} دينار إلى محفظتك'
                          : 'أرجعتَ ${change.round()} دينار إلى محفظة الراكب',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (completed && other != null) ...[
          const SizedBox(height: 24),
          if (rated)
            // **مثبَّتٌ لا معطَّل بلا سبب.** زرٌّ رماديّ بلا كلمة يجعل
            // صاحبه يضغطه مراراً ثم يظنّ التطبيق معطوباً.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle,
                    size: 18, color: Colors.green.shade600),
                const SizedBox(width: 8),
                Text('قيّمتَ هذه الرحلة',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            )
          else
            FilledButton.icon(
              onPressed: _rate,
              icon: const Icon(Icons.star_outline),
              label: const Text('قيّم الآن'),
            ),
        ],
      ],
    );
  }
}

String _iqd(Object? v) =>
    v == null ? '—' : '${(v as num).round()} دينار';

String _when(Object? raw) {
  final d = DateTime.tryParse('$raw')?.toLocal();
  if (d == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _Card extends StatelessWidget {
  const _Card(this.title, this.lines);
  final String title;
  final List<Widget> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            ...lines,
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
