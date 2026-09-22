import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/admin_repository.dart';
import '../../core/layout.dart';
import '../trips/trips_page.dart' show fmtDateTime;

final isOwnerProvider =
    FutureProvider<bool>((ref) => ref.watch(adminRepositoryProvider).isOwner());

/// صلاحيات من فتح اللوحة — تُخفي بها الصفحاتُ أزرارَ ما لا يملكه.
///
/// **القفل في القاعدة لا هنا.** الإخفاء راحةٌ لا حماية: زرٌّ يردّ «غير
/// مصرّح» أسوأ من زرٍّ لا يظهر، لكنّ من يتجاوز اللوحة تردّه القاعدة.
final myPermissionsProvider = FutureProvider<Set<String>>(
    (ref) => ref.watch(adminRepositoryProvider).myPermissions());
final permissionsProvider = FutureProvider<List<Map<String, dynamic>>>(
    (ref) => ref.watch(adminRepositoryProvider).knownPermissions());
final staffProvider = FutureProvider<List<Map<String, dynamic>>>(
    (ref) => ref.watch(adminRepositoryProvider).staff());
final auditProvider = FutureProvider.family<List<Map<String, dynamic>>, String>(
    (ref, q) => ref.watch(adminRepositoryProvider).auditLog(query: q));

/// المستخدمون: الموظفون وصلاحياتهم، وسجلّ ما فعلوه.
///
/// **للمالك وحده، والحارس في القاعدة لا هنا.** إخفاء زر لا يمنع أحداً من
/// نداء الدالة مباشرةً — `set_staff` و`remove_staff` تتحققان من البريد
/// بنفسيهما. ما في هذه الصفحة إخفاءٌ لما لا يفيد عرضه، لا حماية.
class StaffPage extends ConsumerStatefulWidget {
  const StaffPage({super.key});

  @override
  ConsumerState<StaffPage> createState() => _StaffPageState();
}

class _StaffPageState extends ConsumerState<StaffPage> {
  final _search = TextEditingController();
  String _auditQuery = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owner = ref.watch(isOwnerProvider).value ?? false;

