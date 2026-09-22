import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'package:image_picker/image_picker.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../shared/delete_account_dialog.dart';
import '../shared/edit_profile_dialog.dart';
import '../trips/trip_detail_page.dart';
import '../trips/trips_page.dart' show statusLabel, fmtDateTime;
import '../../core/theme.dart';
import '../shared/ratings_section.dart';
import '../shared/adjust_balance_dialog.dart';
import '../shared/referral_card.dart';
import '../notifications/send_notification_dialog.dart';
import '../../core/perms.dart';

/// صفحة مراجعة سائق واحد — قلب لوحة التحكم.
///
/// هنا يتخذ المدير القرار الوحيد الذي لا يستطيع النظام اتخاذه عنه:
/// **هل هذا الشخص أهل لنقل الناس؟**
///
/// لذلك تعرض الصور بحجم قابل للفحص لا مصغّرات، وتضع القبول والرفض بجانب
/// كل وثيقة لا في زر واحد جامع — الوثيقة الواحدة قد تكون واضحة والأخرى
/// مشوّشة، والرفض الجامع يجبر السائق على إعادة رفع ما كان مقبولاً.
class DriverDetailPage extends ConsumerStatefulWidget {
  const DriverDetailPage({super.key, required this.driver});

  final Map<String, dynamic> driver;

  @override
  ConsumerState<DriverDetailPage> createState() => _DriverDetailPageState();
}

class _DriverDetailPageState extends ConsumerState<DriverDetailPage> {
  bool _busy = false;
  String? _error;

  String get _driverId => widget.driver['id'] as String;

  /// الصفّ الحيّ إن وصل، وإلا اللقطة التي فُتحت بها الصفحة.
  Map<String, dynamic> get _driver =>
      ref.watch(driverRowProvider(_driverId)).value ?? widget.driver;

  Map<String, dynamic> get _profile =>
      _driver['profiles'] as Map<String, dynamic>;

  /// تعديل بيانات السائق مباشرةً — نفس المربع الذي يخدم الراكب.
  ///
  /// **الحقول المشتركة وحدها.** بيانات المركبة (اللوحة واللون والنوع)
  /// تعيش في `drivers` ولها بابها: طلبات التعديل. واللوحة واللون هما ما
  /// يتعرّف بهما الراكب على سائقه في الشارع، فتغييرهما بلا مراجعة أخطر
  /// من تصحيح اسم.
  Future<void> _editProfile() async {
    final p = _profile;
    final saved = await showEditProfileDialog(
      context,
      userId: _driverId,
      fullName: p['full_name'] as String?,
      phone: p['phone'] as String?,
      address: p['address'] as String?,
      dateOfBirth: '${p['date_of_birth']}',
    );
    if (saved == true && mounted) {
      ref.invalidate(driverRowProvider(_driverId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حُفظ التعديل')),
      );
    }
  }

  /// يستبدل وثيقةً بملف يختاره المدير.
  ///
  /// **متى يُستعمل؟** يتصل سائق: «صورة بطاقتي مقلوبة» أو «رفعت صورة
  /// الدراجة الخطأ». وقبل هذا لم يملك المدير إلا أن يرفض الوثيقة ويطلب
  /// إعادة الرفع — فيبقى السائق معطّلاً حتى يتفرّغ، وربما يئس فذهب.
  ///
  /// **والحالة تعود «قيد المراجعة»** بعد الاستبدال: وثيقةٌ لم يفحصها
  /// أحد بعد. اعتمادها تلقائياً يجعل الاستبدال طريقاً لتمرير ما لم
  /// يُراجع.
  Future<void> _deleteAccount() async {
    final deleted = await showDeleteAccountDialog(
      context,
      userId: _driverId,
      fullName: '${_profile['full_name'] ?? '—'}',
    );
    if (deleted == true && mounted) {
      ref.invalidate(driverSearchProvider(''));
      Navigator.of(context).pop();
    }
  }

  Future<void> _replaceDoc(String docType) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 2000,
    );
    if (picked == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';

      await ref.read(adminRepositoryProvider).replaceDocument(
            userId: _driverId,
            docType: docType,
            bytes: bytes,
            extension: ext,
          );

      ref.invalidate(driverDocumentsProvider(_driverId));
      ref.invalidate(driverRowProvider(_driverId));
      messenger.showSnackBar(
        const SnackBar(content: Text('استُبدلت الوثيقة — وصارت قيد المراجعة')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _review(String docId, bool approve) async {
    String? notes;

    if (!approve) {
      notes = await _askRejectionReason();
      if (notes == null) return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminRepositoryProvider).reviewDocument(
            documentId: docId,
            approve: approve,
            notes: notes,
          );
      _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askRejectionReason() async {
    final ctrl = TextEditingController();
    // أسباب جاهزة تغطي الغالبية، مع حقل حر للباقي. السبب المكتوب يصل
    // للسائق في تطبيقه، فصياغته الواضحة توفّر جولة رفض ثانية.
    const presets = [
      'الصورة غير واضحة — أعد التصوير بإضاءة أفضل',
      'الصورة مقطوعة — صوّر الوثيقة كاملة',
      'الوثيقة منتهية الصلاحية',
      'البيانات لا تطابق اسم الحساب',
    ];

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('سبب الرفض'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...presets.map((p) => ListTile(
                    dense: true,
                    title: Text(p),
                    onTap: () => Navigator.pop(ctx, p),
                  )),
              const Divider(),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(labelText: 'سبب آخر'),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('رفض'),
          ),
        ],
      ),
    );
  }

  Future<void> _approveAll() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminRepositoryProvider).approveAll(_driverId);
      _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refresh() {
    ref.invalidate(driverRowProvider(_driverId));
    ref.invalidate(driverDocumentsProvider(_driverId));
    ref.invalidate(pendingDriversProvider);
    ref.invalidate(allDriversProvider);
    ref.invalidate(driverSearchProvider);
  }

