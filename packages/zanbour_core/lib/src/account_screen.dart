import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'errors.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'invite_screen.dart';
import 'verify_phone_screen.dart';

/// شاشة «حسابي» — مشتركة بين الراكب والسائق.
///
/// **لماذا لا يعدّل المستخدم بياناته مباشرةً؟** لأن الاسم والهاتف وتاريخ
/// الميلاد هي ما طابقه المدير مع صورة البطاقة الوطنية وقت الاعتماد.
/// تعديلٌ مباشر يعني أن سائقاً معتمَداً يستطيع أن يصير شخصاً آخر بعد
/// المراجعة — فتسقط المراجعة كلها. لذلك: طلب يمرّ على إنسان.
///
/// **ولماذا الحذف فوري بلا موافقة؟** لأنه حقّ لا امتياز. جوجل تشترطه،
/// والانتظار فيه إهانة: من قرّر المغادرة لا يُحتجز.

/// بيانات الحساب الحالية — الملف الشخصي وصف السائق إن وُجد.
final accountProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final sb = Supabase.instance.client;
  final uid = sb.auth.currentUser?.id;
  if (uid == null) return null;

  final profile =
      await sb.from('profiles').select().eq('id', uid).maybeSingle();
  if (profile == null) return null;

  final out = Map<String, dynamic>.from(profile);
  if (profile['role'] == 'driver') {
    final d = await sb
        .from('drivers')
        .select('vehicle_type, vehicle_plate, vehicle_color, '
            'verification_status, wallet_balance_iqd')
        .eq('id', uid)
        .maybeSingle();
    if (d != null) out['_driver'] = Map<String, dynamic>.from(d);
  }
  return out;
});

/// آخر طلب تعديل — المعلّق منه هو ما يهمّ الشاشة.
final myChangeRequestProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  final sb = Supabase.instance.client;
  final uid = sb.auth.currentUser?.id;
  if (uid == null) return null;

  final rows = await sb
      .from('profile_change_requests')
      .select()
      .eq('user_id', uid)
      .order('created_at', ascending: false)
      .limit(1);
  return (rows as List).isEmpty
      ? null
      : Map<String, dynamic>.from(rows.first as Map);
});

/// أسماء الحقول بالعربية — تُستعمل في العرض وفي بطاقة الطلب معاً.
const kFieldLabels = <String, String>{
  'full_name': 'الاسم الثلاثي',
  'phone': 'رقم الهاتف',
  'date_of_birth': 'تاريخ الميلاد',
  'address': 'العنوان',
  'vehicle_type': 'نوع المركبة',
  'vehicle_plate': 'رقم اللوحة',
  'vehicle_color': 'لون المركبة',
};

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key, required this.driver});

  /// تطبيق السائق يعرض حقول المركبة ورصيد المحفظة.
  final bool driver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final request = ref.watch(myChangeRequestProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('حسابي')),
      body: account.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppError.message(e), textAlign: TextAlign.center),
          ),
        ),
        data: (a) {
          if (a == null) {
            return const Center(child: Text('لا توجد بيانات'));
          }
          final d = a['_driver'] as Map<String, dynamic>?;
          final pending = request.value?['status'] == 'pending'
              ? request.value
              : null;

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(accountProvider);
              ref.invalidate(myChangeRequestProvider);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                if (pending != null) ...[
                  _PendingCard(request: pending, ref: ref),
                  const SizedBox(height: 16),
                ] else if (request.value?['status'] == 'rejected') ...[
                  _RejectedCard(request: request.value!),
                  const SizedBox(height: 16),
                ],

                _Section(
                  title: 'بياناتي',
                  children: [
                    _Row('الاسم الثلاثي', '${a['full_name'] ?? '—'}'),
                    _Row('رقم الهاتف', '${a['phone'] ?? '—'}', ltr: true),
                    _Row('البريد', '${a['email'] ?? '—'}', ltr: true),
                    _Row('تاريخ الميلاد', _date(a['date_of_birth'])),
                    _Row('العنوان', '${a['address'] ?? '—'}'),
                  ],
                ),

                if (driver && d != null) ...[
                  const SizedBox(height: 16),
                  _Section(
                    title: 'مركبتي',
                    children: [
                      _Row('النوع', '${d['vehicle_type'] ?? '—'}'),
                      _Row('رقم اللوحة', '${d['vehicle_plate'] ?? '—'}',
                          ltr: true),
                      _Row('اللون', '${d['vehicle_color'] ?? '—'}'),
                    ],
                  ),
                ],

                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: pending != null
                      ? null
                      : () => _openEdit(context, ref, a, driver),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(pending != null
                      ? 'لديك طلب قيد المراجعة'
                      : 'طلب تعديل البيانات'),
                ),
                const SizedBox(height: 8),
                Text(
                  'التعديل يمرّ على الإدارة قبل تطبيقه، لأن بياناتك مطابقة '
                  'لوثائق راجعها موظف.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),

                const SizedBox(height: 20),
                const _VerificationCards(),

                const SizedBox(height: 20),
                _BalanceAndInvite(driver: driver),

                const SizedBox(height: 36),
                const Divider(),
                const SizedBox(height: 12),
                const _VersionLine(),

                const SizedBox(height: 12),
                _DeleteSection(driver: driver),
              ],
            ),
          );
        },
      ),
    );
  }
}

