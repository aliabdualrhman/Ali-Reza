import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';
import '../shared/ratings_section.dart';
import '../shared/delete_account_dialog.dart';
import '../shared/edit_profile_dialog.dart';
import '../trips/trip_detail_page.dart';
import '../trips/trips_page.dart' show statusLabel, fmtDateTime;
import '../shared/adjust_balance_dialog.dart';
import '../shared/referral_card.dart';
import '../notifications/send_notification_dialog.dart';
import '../../core/perms.dart';

/// بطاقة راكب واحد — بياناته وإحصاءاته ورحلاته.
///
/// **لماذا احتجناها؟** كان الراكب يظهر اسماً عابراً داخل صفّ رحلة، فلا
/// يستطيع المدير أن يجيب سؤالاً بسيطاً حين يتصل أحدهم يشكو: من هذا؟ كم
/// رحلة ألغى؟ متى آخر مرة استعمل التطبيق؟
class RiderDetailPage extends ConsumerStatefulWidget {
  const RiderDetailPage({super.key, required this.rider});

  final Map<String, dynamic> rider;

  @override
  ConsumerState<RiderDetailPage> createState() => _RiderDetailPageState();
}

class _RiderDetailPageState extends ConsumerState<RiderDetailPage> {
  bool _busy = false;
  String? _error;

  String get _id => widget.rider['id'] as String;

  /// الصفّ الحيّ إن وصل، وإلا اللقطة التي فُتحت بها الصفحة.
  Map<String, dynamic> get _rider =>
      ref.watch(riderRowProvider(_id)).value ?? widget.rider;

  Future<void> _edit() async {
    final r = _rider;
    final saved = await showEditProfileDialog(
      context,
      userId: _id,
      fullName: r['full_name'] as String?,
      phone: r['phone'] as String?,
      address: r['address'] as String?,
      dateOfBirth: '${r['date_of_birth']}',
    );
    if (saved == true && mounted) {
      ref.invalidate(riderRowProvider(_id));
      ref.invalidate(riderSearchProvider(''));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حُفظ التعديل')),
      );
    }
  }

  /// **محفظة الراكب مفهوم جديد** (0052) — لم يكن له رصيد إطلاقاً قبلها.
  /// رسالةٌ لهذا الراكب وحده — ردّاً على شكوى أو تنبيهاً على إلغاءات.
  Future<void> _notify() async {
    await showSendNotificationDialog(
      context,
      userId: _id,
      userName: '${_rider['full_name'] ?? 'الراكب'}',
    );
  }

  Future<void> _adjustBalance() async {
    final saved = await showAdjustBalanceDialog(
      context,
      userId: _id,
      fullName: '${_rider['full_name'] ?? 'الراكب'}',
      isDriver: false,
    );
    if (saved == true && mounted) {
      ref.invalidate(riderWalletProvider(_id));
    }
  }

  Future<void> _delete() async {
    final deleted = await showDeleteAccountDialog(
      context,
      userId: _id,
      fullName: '${_rider['full_name'] ?? '—'}',
    );
    if (deleted == true && mounted) {
      ref.invalidate(riderSearchProvider(''));
      Navigator.of(context).pop();   // لا معنى لبقاء بطاقة حسابٍ حُذف
    }
  }

  Future<void> _toggleBlock() async {
    final blocked = _rider['is_blocked'] == true;
    final messenger = ScaffoldMessenger.of(context);

    String? reason;
    if (!blocked) {
      reason = await _askReason();
      if (reason == null) return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(adminRepositoryProvider)
          .setProfileBlocked(_id, !blocked, reason: reason);
      ref.invalidate(riderRowProvider(_id));
      messenger.showSnackBar(SnackBar(
        content: Text(blocked ? 'رُفع الإيقاف' : 'أُوقف الحساب'),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// **السبب مطلوب لا اختياري.** إيقاف بلا سبب مكتوب يصير لغزاً بعد
  /// شهر — لا المدير يتذكّر ولا الراكب يُخبَر لماذا.
  Future<String?> _askReason() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إيقاف الحساب'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 420),
          child: TextField(
            controller: ctl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'سبب الإيقاف',
              hintText: 'إلغاءات متكررة، إساءة للسائقين، بلاغ…',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('أوقفه')),
        ],
      ),
    );
    final text = ctl.text.trim();
    ctl.dispose();
    return ok == true && text.isNotEmpty ? text : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _rider;
    final blocked = r['is_blocked'] == true;

    return Scaffold(
      appBar: AppBar(
        title: Text('${r['full_name'] ?? 'راكب'}'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(riderRowProvider(_id));
              ref.invalidate(riderTripsProvider(_id));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (blocked)
            Card(
              color: AdminTheme.danger.withValues(alpha: 0.12),
              child: ListTile(
                leading: Icon(Icons.block, color: AdminTheme.danger),
                title: const Text('هذا الحساب موقوف'),
                subtitle: const Text('لا يستطيع صاحبه طلب رحلات.'),
              ),
            ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            SelectableText(_error!,
                style: TextStyle(color: theme.colorScheme.error)),
          ],

          const SizedBox(height: 12),
          _Balance(
            riderId: _id,
            // **بلا صلاحية الشحن لا زرّ.** القاعدة ترفض أصلاً.
            onAdjust: (_busy || !can(ref, 'wallets.adjust'))
                ? null
                : _adjustBalance,
          ),

          const SizedBox(height: 16),
          ReferralCard(userId: _id),

          const SizedBox(height: 16),
          _InfoCard(rider: r),

          const SizedBox(height: 24),
          RatingsSection(userId: _id),

          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              // **كل زرٍّ بصلاحيته** — والقاعدة ترفض ما لا يملكه.
              if (can(ref, 'profiles.edit'))
                FilledButton.icon(
                  onPressed: _busy ? null : _edit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('تعديل البيانات'),
                ),
              if (can(ref, 'notifications.send'))
                OutlinedButton.icon(
                  onPressed: _busy ? null : _notify,
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('أرسل إشعاراً'),
                ),
              if (can(ref, 'accounts.delete'))
                OutlinedButton.icon(
                  onPressed: _busy ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف الحساب'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AdminTheme.danger),
                ),
              if (can(ref, 'profiles.edit'))
              OutlinedButton.icon(
                onPressed: _busy ? null : _toggleBlock,
                icon: Icon(blocked ? Icons.lock_open : Icons.block),
                label: Text(blocked ? 'رفع الإيقاف' : 'إيقاف الحساب'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: blocked ? null : AdminTheme.danger,
                ),
              ),
            ],
          ),

          const SizedBox(height: 28),
          Text('رحلاته', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          _Trips(riderId: _id),
        ],
      ),
    );
  }
}