  /// يشغّل فعلاً إدارياً ويعرض نتيجته. الأفعال الثلاثة تتشارك المعالجة
  /// نفسها: انشغال، ثم خطأ معروض أو رسالة نجاح، ثم تحديث.
  Future<void> _run(Future<String> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await action();
      _refresh();
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleBlock(bool blocked) async {
    String? reason;
    if (blocked) {
      reason = await _askReason(
        title: 'إيقاف عن استلام الطلبات',
        body: 'لن تصله عروض رحلات، ويبقى اعتماده ووثائقه كما هي. '
            'ترفع الإيقاف بضغطة متى شئت.',
        confirm: 'أوقفه',
        presets: const [
          'شكوى راكب قيد التحقيق',
          'رفض متكرر للرحلات',
          'مخالفة سلوك',
          'دين متراكم على المحفظة',
        ],
      );
      if (reason == null) return;
    }
    await _run(() async {
      await ref
          .read(adminRepositoryProvider)
          .setBlocked(_driverId, blocked, reason: reason);
      return blocked
          ? 'أُوقف السائق عن استلام الطلبات'
          : 'أُعيد تفعيل السائق';
    });
  }

  Future<void> _toggleApproval(bool approved) async {
    String? reason;
    if (!approved) {
      reason = await _askReason(
        title: 'إلغاء الاعتماد',
        body: 'يعود السائق إلى حالة «موقوف»: لا يتصل ولا يعمل، ويرى السبب '
            'في تطبيقه. إعادة اعتماده لاحقاً لا تحتاج رفع وثائق من جديد.',
        confirm: 'ألغِ الاعتماد',
        presets: const [
          'وثائق مشكوك في صحتها',
          'حادث أو مخالفة مرورية',
          'انتحال هوية',
          'طلب السائق إيقاف حسابه',
        ],
      );
      if (reason == null) return;
    }
    await _run(() async {
      await ref
          .read(adminRepositoryProvider)
          .setApproved(_driverId, approved, reason: reason);
      return approved ? 'أُعيد اعتماد السائق' : 'أُلغي اعتماد السائق';
    });
  }

  /// **صارت نافذةً واحدة لأربعة أفعال** — إضافة وخصم، فعليّاً وهديةً.
  ///
  /// وكان الحقن يضيف إلى الرصيد الفعلي دائماً، وهو القابل للسحب. فمنحةٌ
  /// تحفيزية تُضاف سهواً إليه تخرج نقداً من الخزينة بلا أن يلاحظ أحد.
  /// **رسالةٌ لهذا الشخص وحده.** والبثّ العام لا يغني عنها: تذكيرٌ
  /// بدَينٍ مستحق، أو تنبيهٌ على تقييمٍ منخفض، أو ردٌّ على شكوى — كلها
  /// تخصّ واحداً، وإرسالها للجميع فضيحةٌ لا تنبيه.
  Future<void> _notify() async {
    await showSendNotificationDialog(
      context,
      userId: _driverId,
      userName: '${_profile['full_name'] ?? 'السائق'}',
    );
  }

  Future<void> _adjustBalance() async {
    final saved = await showAdjustBalanceDialog(
      context,
      userId: _driverId,
      fullName: '${_profile['full_name'] ?? 'السائق'}',
      isDriver: true,
    );
    if (saved == true && mounted) {
      ref.invalidate(driverRowProvider(_driverId));
    }
  }

  /// سبب الفعل: خيارات جاهزة وحقل حر. السبب يصل السائق، فصياغته الواضحة
  /// توفّر مكالمة غاضبة.
  Future<String?> _askReason({
    required String title,
    required String body,
    required String confirm,
    required List<String> presets,
  }) async {
    final ctrl = TextEditingController();
    final out = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(body,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                ...presets.map((x) => ListTile(
                      dense: true,
                      title: Text(x),
                      onTap: () => Navigator.pop(ctx, x),
                    )),
                const Divider(),
                TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(labelText: 'سبب آخر'),
                  onSubmitted: (v) => Navigator.pop(ctx, v),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(confirm),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return out;
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final docs = ref.watch(driverDocumentsProvider(_driverId));
    final driver = _driver;
    final verification = driver['verification_status'] as String?;
    final blocked = _profile['is_blocked'] == true;
    final approved = verification == 'approved';
    // **كل زرٍّ بصلاحيته.** القاعدة ترفض ما لا يملكه، وهذا يُخفيه قبلها.
    final canAdjust = can(ref, 'wallets.adjust');
    final canReview = can(ref, 'drivers.review');
    final canSuspend = can(ref, 'drivers.suspend');
    final canEdit = can(ref, 'profiles.edit');
    final canDelete = can(ref, 'accounts.delete');

    return Scaffold(
      appBar: AppBar(
        title: Text('${_profile['full_name']}'),
        actions: [
          if (canReview && !approved && !Breaks.isCompact(context))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: _busy ? null : _approveAll,
                icon: const Icon(Icons.done_all),
                label: const Text('اعتماد كل الوثائق'),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(Breaks.pad(context)),
        children: [
          // شريط الأفعال قبل البيانات لا بعدها: المدير الذي يفتح صفحة
          // سائق ليوقفه أو يعبّئ رصيده لا يريد أن يمرّر وثائق ليصل إلى زر.
          _ActionBar(
            busy: _busy,
            approved: approved,
            blocked: blocked,
            compact: Breaks.isCompact(context),
            onApproveAll: canReview ? _approveAll : null,
            // **بلا صلاحية الشحن لا زرّ.** القاعدة ترفض أصلاً (0099).
            onTopup: canAdjust ? _adjustBalance : null,
            onToggleBlock: canSuspend ? () => _toggleBlock(!blocked) : null,
            onToggleApproval:
                canSuspend ? () => _toggleApproval(!approved) : null,
            onEditProfile: canEdit ? _editProfile : null,
            onDeleteAccount: canDelete ? _deleteAccount : null,
          ),

          if (blocked) ...[
            const SizedBox(height: 14),
            _Banner(
              icon: Icons.pause_circle_outline,
              color: AdminTheme.warning,
              title: 'موقوف عن استلام الطلبات',
              body: 'لا تصله عروض رحلات. اعتماده ووثائقه سليمة، '
                  'ورفع الإيقاف يعيده للعمل فوراً.',
            ),
          ],
          if (verification == 'suspended') ...[
            const SizedBox(height: 14),
            _Banner(
              icon: Icons.block,
              color: AdminTheme.danger,
              title: 'اعتماده ملغى',
              body: '${driver['rejection_reason'] ?? 'بلا سبب مسجّل'}',
            ),
          ],

          const SizedBox(height: 20),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _notify,
              icon: const Icon(Icons.notifications_active_outlined, size: 18),
              label: const Text('أرسل إشعاراً له'),
            ),
          ),

          const SizedBox(height: 20),
          BalanceCard(
            real: (driver['wallet_balance_iqd'] as num?) ?? 0,
            bonus: (driver['bonus_balance_iqd'] as num?) ?? 0,
            onAdjust: (_busy || !canAdjust) ? null : _adjustBalance,
          ),

          const SizedBox(height: 20),
          ReferralCard(userId: _driverId),

          const SizedBox(height: 20),
          _InfoCard(profile: _profile, driver: driver),

          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: DriverLedger(driverId: widget.driver['id'] as String),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(_error!,
                  style:
                      TextStyle(color: theme.colorScheme.onErrorContainer)),
            ),
          ],

          const SizedBox(height: 28),
          RatingsSection(userId: _driverId),

          const SizedBox(height: 28),
          Text('الوثائق',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),

          docs.when(
            loading: () =>
                const Center(child: Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(),
            )),
            error: (e, _) => SelectableText('تعذّر تحميل الوثائق: $e'),
            data: (list) {
              if (list.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('لم يرفع السائق أي وثيقة بعد')),
                  ),
                );
              }
              return Column(
                children: list
                    .map((d) => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _DocumentCard(
                            doc: d,
                            busy: _busy,
                            onApprove: canReview
                                ? () => _review(d['id'] as String, true)
                                : null,
                            onReject: canReview
                                ? () => _review(d['id'] as String, false)
                                : null,
                            onReplace: canEdit
                                ? () => _replaceDoc(d['doc_type'] as String)
                                : null,
                          ),
                        ))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

// =============================================================================
/// أفعال المدير الثلاثة على سائق: التعبئة، والإيقاف، وإلغاء الاعتماد.
///
/// **مرتّبة من الأخفّ إلى الأثقل، لا بالعكس.** التعبئة فعل يومي، وإلغاء
/// الاعتماد فعل نادر لا يجوز أن يقع تحت الإبهام سهواً — فهو آخر الصفّ
/// وبلون التحذير.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.busy,
    required this.approved,
    required this.blocked,
    required this.compact,
    required this.onApproveAll,
    required this.onTopup,
    required this.onToggleBlock,
    required this.onToggleApproval,
    required this.onEditProfile,
    required this.onDeleteAccount,
  });

  final bool busy;
  final bool approved;
  final bool blocked;
  final bool compact;
  final VoidCallback? onApproveAll;
  /// `null` = لا يملك صلاحية الشحن، فلا يظهر الزرّ.
  final VoidCallback? onTopup;
  // `null` = لا يملك الصلاحية، فلا يظهر الزرّ.
  final VoidCallback? onToggleBlock;
  final VoidCallback? onToggleApproval;
  final VoidCallback? onEditProfile;
  final VoidCallback? onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        if (onTopup != null)
          FilledButton.icon(
            onPressed: busy ? null : onTopup,
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: const Text('تعبئة رصيد'),
          ),

        if (onEditProfile != null)
          OutlinedButton.icon(
            onPressed: busy ? null : onEditProfile,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('تعديل البيانات'),
          ),

        if (onDeleteAccount != null)
          OutlinedButton.icon(
            onPressed: busy ? null : onDeleteAccount,
            icon: const Icon(Icons.delete_outline),
            label: const Text('حذف الحساب'),
            style:
                OutlinedButton.styleFrom(foregroundColor: AdminTheme.danger),
          ),

        if (onApproveAll != null && !approved && compact)
          FilledButton.icon(
            onPressed: busy ? null : onApproveAll,
            icon: const Icon(Icons.done_all),
            label: const Text('اعتماد كل الوثائق'),
          ),

        // الإيقاف متاح للمعتمَد وحده: إيقاف من لا يعمل أصلاً بلا معنى.
        if (onToggleBlock != null && approved)
          OutlinedButton.icon(
            onPressed: busy ? null : onToggleBlock,
            icon: Icon(blocked
                ? Icons.play_circle_outline
                : Icons.pause_circle_outline),
            label: Text(blocked ? 'رفع الإيقاف' : 'إيقاف عن الطلبات'),
            style: OutlinedButton.styleFrom(
              foregroundColor: blocked ? AdminTheme.success : AdminTheme.warning,
            ),
          ),

        if (onToggleApproval != null && approved)
          OutlinedButton.icon(
            onPressed: busy ? null : onToggleApproval,
            icon: const Icon(Icons.gpp_bad_outlined),
            label: const Text('إلغاء الاعتماد'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),

        if (onToggleApproval != null && !approved)
          FilledButton.tonalIcon(
            onPressed: busy ? null : onToggleApproval,
            icon: const Icon(Icons.verified_outlined),
            label: const Text('اعتماد السائق'),
          ),

        if (busy)
          const Padding(
            padding: EdgeInsets.all(10),
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2)),
          ),
      ],
    );
  }
}

