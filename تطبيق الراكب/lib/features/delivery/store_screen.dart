import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';
import '../shopping/location_picker_screen.dart';
import 'delivery_repository.dart';

/// «متجري» — تسجيل المتجر وتعديله، وحالة اعتماده.
///
/// يصل إليها التاجر من أيقونة المتجر في الرئيسية، **أو تلقائياً** حين
/// يضغط «اطلب مندوب» ولا متجر له بعد.
class StoreScreen extends ConsumerStatefulWidget {
  const StoreScreen({super.key});

  @override
  ConsumerState<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends ConsumerState<StoreScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();

  /// «نفس رقمي» — أكثر التجار الصغار يبيعون من هواتفهم.
  bool _samePhone = false;
  LatLng? _point;

  bool _loaded = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  void _fill(Map<String, dynamic>? s, String? myPhone) {
    if (_loaded) return;
    _loaded = true;
    if (s == null) {
      _samePhone = myPhone != null;
      return;
    }
    // **التعديل المعلّق أولاً إن وُجد.** هو ما كتبه التاجر آخر مرة؛
    // عرضُ البيانات المعتمدة مكانه يوهمه أن تعديله ضاع فيكتبه ثانيةً.
    final c = (s['pending_changes'] as Map?)?.cast<String, dynamic>() ?? s;
    _name.text = '${c['name'] ?? ''}';
    _phone.text = '${c['phone'] ?? ''}';
    _address.text = '${c['address'] ?? ''}';
    final lat = c['lat'], lng = c['lng'];
    if (lat is num && lng is num) _point = LatLng(lat.toDouble(), lng.toDouble());
    _samePhone = myPhone != null && iraqiE164(myPhone) == iraqiE164(_phone.text);
  }

  Future<void> _pickLocation() async {
    final picked = await Navigator.of(context).push<PickedPlace>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          title: 'أين متجرك؟',
          markerIcon: Icons.storefront,
          initial: _point,
          confirmLabel: 'هنا متجري',
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _point = picked.point;
      if (_address.text.trim().isEmpty) _address.text = picked.address;
    });
  }

  Future<void> _save(String? myPhone) async {
    final phone = _samePhone ? (myPhone ?? '') : _phone.text.trim();
    if (_name.text.trim().length < 2) {
      setState(() => _error = 'اكتب اسم المتجر');
      return;
    }
    if (phone.isEmpty) {
      setState(() => _error = 'اكتب رقم المتجر أو اختر «نفس رقمي»');
      return;
    }
    if (_point == null) {
      setState(() => _error = 'حدّد موقع المتجر على الخريطة');
      return;
    }

    // المعتمد يُعلَّق تعديله (0092) — «حُفظ» حينها كذبة.
    final wasApproved = const {'approved', 'suspended'}
        .contains(ref.read(myStoreProvider).value?['status']);

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(deliveryRepositoryProvider).saveStore(
            name: _name.text.trim(),
            phone: phone,
            address: _address.text.trim(),
            lat: _point!.latitude,
            lng: _point!.longitude,
          );
      ref.invalidate(myStoreProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(wasApproved
                ? 'أُرسل التعديل للمراجعة — متجرك يعمل ببياناته الحالية'
                : 'حُفظ متجرك'),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = ref.watch(myStoreProvider);
    final myPhone = ref.watch(myProfileProvider).value?['phone'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text('متجري')),
      body: store.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppError.message(e))),
        data: (s) {
          _fill(s, myPhone);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              if (s != null) ...[
                StoreStatusBanner(store: s),
                const SizedBox(height: 10),
                if (s['pending_changes'] != null)
                  _Note(
                    icon: Icons.hourglass_top,
                    color: ZanbourTheme.warning,
                    text: 'تعديلك بانتظار موافقة الإدارة. متجرك يعمل '
                        'ببياناته الحالية حتى يُعتمد.',
                  )
                else if (s['changes_rejection'] != null)
                  _Note(
                    icon: Icons.info_outline,
                    color: theme.colorScheme.error,
                    text: 'لم يُعتمد تعديلك الأخير: ${s['changes_rejection']}',
                  ),
                const SizedBox(height: 16),
              ] else ...[
                Text(
                  'سجّل متجرك لتطلب مناديب توصيل. تراجعه الإدارة وتعتمده، '
                  'ثم تطلب مندوباً متى شئت.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _name,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'اسم المتجر',
                  prefixIcon: Icon(Icons.storefront_outlined),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _samePhone,
                onChanged: myPhone == null
                    ? null
                    : (v) => setState(() => _samePhone = v ?? false),
                contentPadding: EdgeInsets.zero,
                title: const Text('رقم المتجر هو نفس رقمي'),
                subtitle: myPhone == null
                    ? null
                    : Text(myPhone, textDirection: TextDirection.ltr),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (!_samePhone)
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'رقم المتجر',
                    hintText: '07xx xxx xxxx',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _address,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'عنوان المتجر',
                  hintText: 'الحيّ، الشارع، قرب…',
                  prefixIcon: Icon(Icons.place_outlined),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickLocation,
                icon: Icon(_point == null
                    ? Icons.add_location_alt_outlined
                    : Icons.check_circle),
                label: Text(_point == null
                    ? 'حدّد موقع المتجر على الخريطة'
                    : 'الموقع محدّد — اضغط لتغييره'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : () => _save(myPhone),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56)),
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4))
                    : Text(s == null ? 'سجّل المتجر' : 'حفظ التعديلات'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// حالة اعتماد المتجر — تُعرض في «متجري» وحين يُمنع الطلب.
class StoreStatusBanner extends StatelessWidget {
  const StoreStatusBanner({super.key, required this.store});
  final Map<String, dynamic> store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, Color color, String title, String body) =
        switch ('${store['status']}') {
      'approved' => (
          Icons.verified,
          ZanbourTheme.success,
          'متجرك معتمد',
          'تستطيع طلب مندوب الآن.',
        ),
      'rejected' => (
          Icons.cancel_outlined,
          theme.colorScheme.error,
          'لم يُعتمد متجرك',
          'السبب: ${store['rejection_reason'] ?? '—'}\n'
              'عدّل البيانات واحفظها ليُراجَع من جديد.',
        ),
      'suspended' => (
          Icons.pause_circle_outline,
          theme.colorScheme.outline,
          'متجرك موقوف مؤقتاً',
          'لا تستطيع طلب مندوب حالياً. تواصل مع الدعم.',
        ),
      _ => (
          Icons.hourglass_top,
          ZanbourTheme.warning,
          'بانتظار موافقة الإدارة',
          'نراجع متجرك ونخبرك بإشعار حين يُعتمد.',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
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
                    style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold, color: color)),
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

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color))),
        ],
      );
}
