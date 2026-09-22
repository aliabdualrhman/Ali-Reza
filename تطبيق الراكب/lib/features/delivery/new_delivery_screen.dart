import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../shopping/location_picker_screen.dart';
import 'delivery_repository.dart';

/// طلب مندوب جديد.
///
/// **التاجر يحدّد سعر التوصيل بنفسه**، والسائق يقبل أو يرفض. والحدّ
/// الأدنى من إعدادات المدير — يُعرض هنا قبل أن يرفضه الخادم.
class NewDeliveryScreen extends ConsumerStatefulWidget {
  const NewDeliveryScreen({super.key});

  @override
  ConsumerState<NewDeliveryScreen> createState() => _NewDeliveryScreenState();
}

class _NewDeliveryScreenState extends ConsumerState<NewDeliveryScreen> {
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _landmark = TextEditingController();
  final _goods = TextEditingController();
  final _fee = TextEditingController();
  final _note = TextEditingController();

  String _vehicle = 'bike';

  /// دبوس المستلم — **اختياري**. التاجر لا يعرف بيت زبونه غالباً.
  LatLng? _pin;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in [_goods, _fee]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_phone, _address, _landmark, _goods, _fee, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  num? _num(TextEditingController c) => num.tryParse(c.text.trim());

  Future<void> _pickPin() async {
    final picked = await Navigator.of(context).push<PickedPlace>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          title: 'أين المستلم؟ (تقريباً)',
          markerIcon: Icons.person_pin_circle,
          initial: _pin,
          confirmLabel: 'هنا المستلم',
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pin = picked.point;
      if (_address.text.trim().isEmpty) _address.text = picked.address;
    });
  }

  Future<void> _submit(int minFee) async {
    final goods = _num(_goods);
    final fee = _num(_fee);

    String? err;
    if (_phone.text.trim().length < 7) {
      err = 'اكتب رقم المستلم';
    } else if (_address.text.trim().length < 3) {
      err = 'اكتب عنوان المستلم';
    } else if (goods == null || goods < 0) {
      err = 'اكتب ثمن السلعة (صفر إن كان مدفوعاً)';
    } else if (fee == null || fee < minFee) {
      err = 'أقل سعر توصيل $minFee دينار';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // المسافة للسائق وحده — «من المتجر إلى المستلم». فشلُ حسابها لا
      // يمنع الطلب: السعر حدّده التاجر أصلاً.
      int? dist;
      int? dur;
      final store = ref.read(myStoreProvider).value;
      if (_pin != null && store?['lat'] is num && store?['lng'] is num) {
        try {
          final r = await ref.read(geoServiceProvider).route(
                LatLng((store!['lat'] as num).toDouble(),
                    (store['lng'] as num).toDouble()),
                _pin!,
              );
          dist = r.distanceMeters;
          dur = r.durationSeconds;
        } catch (_) {}
      }

      await ref.read(deliveryRepositoryProvider).requestDelivery(
            recipientPhone: _phone.text.trim(),
            recipientAddress: _address.text.trim(),
            landmark: _landmark.text.trim().isEmpty
                ? null
                : _landmark.text.trim(),
            goodsPrice: goods!,
            fee: fee!,
            vehicle: _vehicle,
            dropLat: _pin?.latitude,
            dropLng: _pin?.longitude,
            distanceM: dist,
            durationS: dur,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أُرسل الطلب — نبحث عن مندوب')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(publicSettingsProvider).value ?? const {};
    final minBike =
        int.tryParse(settings['delivery_min_fee_bike_iqd'] ?? '') ?? 1000;
    final minTuk =
        int.tryParse(settings['delivery_min_fee_tuktuk_iqd'] ?? '') ?? 3000;
    final minSto =
        int.tryParse(settings['delivery_min_fee_stoota_iqd'] ?? '') ?? 5000;
    // **الستوتة أغلى من التكتك.** حمولتها أكبر وسائقها لا يعمل غير هذا.
    final minFee = switch (_vehicle) {
      'tuktuk' => minTuk,
      'stoota' => minSto,
      _ => minBike,
    };

    final goods = _num(_goods) ?? 0;
    final fee = _num(_fee) ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('طلب مندوب')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Text('المستلم',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'رقم المستلم',
              hintText: '07xx xxx xxxx',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _address,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'عنوان المستلم',
              hintText: 'الحيّ، الشارع، رقم الدار…',
              prefixIcon: Icon(Icons.home_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _landmark,
            decoration: const InputDecoration(
              labelText: 'أقرب نقطة دالة',
              hintText: 'قرب جامع… / مقابل مدرسة…',
              prefixIcon: Icon(Icons.flag_outlined),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickPin,
                  icon: Icon(_pin == null
                      ? Icons.add_location_alt_outlined
                      : Icons.check_circle),
                  label: Text(_pin == null
                      ? 'دبوس على الخريطة (اختياري)'
                      : 'الدبوس محدّد — اضغط لتغييره'),
                ),
              ),
              if (_pin != null)
                IconButton(
                  tooltip: 'إزالة الدبوس',
                  onPressed: () => setState(() => _pin = null),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),

          const SizedBox(height: 24),
          Text('المركبة',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'bike',
                  icon: Icon(Icons.two_wheeler),
                  label: Text('دراجة')),
              ButtonSegment(
                  value: 'tuktuk',
                  icon: Icon(Icons.local_shipping_outlined),
                  label: Text('تكتك — شحنة كبيرة')),
              // **طلب الستوتة يذهب إلى الستوتات وحدها** (0105)، فالانتظار
              // قد يطول إن لم يكن قريباً منك واحد.
              ButtonSegment(
                  value: 'stoota',
                  icon: Icon(Icons.fire_truck_outlined),
                  label: Text('ستوتة — حمولة ثقيلة')),
            ],
            selected: {_vehicle},
            onSelectionChanged: (v) => setState(() => _vehicle = v.first),
          ),

          const SizedBox(height: 24),
          Text('المبالغ',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _goods,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'ثمن السلعة',
              suffixText: 'دينار',
              helperText: 'صفر إن كان الثمن مدفوعاً',
              prefixIcon: Icon(Icons.sell_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _fee,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'سعر التوصيل',
              suffixText: 'دينار',
              helperText: 'أنت تحدّده — الأقل $minFee دينار'
                  '${switch (_vehicle) {
                    'tuktuk' => ' بالتكتك',
                    'stoota' => ' بالستوتة',
                    _ => '',
                  }}',
              prefixIcon: const Icon(Icons.delivery_dining_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'ملاحظة للمندوب (اختيارية)',
              hintText: 'قابل للكسر · اتصل قبل الوصول',
              prefixIcon: Icon(Icons.sticky_note_2_outlined),
            ),
          ),

          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _Line('ثمن السلعة', '${goods.round()} دينار'),
                  _Line('سعر التوصيل', '${fee.round()} دينار'),
                  const Divider(),
                  _Line('يدفعه المستلم للمندوب',
                      '${(goods + fee).round()} دينار',
                      bold: true),
                ],
              ),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : () => _submit(minFee),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Text('اطلب المندوب', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.a, this.b, {this.bold = false});
  final String a;
  final String b;
  final bool bold;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(a)),
            Text(b,
                style: TextStyle(
                  fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                  fontSize: bold ? 18 : null,
                )),
          ],
        ),
      );
}
