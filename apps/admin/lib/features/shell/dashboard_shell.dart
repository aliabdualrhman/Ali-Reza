import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../../core/perms.dart';
import '../../core/theme.dart';
import '../drivers/driver_detail_page.dart';
import '../coupons/coupons_page.dart';
import '../dashboard/dashboard_page.dart';
import '../requests/change_requests_page.dart';
import '../riders/rider_detail_page.dart';
import '../shared/create_account_dialog.dart';
import '../staff/staff_page.dart';
import '../stores/stores_page.dart';
import '../trips/trips_page.dart';
import '../zones/zones_page.dart';
import '../settings/settings_page.dart';
import '../wallet/payouts_page.dart';
import '../wallet/topup_codes_page.dart';
import '../growth/acquisition_page.dart';
import '../incentives/incentives_page.dart';
import '../notifications/notifications_page.dart';

/// الهيكل الرئيسي للوحة: شريط جانبي وصفحات.
///
/// **لماذا شريط جانبي لا تبويبات؟** اللوحة تُستعمل على شاشة عريضة، والشريط
/// يبقى ظاهراً فيرى المدير عدد السائقين المنتظرين وهو يتصفح الرحلات — وهذا
/// الرقم هو ما يجب ألا يغيب عن عينه.
class DashboardShell extends ConsumerStatefulWidget {
  const DashboardShell({super.key});

  @override
  ConsumerState<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends ConsumerState<DashboardShell> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = ref.watch(isAdminProvider);
    final pending = ref.watch(pendingDriversProvider);
    final pendingCount = pending.value?.length ?? 0;
    final changeCount = ref.watch(pendingChangeCountProvider).value ?? 0;
    final storesCount = ref.watch(storesAwaitingProvider).value ?? 0;

    // فحص عرض لا فحص أمان: الحماية الفعلية في سياسات RLS. نعرض رسالة
    // مفهومة بدل جداول فارغة تحيّر من فتحها بحساب عادي.
    if (isAdmin.value == false) {
      return _NotAdmin(onSignOut: () {
        ref.read(adminRepositoryProvider).signOut();
      });
    }

    final compact = Breaks.isCompact(context);