// =============================================================================
// طلب التعديل
// =============================================================================
Future<void> _openEdit(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> a,
  bool isDriver,
) async {
  final d = a['_driver'] as Map<String, dynamic>?;

  final done = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => _EditRequestScreen(
        current: {
          'full_name': '${a['full_name'] ?? ''}',
          'phone': '${a['phone'] ?? ''}',
          'date_of_birth': '${a['date_of_birth'] ?? ''}',
          'address': '${a['address'] ?? ''}',
          if (isDriver) 'vehicle_type': '${d?['vehicle_type'] ?? ''}',
          if (isDriver) 'vehicle_plate': '${d?['vehicle_plate'] ?? ''}',
          if (isDriver) 'vehicle_color': '${d?['vehicle_color'] ?? ''}',
        },
      ),
    ),
  );

  if (done == true) {
    ref.invalidate(myChangeRequestProvider);
  }
}

class _EditRequestScreen extends ConsumerStatefulWidget {
  const _EditRequestScreen({required this.current});
  final Map<String, String> current;

  @override
  ConsumerState<_EditRequestScreen> createState() => _EditRequestState();
}

class _EditRequestState extends ConsumerState<_EditRequestScreen> {
  late final Map<String, TextEditingController> _ctrl = {
    for (final e in widget.current.entries)
      e.key: TextEditingController(text: e.value)
  };
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // نرسل ما تغيّر وحده. القاعدة تفحص ذلك أيضاً، لكن إرسال الكل يجعل
    // بطاقة الطلب أمام المدير مزدحمة بحقول لم تُمسّ.
    final changes = <String, String>{};
    for (final e in _ctrl.entries) {
      final v = e.value.text.trim();
      if (v.isNotEmpty && v != widget.current[e.key]) changes[e.key] = v;
    }