    if (!owner) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline,
                  size: 56, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text('هذا القسم للمالك وحده',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('إدارة الموظفين وصلاحياتهم لا تُفوَّض.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    final staff = ref.watch(staffProvider);
    final audit = ref.watch(auditProvider(_auditQuery));

    return Padding(
      padding: EdgeInsets.all(Breaks.pad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'المستخدمون',
            actions: [
              FilledButton.icon(
                onPressed: () => _addStaff(context, ref),
                icon: const Icon(Icons.person_add),
                label: const Text('إضافة موظف'),
              ),
            ],
          ),
          const SizedBox(height: 20),

          SizedBox(
            height: 260,
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: staff.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ErrorView(e,
                    onRetry: () => ref.invalidate(staffProvider)),
                data: (list) => ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final u = list[i];
                    final isOwner = u['is_owner'] == true;
                    final perms =
                        List<String>.from(u['permissions'] as List? ?? const []);
                    return ListTile(
                      leading: Icon(isOwner ? Icons.shield : Icons.person),
                      title: Text('${u['full_name'] ?? '—'}'
                          '${isOwner ? '  (المالك)' : ''}'),
                      subtitle: Text(
                        isOwner
                            ? '${u['email']}  ·  كل الصلاحيات'
                            : '${u['email']}  ·  '
                                '${perms.isEmpty ? 'بلا صلاحيات' : '${perms.length} صلاحية'}',
                        textDirection: TextDirection.ltr,
                      ),
                      trailing: isOwner
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  onPressed: () => _addStaff(context, ref,
                                      email: '${u['email']}', current: perms),
                                  child: const Text('الصلاحيات'),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.person_remove),
                                  tooltip: 'نزع الصلاحيات',
                                  onPressed: () async {
                                    await ref
                                        .read(adminRepositoryProvider)
                                        .removeStaff(u['id'] as String);
                                    ref.invalidate(staffProvider);
                                  },
                                ),
                              ],
                            ),
                    );
                  },
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('سجلّ التدقيق',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              SearchField(
                controller: _search,
                width: 300,
                hint: 'بحث بالفعل أو بالاسم',
                onSubmitted: (v) => setState(() => _auditQuery = v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: audit.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ErrorView(e,
                    onRetry: () => ref.invalidate(auditProvider)),
                data: (list) {
                  if (list.isEmpty) {
                    return const Center(child: Text('لا توجد سجلات بعد'));
                  }
                  return ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final a = list[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(_icon('${a['action']}'), size: 20),
                        title: Text('${a['summary'] ?? a['action']}'),
                        subtitle: Text(
                          '${a['actor_name'] ?? 'غير معروف'}  ·  '
                          '${fmtDateTime(a['created_at'])}',
                          style: theme.textTheme.bodySmall,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _icon(String action) {
  if (action.startsWith('topup')) return Icons.confirmation_number_outlined;
  if (action.startsWith('coupon')) return Icons.local_offer_outlined;
  if (action.startsWith('payout')) return Icons.payments_outlined;
  if (action.startsWith('staff')) return Icons.manage_accounts_outlined;
  if (action.startsWith('trip')) return Icons.route_outlined;
  return Icons.history;
}

// =============================================================================
Future<void> _addStaff(
  BuildContext context,
  WidgetRef ref, {
  String? email,
  List<String> current = const [],
}) async {
  final ctl = TextEditingController(text: email ?? '');
  // **حسابٌ يُنشأ هنا كاملاً.** كان على الموظف أن يسجّل في تطبيق الراكب
  // أولاً ليُرفَّع مشرفاً — طريقٌ ملتوٍ لمن كل عمله لوحةُ ويب (0109).
  final pass = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();
  var existing = false;   // لبريدٍ مسجّلٍ أصلاً: نمنحه الصلاحيات فقط
  final chosen = {...current};
  var busy = false;
  String? error;

  final perms = ref.read(permissionsProvider).value ?? const [];

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(email == null ? 'إضافة موظف' : 'صلاحيات $email'),
        content: SizedBox(
          width: Breaks.dialogWidth(ctx, 460),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (email == null) ...[
                  TextField(
                    controller: ctl,
                    autofocus: true,
                    textDirection: TextDirection.ltr,
                    decoration: const InputDecoration(
                      labelText: 'بريد الموظف',
                      helperText: 'يدخل به إلى اللوحة',
                    ),
                  ),
                  const SizedBox(height: 10),
                  // من كان له حساب في التطبيق أصلاً لا يُنشأ له حساب ثانٍ.
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: existing,
                    title: const Text('له حساب مسجّل أصلاً — امنحه الصلاحيات فقط'),
                    onChanged: (v) => setLocal(() => existing = v == true),
                  ),
                  if (!existing) ...[
                    TextField(
                      controller: pass,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور',
                        helperText: 'ثمانية أحرف فأكثر — سلّمها له بيدك',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'الاسم الثلاثي',
                        helperText: 'الاسم واسم الأب واسم الجد',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: phone,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'رقم الهاتف',
                        hintText: '07701234567',
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
                Text('الصلاحيات',
                    style: Theme.of(ctx)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  'صلاحيات «رؤية» تُظهر الصفحة، وغيرها يُظهر أزرارها. '
                  'المعلَّمة بـ💰 تحرّك المال مباشرةً — لا تعطِها إلا لمن تثق به.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                ),
                // **مجمّعةٌ بالصفحة.** ثلاثون مربّعاً في قائمةٍ واحدة تُقرأ
                // عشوائياً؛ وتحت عنوان صفحتها يعرف المدير ما يمنحه.
                for (final group in _groupByPage(perms)) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(group.$1,
                            style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                color: Theme.of(ctx).colorScheme.primary,
                                fontWeight: FontWeight.bold)),
                      ),
                      // الكلّ أو لا شيء للصفحة بضغطة.
                      TextButton(
                        onPressed: () => setLocal(() {
                          final codes = [for (final p in group.$2) '${p['code']}'];
                          if (codes.every(chosen.contains)) {
                            chosen.removeAll(codes);
                          } else {
                            chosen.addAll(codes);
                          }
                        }),
                        child: Text(group.$2
                                .every((p) => chosen.contains('${p['code']}'))
                            ? 'إلغاء الكل'
                            : 'الكل'),
                      ),
                    ],
                  ),
                  for (final p in group.$2)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: chosen.contains('${p['code']}'),
                      title: Text(
                          '${_moneyPerms.contains(p['code']) ? '💰 ' : ''}'
                          '${p['label']}'),
                      onChanged: (v) => setLocal(() => v == true
                          ? chosen.add('${p['code']}')
                          : chosen.remove('${p['code']}')),
                    ),
                ],
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
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setLocal(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      final repo = ref.read(adminRepositoryProvider);
                      if (email == null && !existing) {
                        await repo.createStaff(
                          email: ctl.text.trim(),
                          password: pass.text,
                          fullName: name.text.trim(),
                          phone: phone.text.trim(),
                          permissions: chosen.toList(),
                        );
                      } else {
                        await repo.setStaff(ctl.text.trim(), chosen.toList());
                      }
                      ref.invalidate(staffProvider);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      setLocal(() {
                        error = '$e';
                        busy = false;
                      });
                    }
                  },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );
  ctl.dispose();
  pass.dispose();
  name.dispose();
  phone.dispose();
}


/// صلاحياتٌ تحرّك المال مباشرةً — تُعلَّم في النافذة ليتمهّل من يمنحها.
const _moneyPerms = {
  'wallets.adjust',
  'topups.generate',
  'topups.generate_zaincash',
  'payouts.process',
  'coupons.manage',
  'settings.manage',
};

/// الصلاحيات مجمّعةً بصفحتها، بترتيب ورودها من القاعدة.
List<(String, List<Map<String, dynamic>>)> _groupByPage(
    List<Map<String, dynamic>> perms) {
  final out = <(String, List<Map<String, dynamic>>)>[];
  for (final p in perms) {
    final page = '${p['page'] ?? 'أخرى'}';
    if (out.isEmpty || out.last.$1 != page) {
      out.add((page, <Map<String, dynamic>>[]));
    }
    out.last.$2.add(p);
  }
  return out;
}