    // **كل صفحةٍ بصلاحيتها.** من لا يملكها لا يراها في القائمة أصلاً —
    // لا صفحةً يفتحها فيجدها فارغة. و«المستخدمون» للمالك وحده: من يوزّع
    // الصلاحيات يملكها كلّها.
    final all = <_Nav>[
      _Nav(const Icon(Icons.dashboard_outlined), const Icon(Icons.dashboard),
          'اللوحة', const DashboardPage(), can(ref, 'dashboard.view')),
      _Nav(
        Badge(
          isLabelVisible: pendingCount > 0,
          label: Text('$pendingCount'),
          child: const Icon(Icons.pending_actions),
        ),
        const Icon(Icons.pending_actions),
        'المراجعة',
        const _PendingPage(),
        can(ref, 'drivers.review'),
      ),
      _Nav(const Icon(Icons.people_outline), const Icon(Icons.people),
          'السائقون', const _AllDriversPage(), can(ref, 'drivers.view')),
      _Nav(const Icon(Icons.person_outline), const Icon(Icons.person),
          'الركّاب', const _RidersPage(), can(ref, 'riders.view')),
      _Nav(
        Badge(
          isLabelVisible: changeCount > 0,
          label: Text('$changeCount'),
          child: const Icon(Icons.edit_note_outlined),
        ),
        const Icon(Icons.edit_note),
        'طلبات التعديل',
        const ChangeRequestsPage(),
        can(ref, 'profiles.review'),
      ),
      _Nav(const Icon(Icons.route_outlined), const Icon(Icons.route),
          'الرحلات', const TripsPage(), can(ref, 'trips.view')),
      _Nav(
          const Icon(Icons.confirmation_number_outlined),
          const Icon(Icons.confirmation_number),
          'رموز التعبئة',
          const TopupCodesPage(),
          canAny(ref, ['topups.view', 'topups.generate', 'topups.delete'])),
      _Nav(const Icon(Icons.payments_outlined), const Icon(Icons.payments),
          'طلبات السحب', const PayoutsPage(),
          canAny(ref, ['payouts.view', 'payouts.process'])),
      _Nav(const Icon(Icons.local_offer_outlined), const Icon(Icons.local_offer),
          'الكوبونات', const CouponsPage(),
          canAny(ref, ['coupons.view', 'coupons.manage'])),
      _Nav(const Icon(Icons.settings_outlined), const Icon(Icons.settings),
          'الإعدادات', const SettingsPage(),
          canAny(ref, ['settings.view', 'settings.manage'])),
      _Nav(const Icon(Icons.map_outlined), const Icon(Icons.map), 'المناطق',
          const ZonesPage(), canAny(ref, ['settings.view', 'settings.manage'])),
      _Nav(const Icon(Icons.insights_outlined), const Icon(Icons.insights),
          'قنوات الوصول', const AcquisitionPage(), can(ref, 'growth.view')),
      _Nav(
          const Icon(Icons.notifications_outlined),
          const Icon(Icons.notifications),
          'الإشعارات',
          const NotificationsPage(),
          canAny(ref, ['notifications.view', 'notifications.send'])),
      _Nav(
        Badge(
          isLabelVisible: storesCount > 0,
          label: Text('$storesCount'),
          child: const Icon(Icons.storefront_outlined),
        ),
        const Icon(Icons.storefront),
        'المتاجر',
        const StoresPage(),
        canAny(ref, ['stores.review', 'deliveries.settle']),
      ),
      _Nav(
          const Icon(Icons.emoji_events_outlined),
          const Icon(Icons.emoji_events),
          'الحوافز',
          const IncentivesPage(),
          canAny(ref, ['incentives.view', 'incentives.manage'])),
      _Nav(
          const Icon(Icons.manage_accounts_outlined),
          const Icon(Icons.manage_accounts),
          'المستخدمون',
          const StaffPage(),
          isOwner(ref)),
    ];
    final navs = [for (final n in all) if (n.visible) n];

    // **الصلاحيات لم تصل بعد، أو لا صلاحية إطلاقاً.** الأولى لحظة، والثانية
    // موظفٌ أُضيف ولم يُعطَ شيئاً — يرى رسالةً لا لوحةً فارغة.
    final permsLoaded = ref.watch(myPermissionsProvider).hasValue &&
        ref.watch(isOwnerProvider).hasValue;
    if (navs.isEmpty) {
      return Scaffold(
        body: Center(
          child: permsLoaded
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 56),
                    const SizedBox(height: 12),
                    const Text('لم تُمنح أي صلاحية بعد.\n'
                        'اطلب من المدير أن يحدّد صلاحياتك.',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () =>
                          ref.read(adminRepositoryProvider).signOut(),
                      icon: const Icon(Icons.logout),
                      label: const Text('تسجيل الخروج'),
                    ),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      );
    }

    // الصفحة المختارة قد تختفي إن تبدّلت الصلاحيات أثناء الجلسة.
    final page = _page.clamp(0, navs.length - 1);
    final destinations = [for (final n in navs) (n.icon, n.selected, n.label)];
    final body = navs[page].page;
    final reviewIndex = navs.indexWhere((n) => n.label == 'المراجعة');