    if (changes.isEmpty) {
      setState(() => _error = 'لم تغيّر شيئاً');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await Supabase.instance.client.rpc('request_profile_change', params: {
        'p_changes': changes,
        'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AppError.message(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('طلب تعديل البيانات')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Text(
            'غيّر ما تريد تعديله واترك الباقي كما هو. يصل الطلب إلى '
            'الإدارة، وتُطبَّق التغييرات بعد الموافقة.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),

          for (final e in _ctrl.entries) ...[
            TextField(
              controller: e.value,
              textDirection: e.key == 'phone' ? TextDirection.ltr : null,
              keyboardType: e.key == 'phone'
                  ? TextInputType.phone
                  : TextInputType.text,
              inputFormatters: e.key == 'date_of_birth'
                  ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9-]'))]
                  : null,
              decoration: InputDecoration(
                labelText: kFieldLabels[e.key] ?? e.key,
                border: const OutlineInputBorder(),
                helperText: switch (e.key) {
                  'phone' => 'بالصيغة +9647XXXXXXXXX',
                  'date_of_birth' => 'بالصيغة YYYY-MM-DD',
                  _ => null,
                },
              ),
            ),
            const SizedBox(height: 14),
          ],

          TextField(
            controller: _note,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'سبب التعديل (اختياري)',
              hintText: 'مثال: غيّرت رقم هاتفي',
              border: OutlineInputBorder(),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],

          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2))
                : const Text('إرسال الطلب'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// بطاقات حالة الطلب
// =============================================================================
class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.request, required this.ref});
  final Map<String, dynamic> request;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changes = (request['changes'] as Map?) ?? const {};

    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hourglass_top),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('طلب تعديل قيد المراجعة',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final e in changes.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${kFieldLabels[e.key] ?? e.key}: ${e.value}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                icon: const Icon(Icons.undo),
                label: const Text('سحب الطلب'),
                onPressed: () async {
                  await Supabase.instance.client
                      .rpc('cancel_profile_change');
                  ref.invalidate(myChangeRequestProvider);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RejectedCard extends StatelessWidget {
  const _RejectedCard({required this.request});
  final Map<String, dynamic> request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.cancel_outlined,
                color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('رُفض طلب التعديل الأخير',
                      style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onErrorContainer)),
                  const SizedBox(height: 4),
                  Text('${request['review_note'] ?? 'بلا سبب مذكور'}',
                      style: TextStyle(
                          color: theme.colorScheme.onErrorContainer)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// حذف الحساب
// =============================================================================
/// **حاجزان لا ثلاثة.** الحذف حقّ، فلا نُثقله بخطوات تُشعر صاحبه أنه
/// يتسوّل مغادرة. لكنه لا رجعة فيه، فلا يقع بلمسة واحدة: نشرح ما يُمحى
/// وما يبقى، ثم نطلب كتابة كلمة واحدة.
class _DeleteSection extends ConsumerStatefulWidget {
  const _DeleteSection({required this.driver});
  final bool driver;

  @override
  ConsumerState<_DeleteSection> createState() => _DeleteSectionState();
}

class _DeleteSectionState extends ConsumerState<_DeleteSection> {
  bool _busy = false;

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ConfirmDelete(driver: widget.driver),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final sb = Supabase.instance.client;

      // **الدالة أولاً ثم الملفات.** حرّاسها قد يرفضون الحذف — رحلة
      // جارية أو دين مستحق — ولو حذفنا الملفات أولاً لخسر السائق
      // وثائقه ثم بقي مسجَّلاً، فيرفعها كلها من جديد بلا ذنب.
      //
      // وتعيد مساراتها لأن صفوفها تُمحى معها: بعد الحذف لا يبقى ما
      // يدلّ على الملفات، فتبقى في التخزين إلى الأبد بلا من يعرف بها.
      final paths = await sb.rpc('delete_my_account');

      // **حذفها بواجهة التخزين لا بجدولها.** Supabase تمنع الحذف
      // المباشر من `storage.objects`، فالمرور بالواجهة هو الطريق
      // الوحيد المسموح.
      final list = (paths as List?)?.map((e) => '$e').toList() ?? const [];
      if (list.isNotEmpty) {
        try {
          await sb.storage.from('documents').remove(list);
        } catch (_) {
          // فشل حذف ملف لا يُعيد الحساب. الحساب مُجهَّل فعلاً، وبقاء
          // ملفٍ يتيم أهون من رسالة خطأ توهم صاحبه أن الحذف لم يتمّ.
        }
      }

      // الخروج بعد الحذف مباشرةً: الجلسة صارت لحساب لا وجود له.
      await sb.auth.signOut();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        messenger.showSnackBar(
            SnackBar(content: Text(AppError.message(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('حذف الحساب',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(
          'يُمحى اسمك ورقمك وبريدك وعنوانك وصورك نهائياً، ولا تستطيع '
          'الدخول بعدها. لا يمكن التراجع.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: _busy ? null : _delete,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.delete_forever_outlined),
          label: const Text('حذف حسابي نهائياً'),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            side: BorderSide(color: theme.colorScheme.error),
          ),
        ),
      ],
    );
  }
}

class _ConfirmDelete extends StatefulWidget {
  const _ConfirmDelete({required this.driver});
  final bool driver;

  @override
  State<_ConfirmDelete> createState() => _ConfirmDeleteState();
}

class _ConfirmDeleteState extends State<_ConfirmDelete> {
  final _ctrl = TextEditingController();
  static const _word = 'حذف';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = _ctrl.text.trim() == _word;

    return AlertDialog(
      title: const Text('حذف الحساب نهائياً'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('يُمحى نهائياً:'),
            const SizedBox(height: 6),
            const Text('• اسمك ورقم هاتفك وبريدك وعنوانك وتاريخ ميلادك'),
            const Text('• صور بطاقتك وصورتك الحية من الخوادم'),
            const SizedBox(height: 12),
            const Text('يبقى في سجلّاتنا:'),
            const SizedBox(height: 6),
            const Text('• سجلّ الرحلات ومبالغها بلا اسمك — تلزمنا للمحاسبة '
                'ولحقوق الطرف الآخر في كل رحلة.'),
            if (widget.driver) ...[
              const SizedBox(height: 12),
              Text(
                'لا يمكن الحذف ولديك رصيد مستحق أو طلب سحب معلّق.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 18),
            Text('اكتب «$_word» للتأكيد:',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('تراجع'),
        ),
        FilledButton(
          onPressed: ok ? () => Navigator.pop(context, true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
          ),
          child: const Text('احذف حسابي'),
        ),
      ],
    );
  }
}

// =============================================================================
// عناصر عرض
// =============================================================================
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

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
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.ltr = false});
  final String label;
  final String value;
  final bool ltr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(
              value,
              textDirection: ltr ? TextDirection.ltr : null,
              style: theme.textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}

String _date(Object? raw) {
  final d = DateTime.tryParse('$raw');
  if (d == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}


// =============================================================================
/// رقم الإصدار ورقم البناء معاً.
///
/// **لماذا رقم البناء لا الإصدار وحده؟** شاشة أندرويد تعرض `versionName`
/// فقط — أي `1.0.0` — وهو ثابت بين كل النسخ التجريبية. فلا المختبِر يعرف
/// أيّها عنده، ولا نحن نعرف إن كان يبلّغ عن عطلٍ أصلحناه قبل ثلاثة أيام.
///
/// ورقم البناء هو ما يتغيّر فعلاً مع كل رفع.
class _VersionLine extends StatefulWidget {
  const _VersionLine();

  @override
  State<_VersionLine> createState() => _VersionLineState();
}

class _VersionLineState extends State<_VersionLine> {
  String? _text;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _text = '${info.version} (${info.buildNumber})');
      }
    } catch (_) {
      // قراءة فاشلة لا تستحق تعطيل الشاشة. يبقى السطر فارغاً.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_text == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Center(
      // **قابل للتحديد.** المختبِر يُرسله لنا نصاً لا صورةً.
      child: SelectableText(
        'الإصدار $_text',
        textDirection: TextDirection.ltr,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}


// =============================================================================
/// رصيدي وبابا الدعوة.
///
/// **الرصيدان معروضان منفصلين لا مجموعهما.** المجموع يخفي ما يهمّ فعلاً:
/// كم يستطيع أن يسحب، وكم وُهب له. ومن يرى رقماً واحداً ثم يُمنع من سحب
/// نصفه يشعر أنه خُدع.
class _BalanceAndInvite extends ConsumerStatefulWidget {
  const _BalanceAndInvite({required this.driver});

  final bool driver;

  @override
  ConsumerState<_BalanceAndInvite> createState() => _BalanceAndInviteState();
}

class _BalanceAndInviteState extends ConsumerState<_BalanceAndInvite> {
  Map<String, dynamic>? _balance;

  /// هل يُعرض مدخل «لديك رمز دعوة؟».
  ///
  /// **يبدأ مخفيّاً لا ظاهراً.** لو بدأ ظاهراً لومض ثم اختفى أمام أكثر
  /// المستخدمين — ومن رأى باباً يُغلق في وجهه يسأل عمّا فاته.
  bool _canRedeem = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sb = Supabase.instance.client;
    try {
      final v = await sb.rpc('my_balance');
      if (mounted) setState(() => _balance = (v as Map).cast<String, dynamic>());
    } catch (_) {
      // قاعدةٌ لم تُرحَّل بعد، أو شبكةٌ منقطعة. لا نُظهر خطأً في شاشة
      // الحساب من أجل بطاقة إضافية.
    }
    try {
      final r = await sb.rpc('can_redeem_referral');
      if (mounted) {
        setState(() => _canRedeem = (r as Map)['can'] == true);
      }
    } catch (_) {
      // يبقى مخفيّاً. القاعدة هي التي تمنع فعلاً، والشاشة تتبعها.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = _balance;
    final real = (b?['real'] as num?)?.round() ?? 0;
    final bonus = (b?['bonus'] as num?)?.round() ?? 0;
    final expires = DateTime.tryParse('${b?['bonus_expires_at']}');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (b != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('رصيدي', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 40,
                    runSpacing: 14,
                    children: [
                      _Money('رصيدي', real),
                      _Money(
                        'هدية',
                        bonus,
                        note: bonus == 0
                            ? null
                            : expires == null
                                ? 'يُنفق تلقائياً'
                                : 'حتى ${expires.year}/${expires.month}/'
                                    '${expires.day}',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => InviteScreen(
                isDriver: widget.driver,
              ),
            ),
          ),
          icon: const Icon(Icons.card_giftcard),
          label: const Text('ادعُ صديقاً واكسب رصيداً'),
        ),

        // **يختفي بعد الاستعمال وبعد أول رحلة.** لا يُعطَّل رمادياً:
        // زرٌّ معطَّل يبقى سؤالاً بلا جواب في شاشةٍ يراها صاحبها كل يوم.
        if (_canRedeem) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              final ok = await showRedeemCodeDialog(context);
              if (ok == true) _load();
            },
            icon: const Icon(Icons.redeem, size: 18),
            label: const Text('لديك رمز دعوة؟'),
          ),
        ],
      ],
    );
  }
}