/// شريط حالة يشرح ما يراه المدير قبل أن يسأل عنه.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold, color: color)),
                const SizedBox(height: 2),
                Text(body, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.profile, required this.driver});

  final Map<String, dynamic> profile;
  final Map<String, dynamic> driver;

  @override
  Widget build(BuildContext context) {
    final status = driver['verification_status'] as String?;
    final wallet = (driver['wallet_balance_iqd'] as num?)?.toDouble() ?? 0;

    final dob = DateTime.tryParse('${profile['date_of_birth']}');
    final age = dob == null
        ? null
        : DateTime.now().difference(dob).inDays ~/ 365;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          spacing: 40,
          runSpacing: 16,
          children: [
            _Field('الاسم', '${profile['full_name']}'),
            _Field('الهاتف', '${profile['phone']}', ltr: true),
            _Field('البريد', '${profile['email']}', ltr: true),
            _Field('العنوان', '${profile['address']}'),
            if (age != null) _Field('العمر', '$age سنة'),
            // **المركبة قبل وصفها.** سائق الستوتة لا يحمل ركّاباً ولا
            // يتسوّق (0105)، فمن يراجع وثائقه يجب أن يعرف ذلك أولاً.
            _Field('المركبة', switch (driver['vehicle_kind']) {
              'tuktuk' => 'تكتك',
              'stoota' => 'ستوتة — توصيل المتاجر فقط',
              _ => 'دراجة نارية',
            }),
            _Field('نوع المركبة', '${driver['vehicle_type'] ?? '—'}'),
            // اللوحة واللون يكتبهما السائق عند التسجيل — طابقهما بصور
            // الدراجة قبل الاعتماد، فهما ما يميّز الراكبُ الدراجةَ بهما.
            _Field('رقم اللوحة', '${driver['vehicle_plate'] ?? '—'}', ltr: true),
            _Field('لون المركبة', '${driver['vehicle_color'] ?? '—'}'),
            _Field('الحالة', _statusLabel(status),
                color: _statusColor(status)),
            if (profile['is_blocked'] == true)
              _Field('استلام الطلبات', 'موقوف', color: AdminTheme.warning),
            _Field(
              'المحفظة',
              wallet < 0
                  ? 'عليه ${wallet.abs().round()} دينار'
                  : '${wallet.round()} دينار',
              color: wallet < 0 ? AdminTheme.warning : null,
            ),
            _Field('رحلات مكتملة', '${driver['trips_completed'] ?? 0}'),
            _Field('التقييم',
                (driver['rating_avg'] as num?)?.toStringAsFixed(1) ?? '—'),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(String? s) => switch (s) {
        'approved' => 'معتمد',
        'rejected' => 'مرفوض',
        'suspended' => 'موقوف',
        _ => 'قيد المراجعة',
      };

  static Color? _statusColor(String? s) => switch (s) {
        'approved' => AdminTheme.success,
        'rejected' || 'suspended' => AdminTheme.danger,
        _ => AdminTheme.warning,
      };
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
class _DocumentCard extends ConsumerWidget {
  const _DocumentCard({
    required this.doc,
    required this.busy,
    required this.onApprove,
    required this.onReject,
    required this.onReplace,
  });

  final Map<String, dynamic> doc;
  final bool busy;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onReplace;

  static const _labels = {
    'live_selfie': 'صورة حية للوجه',
    'national_id_front': 'وجه البطاقة الوطنية',
    'national_id_back': 'ظهر البطاقة الوطنية',
    'vehicle_photo': 'صورة المركبة',
    'driving_license': 'إجازة السوق',
    'vehicle_registration': 'سنوية المركبة',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final type = doc['doc_type'] as String;
    final status = doc['status'] as String;
    final path = doc['storage_path'] as String;

    final (badgeColor, badgeText) = switch (status) {
      'approved' => (AdminTheme.success, 'مقبولة'),
      'rejected' => (AdminTheme.danger, 'مرفوضة'),
      _ => (AdminTheme.warning, 'قيد المراجعة'),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_labels[type] ?? type,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(badgeText,
                      style: TextStyle(
                          color: badgeColor, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            if (doc['review_notes'] != null) ...[
              const SizedBox(height: 8),
              Text('ملاحظة: ${doc['review_notes']}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AdminTheme.danger)),
            ],
            const SizedBox(height: 14),

            // الصورة بحجم قابل للفحص لا مصغّرة — القرار يُتخذ بالنظر إليها
            _DocImage(path: path),

            const SizedBox(height: 14),
            Row(
              children: [
                Text(
                  DateFormat('d MMM y — HH:mm', 'ar')
                      .format(DateTime.parse('${doc['created_at']}').toLocal()),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const Spacer(),
                if (onReject != null && status != 'rejected')
                  TextButton.icon(
                    onPressed: busy ? null : onReject,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('رفض'),
                    style: TextButton.styleFrom(
                        foregroundColor: AdminTheme.danger),
                  ),
                const SizedBox(width: 8),

                // **الاستبدال بجانب القبول والرفض لا في قائمة مخفية.**
                // من يفحص وثيقة مقلوبة يحتاج الإصلاح في اللحظة نفسها،
                // لا أن يبحث عنه في مكان آخر بعد أن يغلق الصفحة.
                if (onReplace != null)
                  OutlinedButton.icon(
                    onPressed: busy ? null : onReplace,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('استبدال'),
                  ),
                const SizedBox(width: 8),

                if (onApprove != null && status != 'approved')
                  FilledButton.icon(
                    onPressed: busy ? null : onApprove,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('قبول'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// يعرض صورة من البكت الخاص عبر رابط موقّع.
class _DocImage extends ConsumerWidget {
  const _DocImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final urlFuture = ref.watch(_signedUrlProvider(path));

    return Container(
      height: 320,
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: urlFuture.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('تعذّر تحميل الصورة\n$e', textAlign: TextAlign.center),
          ),
        ),
        data: (url) => InteractiveViewer(
          // التكبير ضروري: أرقام البطاقة الوطنية صغيرة، والقرار يعتمد
          // على قراءتها لا على رؤية الصورة عموماً.
          maxScale: 5,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                const Center(child: Text('تعذّر عرض الصورة')),
          ),
        ),
      ),
    );
  }
}

final _signedUrlProvider =
    FutureProvider.family<String, String>((ref, path) async {
  return ref.watch(adminRepositoryProvider).signedUrl(path);
});


// =============================================================================
// سجلّ السائق: رحلاته وسحوباته وتعبئاته
// =============================================================================
final driverTripsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).driverTrips(id),
);
final driverPayoutsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).driverPayouts(id),
);
final driverTopupsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, id) => ref.watch(adminRepositoryProvider).driverTopups(id),
);

/// سجلّ السائق في ثلاثة تبويبات.
///
/// **تبويبات لا قائمة واحدة طويلة.** الأسئلة الثلاثة تُسأل في أوقات
/// مختلفة: "كم عمل؟" و"كم طلب سحبه؟" و"متى عبّأ؟" — وخلطها يجعل كلاً
/// منها أصعب.
class DriverLedger extends ConsumerWidget {
  const DriverLedger({super.key, required this.driverId});
  final String driverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trips = ref.watch(driverTripsProvider(driverId));
    final payouts = ref.watch(driverPayoutsProvider(driverId));
    final topups = ref.watch(driverTopupsProvider(driverId));

    final topupCount = topups.value?.length ?? 0;
    final topupSum = (topups.value ?? const [])
        .fold<num>(0, (a, r) => a + ((r['amount_iqd'] as num?) ?? 0));

    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            tabs: [
              Tab(text: 'الرحلات (${trips.value?.length ?? 0})'),
              Tab(text: 'طلبات السحب (${payouts.value?.length ?? 0})'),
              Tab(text: 'التعبئات ($topupCount)'),
            ],
          ),
          SizedBox(
            height: 420,
            child: TabBarView(
              children: [
                _list(trips, (t) {
                  final fare =
                      (t['fare_final_iqd'] ?? t['fare_estimated_iqd']) as num?;
                  return ListTile(
                    dense: true,
                    leading: Text('${t['trip_number'] ?? '—'}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    title: Text(
                      '${t['pickup_address'] ?? '—'} ← ${t['dropoff_address'] ?? '—'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${statusLabel('${t['status']}')}  ·  '
                      '${fmtDateTime(t['requested_at'])}',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: fare == null
                        ? null
                        : Text('${fare.round()} د',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          TripDetailPage(tripId: t['id'] as String),
                    )),
                  );
                }, 'لا رحلات بعد'),

                _list(payouts, (r) {
                  final st = '${r['status']}';
                  return ListTile(
                    dense: true,
                    leading: Icon(switch (st) {
                      'paid' => Icons.check_circle,
                      'rejected' => Icons.cancel,
                      _ => Icons.hourglass_top,
                    }),
                    title: Text('${(r['amount_iqd'] as num).round()} دينار'),
                    subtitle: Text(
                      'طُلب ${fmtDateTime(r['requested_at'])}'
                      '${r['processed_at'] != null ? '  ·  عُولج ${fmtDateTime(r['processed_at'])}' : ''}'
                      '${'${r['admin_note'] ?? ''}'.isEmpty ? '' : '  ·  ${r['admin_note']}'}',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: Text(switch (st) {
                      'paid' => 'مدفوع',
                      'rejected' => 'مرفوض',
                      _ => 'معلّق',
                    }),
                  );
                }, 'لا طلبات سحب'),

                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'عبّأ $topupCount مرة بمجموع ${topupSum.round()} دينار',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Expanded(
                      child: _list(topups, (r) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.confirmation_number),
                            title: SelectableText('${r['code']}',
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 15)),
                            subtitle: Text(
                              'عُبّئ ${fmtDateTime(r['redeemed_at'])}'
                              '${'${r['batch_note'] ?? ''}'.isEmpty ? '' : '  ·  ${r['batch_note']}'}',
                              style: theme.textTheme.bodySmall,
                            ),
                            trailing: Text(
                                '${(r['amount_iqd'] as num).round()} د',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ), 'لا تعبئات بعد'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(
    AsyncValue<List<Map<String, dynamic>>> async,
    Widget Function(Map<String, dynamic>) row,
    String empty,
  ) =>
      async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? Center(child: Text(empty))
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => row(list[i]),
              ),
      );
}