    // على الهاتف: درج لا شريط جانبي. الشريط بتسعة عناوين يلتهم نصف عرض
    // الشاشة، فلا يبقى للمحتوى ما يكفي ويخرج نصف كل صف خارج الحدّ.
    if (compact) {
      return Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('زنبور'),
              const SizedBox(width: 10),
              Text(destinations[page].$3,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          actions: [
            if (pendingCount > 0 && reviewIndex >= 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  child: Badge(
                    label: Text('$pendingCount'),
                    child: IconButton(
                      icon: const Icon(Icons.pending_actions),
                      tooltip: 'سائقون بانتظار المراجعة',
                      onPressed: reviewIndex < 0
                          ? null
                          : () => setState(() => _page = reviewIndex),
                    ),
                  ),
                ),
              ),
          ],
        ),
        drawer: NavigationDrawer(
          selectedIndex: page,
          onDestinationSelected: (i) {
            setState(() => _page = i);
            Navigator.pop(context);
          },
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(Icons.two_wheeler,
                        color: theme.colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Text('زنبور',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            for (final (icon, selected, label) in destinations)
              NavigationDrawerDestination(
                icon: icon,
                selectedIcon: selected,
                label: Text(label),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('تسجيل الخروج'),
              onTap: () => ref.read(adminRepositoryProvider).signOut(),
            ),
          ],
        ),
        body: body,
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: page,
            onDestinationSelected: (i) => setState(() => _page = i),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(Icons.two_wheeler,
                        color: theme.colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 6),
                  Text('زنبور',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: IconButton(
                    icon: const Icon(Icons.logout),
                    tooltip: 'خروج',
                    onPressed: () =>
                        ref.read(adminRepositoryProvider).signOut(),
                  ),
                ),
              ),
            ),
            destinations: [
              for (final (icon, selected, label) in destinations)
                NavigationRailDestination(
                  icon: icon,
                  selectedIcon: selected,
                  label: Text(label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// تسمية نوع المركبة — تُستعمل في كل مكانٍ يعرض سائقاً.
String _kindLabel(Object? kind) => switch (kind) {
      'tuktuk' => 'تكتك',
      'stoota' => 'ستوتة',
      _ => 'دراجة',
    };

/// صفحةٌ في القائمة الجانبية ومعها شرط ظهورها.
class _Nav {
  const _Nav(this.icon, this.selected, this.label, this.page, this.visible);

  final Widget icon;
  final Widget selected;
  final String label;
  final Widget page;
  final bool visible;
}

// =============================================================================
// السائقون المنتظرون
// =============================================================================
class _PendingPage extends ConsumerWidget {
  const _PendingPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(pendingDriversProvider);

    return _Page(
      title: 'سائقون بانتظار المراجعة',
      subtitle: 'كل سائق هنا لا يستطيع العمل حتى تعتمده',
      onRefresh: () => ref.invalidate(pendingDriversProvider),
      child: drivers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => SelectableText('تعذّر التحميل: $e'),
        data: (list) {
          if (list.isEmpty) {
            return _Empty(
              icon: Icons.check_circle_outline,
              title: 'لا يوجد سائقون بانتظار المراجعة',
              body: 'حين يسجّل سائق جديد ويرفع وثائقه سيظهر هنا.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _DriverRow(driver: list[i]),
          );
        },
      ),
    );
  }
}

// =============================================================================
// كل السائقين
// =============================================================================
class _AllDriversPage extends ConsumerStatefulWidget {
  const _AllDriversPage();

  @override
  ConsumerState<_AllDriversPage> createState() => _AllDriversPageState();
}

class _AllDriversPageState extends ConsumerState<_AllDriversPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final drivers = ref.watch(driverSearchProvider(_query));

    return _Page(
      title: 'كل السائقين',
      onRefresh: () => ref.invalidate(driverSearchProvider(_query)),
      header: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SearchField(
              controller: _search,
              width: 380,
              hint: 'ابحث بالاسم أو رقم الهاتف',
              onSubmitted: (v) => setState(() => _query = v),
            ),
            if (can(ref, 'accounts.create'))
            FilledButton.icon(
              onPressed: () => _createAccount(context, ref, 'driver'),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('حساب سائق جديد'),
            ),
          ],
        ),
      ),
      child: drivers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => SelectableText('تعذّر التحميل: $e'),
        data: (list) {
          if (list.isEmpty) {
            return _Empty(
              icon: Icons.people_outline,
              title: _query.isEmpty
                  ? 'لا يوجد سائقون بعد'
                  : 'لا نتائج لـ"$_query"',
              body: _query.isEmpty
                  ? 'شارك رابط تطبيق السائق لتبدأ التسجيلات.'
                  : 'جرّب اسماً جزئياً أو آخر أرقام الهاتف.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _DriverRow(driver: list[i]),
          );
        },
      ),
    );
  }
}