class _Money extends StatelessWidget {
  const _Money(this.label, this.value, {this.note});

  final String label;
  final int value;
  final String? note;

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
        Text('$value دينار',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        if (note != null)
          Text(note!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

// =============================================================================
/// توثيق الهاتف والبريد — كلٌّ ببطاقته.
///
/// **يظهر الطرفان دائماً.** المفروضُ منهما تجاوزه المستخدم عند التسجيل،
/// والاختياريّ هو ما يبقى معلَّقاً — وإخفاؤه بعد أول تجاهل يجعله لا
/// يُوثَّق أبداً.
///
/// **والمفروض يُعرض أولاً.** ما تجاوزه للتوّ يستحق أن يراه مؤكَّداً قبل
/// ما لم يفعله بعد.
class _VerificationCards extends ConsumerStatefulWidget {
  const _VerificationCards();

  @override
  ConsumerState<_VerificationCards> createState() =>
      _VerificationCardsState();
}

class _VerificationCardsState extends ConsumerState<_VerificationCards> {
  Map<String, dynamic>? _v;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Supabase.instance.client.rpc('my_verification');
      if (mounted) setState(() => _v = (r as Map).cast<String, dynamic>());
    } catch (_) {
      // قاعدةٌ لم تُرحَّل بعد أو شبكةٌ منقطعة — لا نُظهر خطأً في شاشة
      // الحساب من أجل بطاقتين إضافيتين.
    }
  }

  /// **يُرسل رمزاً ثم يفتح خانته.** ولا يكتفي بالإرسال: من يُقال له
  /// «أُرسل الرمز» ولا يجد أين يكتبه يعود إلى الشاشة يبحث، وأكثرهم
  /// يتركها.
  ///
  /// **و`signInWithOtp` لا `resend`.** الثانية تصلح لبريدٍ لم يُؤكَّد
  /// بعد؛ وفي وضع الهاتف يكون `email_confirmed_at` مضبوطاً آلياً
  /// (0064) فترفض. والأولى ترسل رمزاً لصاحب الصندوق في الحالين.
  Future<void> _sendEmail() async {
    final sb = Supabase.instance.client;
    final email = sb.auth.currentUser?.email;
    if (email == null) return;

    setState(() => _sending = true);
    try {
      await sb.auth.signInWithOtp(email: email, shouldCreateUser: false);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _EmailCodeDialog(email: email),
      );
      if (ok == true) _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppError.message(e))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _phoneCard(bool ok, bool otpOn, bool mandatory) => _VCard(
        ok: ok,
        icon: Icons.chat_bubble_outline,
        title: ok ? 'رقمك موثَّق' : 'رقمك غير موثَّق',
        body: ok
            ? 'يصلك السائق والمنصة عند الحاجة'
            : !otpOn
                ? 'توثيق الهاتف متوقّف حالياً.'
                : mandatory
                    ? 'وثّقه برمزٍ يصلك على واتساب.'
                    : 'اختياريّ — وثّقه برمزٍ يصلك على واتساب.',
        action: (ok || !otpOn) ? null : 'وثّق رقمي',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VerifyPhoneScreen()),
        ),
      );

  Widget _emailCard(bool ok, bool mandatory) => _VCard(
        ok: ok,
        icon: Icons.mail_outline,
        title: ok ? 'بريدك مؤكَّد' : 'بريدك غير مؤكَّد',
        body: ok
            ? 'يصلك استعادة كلمة المرور والإشعارات المهمّة'
            : mandatory
                ? 'أكّده برمزٍ يصلك على بريدك.'
                : 'اختياريّ — وثّقه برمزٍ يصلك على بريدك.',
        action: ok ? null : (_sending ? 'جارٍ الإرسال…' : 'أرسل الرمز'),
        onTap: _sending ? null : _sendEmail,
      );

  @override
  Widget build(BuildContext context) {
    final v = _v;
    if (v == null) return const SizedBox.shrink();

    final phoneOk = v['phone'] == true;
    final emailOk = v['email'] == true;
    final otpOn = v['otp_enabled'] == true;
    final phoneMode = v['mode'] == 'phone';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: phoneMode
          ? [
              _phoneCard(phoneOk, otpOn, true),
              const SizedBox(height: 12),
              _emailCard(emailOk, false),
            ]
          : [
              _emailCard(emailOk, true),
              const SizedBox(height: 12),
              _phoneCard(phoneOk, otpOn, false),
            ],
    );
  }
}