// =============================================================================
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.rider});

  final Map<String, dynamic> rider;

  @override
  Widget build(BuildContext context) {
    final dob = DateTime.tryParse('${rider['date_of_birth']}');
    final age =
        dob == null ? null : DateTime.now().difference(dob).inDays ~/ 365;

    final total = (rider['trips_total'] as num?)?.toInt() ?? 0;
    final done = (rider['trips_completed'] as num?)?.toInt() ?? 0;
    final cancelled = (rider['trips_cancelled'] as num?)?.toInt() ?? 0;
    final spent = (rider['spent_iqd'] as num?)?.toInt() ?? 0;

    // **نسبة الإلغاء لا عدده.** راكب ألغى عشراً من مئة غير من ألغى
    // عشراً من اثنتي عشرة — والعدد وحده يساوي بينهما.
    final rate = total == 0 ? 0 : (cancelled * 100 / total).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          spacing: 40,
          runSpacing: 16,
          children: [
            _Field('الاسم', '${rider['full_name'] ?? '—'}'),
            _Field('الهاتف', '${rider['phone'] ?? '—'}', ltr: true),
            _Field('البريد', '${rider['email'] ?? '—'}', ltr: true),
            _Field('العنوان', '${rider['address'] ?? '—'}'),
            if (age != null) _Field('العمر', '$age سنة'),
            _Field('انضمّ في', fmtDateTime(rider['created_at'])),
            _Field('إجمالي الرحلات', '$total'),
            _Field('مكتملة', '$done'),
            _Field(
              'ملغاة',
              total == 0 ? '$cancelled' : '$cancelled  ($rate٪)',
              color: rate >= 30 ? AdminTheme.warning : null,
            ),
            _Field('أنفق', '$spent دينار'),
            _Field(
              'آخر رحلة',
              rider['last_trip_at'] == null
                  ? '—'
                  : fmtDateTime(rider['last_trip_at']),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.ltr = false, this.color});

  final String label;
  final String value;
  final bool ltr;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        SelectableText(
          value,
          textDirection: ltr ? TextDirection.ltr : null,
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600, color: color),
        ),
      ],
    );
  }
}

// =============================================================================
class _Trips extends ConsumerWidget {
  const _Trips({required this.riderId});

  final String riderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trips = ref.watch(riderTripsProvider(riderId));
    final theme = Theme.of(context);

    return trips.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => SelectableText('تعذّر التحميل: $e'),
      data: (list) {
        if (list.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text('لم يطلب رحلةً بعد',
                    style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
          );
        }

        return Column(
          children: [
            for (final t in list)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: TripCodeBadge(number: t['trip_number']),
                  title: Text(
                    '${t['pickup_address'] ?? '—'}  ←  '
                    '${t['dropoff_address'] ?? '—'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${fmtDateTime(t['requested_at'])} · '
                    '${statusLabel('${t['status']}')}'
                    '${t['driver_name'] == null ? '' : ' · ${t['driver_name']}'}',
                  ),
                  trailing: t['fare_final'] == null
                      ? null
                      : Text('${t['fare_final']} د',
                          style: theme.textTheme.titleMedium),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          TripDetailPage(tripId: t['id'] as String),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// =============================================================================
/// رصيد الراكب. **يُحمَّل على حدة لا مع صفّه** — المحفظة تُنشأ عند أول
/// منحة، فأكثر الركّاب بلا صفٍّ فيها، ووصلُها بالصفّ يجعل كل قراءة
/// تحمل جدولاً فارغاً.
class _Balance extends ConsumerWidget {
  const _Balance({required this.riderId, this.onAdjust});

  final String riderId;
  final VoidCallback? onAdjust;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(riderWalletProvider(riderId));

    return w.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SelectableText('تعذّر قراءة الرصيد: $e'),
        ),
      ),
      data: (row) => BalanceCard(
        real: (row?['real_balance_iqd'] as num?) ?? 0,
        bonus: (row?['bonus_balance_iqd'] as num?) ?? 0,
        bonusExpiresAt: DateTime.tryParse('${row?['bonus_expires_at']}'),
        onAdjust: onAdjust,
      ),
    );
  }
}