// =============================================================================
// الركّاب
// =============================================================================
// **لماذا قسم مستقل؟** كان الراكب يظهر اسماً عابراً داخل صفّ رحلة، فلا
// يستطيع المدير أن يجيب سؤالاً بسيطاً حين يتصل أحدهم: من هذا؟ كم رحلة
// ألغى؟ متى آخر مرة استعمل التطبيق؟ والركّاب أكثر عدداً من السائقين
// وأصل الإيراد، فغيابهم عن اللوحة أغرب من غياب أي قسم آخر.
class _RidersPage extends ConsumerStatefulWidget {
  const _RidersPage();

  @override
  ConsumerState<_RidersPage> createState() => _RidersPageState();
}

class _RidersPageState extends ConsumerState<_RidersPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final riders = ref.watch(riderSearchProvider(_query));

    return _Page(
      title: 'الركّاب',
      onRefresh: () => ref.invalidate(riderSearchProvider(_query)),
      header: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SearchField(
              controller: _search,
              width: 380,
              hint: 'ابحث بالاسم أو الهاتف أو البريد',
              onSubmitted: (v) => setState(() => _query = v),
            ),
            if (can(ref, 'accounts.create'))
            FilledButton.icon(
              onPressed: () => _createAccount(context, ref, 'rider'),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('حساب راكب جديد'),
            ),
          ],
        ),
      ),
      child: riders.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => SelectableText('تعذّر التحميل: $e'),
        data: (list) {
          if (list.isEmpty) {
            return _Empty(
              icon: Icons.person_outline,
              title: _query.isEmpty
                  ? 'لا يوجد ركّاب بعد'
                  : 'لا نتائج لـ"$_query"',
              body: _query.isEmpty
                  ? 'شارك رابط تطبيق الراكب لتبدأ التسجيلات.'
                  : 'جرّب اسماً جزئياً أو آخر أرقام الهاتف.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _RiderRow(rider: list[i]),
          );
        },
      ),
    );
  }
}

class _RiderRow extends StatelessWidget {
  const _RiderRow({required this.rider});

  final Map<String, dynamic> rider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = rider['is_blocked'] == true;

    final total = (rider['trips_total'] as num?)?.toInt() ?? 0;
    final cancelled = (rider['trips_cancelled'] as num?)?.toInt() ?? 0;

    // **النسبة لا العدد.** من ألغى عشراً من مئة غير من ألغى عشراً من
    // اثنتي عشرة، والعدد وحده يساوي بينهما.
    final rate = total == 0 ? 0 : (cancelled * 100 / total).round();
    final heavy = total >= 5 && rate >= 30;

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: blocked
              ? AdminTheme.danger.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest,
          child: Icon(blocked ? Icons.block : Icons.person_outline,
              color: blocked ? AdminTheme.danger : null),
        ),
        title: Text('${rider['full_name'] ?? '—'}'),
        subtitle: Text(
          '${rider['phone'] ?? '—'}  ·  $total رحلة'
          '${total == 0 ? '' : '  ·  ملغاة $rate٪'}',
          textDirection: TextDirection.rtl,
        ),
        trailing: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (blocked)
              Chip(
                label: const Text('موقوف'),
                backgroundColor: AdminTheme.danger.withValues(alpha: 0.15),
                side: BorderSide.none,
              )
            else if (heavy)
              Chip(
                label: const Text('إلغاء متكرر'),
                backgroundColor: AdminTheme.warning.withValues(alpha: 0.18),
                side: BorderSide.none,
              ),
            const Icon(Icons.chevron_left),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => RiderDetailPage(rider: rider)),
        ),
      ),
    );
  }
}

class _DriverRow extends StatelessWidget {
  const _DriverRow({required this.driver});

  final Map<String, dynamic> driver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = driver['profiles'] as Map<String, dynamic>;
    final status = driver['verification_status'] as String?;
    final online = driver['status'] as String?;

    // الموقوف عن الطلبات يسبق المعتمَد في العرض: سائق أوقفناه أمس يجب
    // ألّا يظهر في القائمة «معتمداً» فيُحسب ضمن العاملين.
    final blocked = p['is_blocked'] == true;