class _VCard extends StatelessWidget {
  const _VCard({
    required this.ok,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onTap,
  });

  final bool ok;
  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (ok) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.verified_rounded, color: Colors.green.shade600),
          title: Text(title),
          subtitle: Text(body),
        ),
      );
    }

    return Card(
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.tertiary),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: theme.textTheme.bodyMedium),
            if (action != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.icon(
                  onPressed: onTap,
                  icon: Icon(icon, size: 18),
                  label: Text(action!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
/// خانة رمز البريد.
///
/// **رمزٌ يُكتب لا رابطٌ يُضغط.** الرابط يفتح المتصفّح فيخرج المستخدم من
/// التطبيق، وقد يفتحه على جهازٍ آخر فلا تُحدَّث الشاشة التي ينتظرها.
/// والرمز يبقى الفعل كلّه في مكانه.
class _EmailCodeDialog extends StatefulWidget {
  const _EmailCodeDialog({required this.email});
  final String email;

  @override
  State<_EmailCodeDialog> createState() => _EmailCodeDialogState();
}

class _EmailCodeDialogState extends State<_EmailCodeDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sb = Supabase.instance.client;

      // **GoTrue هو الحارس.** لا تنجح إلا لمن يملك الصندوق فعلاً.
      await sb.auth.verifyOTP(
        type: OtpType.email,
        email: widget.email,
        token: _code.text.trim(),
      );

      // ثم نثبّت الحقيقة عندنا: `email_confirmed_at` لا يصلح دليلاً
      // لأن مُشغّل 0064 يضبطه آلياً في وضع الهاتف.
      await sb.rpc('mark_email_verified');

      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تمّ توثيق بريدك ✓')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = AppError.message(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('توثيق البريد'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('أرسلنا رمزاً إلى ${widget.email}',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(fontSize: 24, letterSpacing: 10),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              hintText: '••••••',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_code.text.trim().length == 6) _verify();
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: (_busy || _code.text.trim().length < 6) ? null : _verify,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('توثيق'),
        ),
      ],
    );
  }
}