    final (color, label) = switch (status) {
      _ when blocked && status == 'approved' =>
        (AdminTheme.warning, 'موقوف عن الطلبات'),
      'approved' => (AdminTheme.success, 'معتمد'),
      'rejected' => (AdminTheme.danger, 'مرفوض'),
      'suspended' => (AdminTheme.danger, 'اعتماده ملغى'),
      _ => (AdminTheme.warning, 'قيد المراجعة'),
    };

    final compact = Breaks.isCompact(context);

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );

    final dot = (!blocked && (online == 'online' || online == 'on_trip'))
        ? Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AdminTheme.success,
            ),
          )
        : null;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DriverDetailPage(driver: driver),
        )),
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 16),
          child: Row(
            children: [
              CircleAvatar(
                radius: compact ? 20 : 24,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(Icons.person,
                    color: theme.colorScheme.onPrimaryContainer),
              ),
              SizedBox(width: compact ? 12 : 16),
              // على الهاتف: الاسم والهاتف والحالة فوق بعضها. الصفّ الواحد
              // بخمسة أعمدة يخرج عن حدّ الشاشة فتُقصّ الحالة — وهي أهم ما
              // في الصف.
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${p['full_name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text('${p['phone']}',
                        textDirection: TextDirection.ltr,
                        style: theme.textTheme.bodySmall),
                    if (compact) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          badge,
                          ?dot,
                          // **نوع المركبة قبل وصفها.** «هوندا ١٥٠»
                          // لا تقول أستوتةٌ هي أم دراجة، والفرق في
                          // العمل كلّه: الستوتة لا تحمل ركّاباً.
                          Text(_kindLabel(driver['vehicle_kind']),
                              style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.bold)),
                          Text('${driver['vehicle_type'] ?? '—'}',
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (!compact) ...[
                Expanded(
                  flex: 2,
                  child: Text(
                      '${_kindLabel(driver['vehicle_kind'])}'
                      '  ·  ${driver['vehicle_type'] ?? '—'}',
                      style: theme.textTheme.bodyMedium),
                ),
                if (dot != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: dot,
                  ),
                badge,
                const SizedBox(width: 8),
              ],
              const Icon(Icons.chevron_left),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// الرحلات الجارية
// =============================================================================
/// يفتح مربع الإنشاء ثم يعرض بيانات الدخول مرة واحدة.
///
/// **مشتركة بين صفحتَي الركّاب والسائقين** — الفرق دورٌ يُمرَّر لا مسار
/// منفصل، فلا تتباعد النسختان حين نضيف حقلاً.
Future<void> _createAccount(
  BuildContext context,
  WidgetRef ref,
  String role,
) async {
  final created = await showCreateAccountDialog(context, role: role);
  if (created == null || !context.mounted) return;

  // التحديث قبل عرض البيانات: المدير يغلق النافذة فيجد الحساب في
  // القائمة، لا قائمةً كما كانت فيظنّ الإنشاء فشل.
  ref.invalidate(riderSearchProvider(''));
  ref.invalidate(driverSearchProvider(''));

  await showCredentialsDialog(
    context,
    email: created.email,
    password: created.password,
  );
}

class _Page extends StatelessWidget {
  const _Page({
    required this.title,
    required this.child,
    this.subtitle,
    this.onRefresh,
    this.header,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onRefresh;

  /// شريط اختياري بين العنوان والمحتوى — للبحث والمرشّحات.
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final pad = Breaks.pad(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: title,
            subtitle: subtitle,
            actions: [
              if (onRefresh != null)
                IconButton.filledTonal(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'تحديث',
                ),
            ],
          ),
          SizedBox(height: Breaks.isCompact(context) ? 14 : 24),
          ?header,
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(body,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _NotAdmin extends StatelessWidget {
  const _NotAdmin({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline, size: 72),
              const SizedBox(height: 20),
              const Text('هذا الحساب ليس حساب مدير',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              const Text(
                'اللوحة مخصصة لحسابات الإدارة فقط.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: onSignOut,
                child: const Text('تسجيل الخروج'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
