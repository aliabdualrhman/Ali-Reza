import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:zanbour_core/zanbour_core.dart';

import '../auth/auth_repository.dart';
import '../trip/trip_repository.dart';
import 'location_picker_screen.dart';
import '../../core/guest_gate.dart';

/// طلب تسوّق — ثلاث خطوات في شاشة واحدة.
///
/// **لماذا شاشة واحدة لا ثلاث؟** كل انتقالٍ بين شاشات يفقد جزءاً من
/// الناس، ومن كتب قائمته ثم وجد نفسه في شاشةٍ ثالثة يشكّ أنها ضاعت.
/// والخطوات هنا قصيرة: نقطتان وقائمة ورقم.
///
/// **والمحل هو نقطة الانطلاق.** يذهب إليه السائق أولاً، فالتسعير من
/// المحل إلى بابك — كما تُسعَّر أيّ رحلة.
class ShoppingScreen extends ConsumerStatefulWidget {
  const ShoppingScreen({super.key});

  @override
  ConsumerState<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends ConsumerState<ShoppingScreen> {
  final _total = TextEditingController();
  final _note = TextEditingController();

  /// اسم المحل — اختياري. النقطة على الخريطة في سوقٍ مزدحم تقع بين
  /// عشرة أبواب، والاسم هو ما يبحث عنه السائق بعينه حين يصل.
  final _shopName = TextEditingController();

  /// كل سطر: اسم السلعة، والكمية أو سعرها.
  final _items = <_Item>[_Item()];

  LatLng? _shop;
  String _shopAddress = '';
  LatLng? _drop;
  String _dropAddress = '';

  final _coupon = TextEditingController();

  /// أجرة التوصيل كما تحسبها القاعدة. تُقدَّر فور اكتمال النقطتين.
  ///
  /// **الرقم قبل الطلب لا بعده.** الراكب يقدّر ثمن البضاعة بنفسه، أما
  /// التوصيل فسعرُنا — ومن يضغط «اطلب» بلا أن يعرفه يفاجأ عند التسليم.
  num? _fare;
  bool _faring = false;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _total.dispose();
    _note.dispose();
    _shopName.dispose();
    _coupon.dispose();
    for (final i in _items) {
      i.dispose();
    }
    super.dispose();
  }

  /// يفتح شاشة الخريطة ويحفظ ما اختاره.
  Future<void> _pick({required bool isShop}) async {
    final picked = await Navigator.of(context).push<PickedPlace>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          title: isShop ? 'أين المحل؟' : 'أين نسلّمك؟',
          markerIcon: isShop ? Icons.storefront : Icons.home,
          initial: isShop ? _shop : _drop,
          confirmLabel: isShop ? 'هذا هو المحل' : 'سلّم هنا',
        ),
      ),
    );
    if (picked == null || !mounted) return;

    setState(() {
      if (isShop) {
        _shop = picked.point;
        _shopAddress = picked.address;
      } else {
        _drop = picked.point;
        _dropAddress = picked.address;
      }
      _fare = null;
    });

    _estimate();
  }

  /// **الحساب في القاعدة لا هنا.** التطبيق يعمل على جهاز المستخدم، ومن
  /// يفكّك الحزمة يعدّل حسابها. والقاعدة مصدر السعر الوحيد.
  Future<void> _estimate() async {
    if (_shop == null || _drop == null) return;

    setState(() {
      _faring = true;
      _error = null;
    });
    try {
      final route = await ref.read(geoServiceProvider).route(_shop!, _drop!);
      final r = await ref
          .read(supabaseProvider)
          .rpc('estimate_shopping', params: {
        'p_shop_lat': _shop!.latitude,
        'p_shop_lng': _shop!.longitude,
        'p_distance_m': route.distanceMeters,
        'p_duration_s': route.durationSeconds,
      });

      final m = (r as Map).cast<String, dynamic>();
      if (!mounted) return;

      if (m['available'] != true) {
        setState(() => _error = '${m['message'] ?? 'الخدمة غير متوفرة هنا'}');
        return;
      }
      setState(() => _fare = m['total'] as num?);
    } on GeoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _faring = false);
    }
  }

  bool get _ready =>
      _shop != null &&
      _drop != null &&
      _items.any((i) => i.name.text.trim().isNotEmpty) &&
      (num.tryParse(_total.text.trim()) ?? 0) > 0;

  Future<void> _submit() async {
    if (!_ready) return;
    // الضيف يكتب قائمته ويرى الأجرة، ويُسأل التسجيل عند الإرسال وحده.
    if (!await requireAccountHere(context, ref,
        reason: 'أنشئ حساباً مجانياً ليصلك طلبك.')) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final geo = ref.read(geoServiceProvider);
      final route = await geo.route(_shop!, _drop!);

      final items = [
        for (final i in _items)
          if (i.name.text.trim().isNotEmpty)
            {
              'name': i.name.text.trim(),
              'qty': i.qty.text.trim(),
            }
      ];

      await ref.read(tripRepositoryProvider).requestShopping(
            shop: _shop!,
            shopAddress: _shopAddress,
            dropoff: _drop!,
            dropoffAddress: _dropAddress,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            items: items,
            goodsEstimate: num.parse(_total.text.trim()),
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            couponCode:
                _coupon.text.trim().isEmpty ? null : _coupon.text.trim(),
            shopName:
                _shopName.text.trim().isEmpty ? null : _shopName.text.trim(),
          );

      if (!mounted) return;
      // الموجّه ينقل إلى شاشة البحث حين تصير الرحلة نشطة.
      context.go('/searching');
    } on GeoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('طلب تسوّق')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          // ---- المكانان ----
          //
          // **شاشةُ خريطةٍ كاملة لكلٍّ منهما.** كانت خريطةً صغيرة
          // ومفتاحاً يقول «المحل / التسليم»، فيضغط المستخدم عليها
          // وهو لا يدري أيّهما يحرّك — والنقطتان تتبادلان بلا أن
          // يلاحظ. والشاشة الكاملة تسأل سؤالاً واحداً وتنتظر جوابه.
          _PlaceButton(
            icon: Icons.storefront,
            label: 'المحل',
            value: _shopAddress,
            onTap: () => _pick(isShop: true),
          ),
          const SizedBox(height: 10),
          // **تحت المحل مباشرةً لا في آخر الاستمارة.** مكانه يقول ما هو:
          // اسمٌ لهذه النقطة. وفي الأسفل بجانب الملاحظة يُقرأ تعليماتٍ
          // للسائق فيُترك فارغاً.
          TextField(
            controller: _shopName,
            maxLength: 60,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'اسم المحل (اختياري)',
              hintText: 'مثلاً: أسواق الهدى',
              prefixIcon: Icon(Icons.storefront_outlined),
              helperText: 'يساعد السائق على إيجاد المحل بسرعة',
              counterText: '',
            ),
          ),
          const SizedBox(height: 10),
          _PlaceButton(
            icon: Icons.home,
            label: 'مكان التسليم',
            value: _dropAddress,
            onTap: () => _pick(isShop: false),
          ),

          // ---- القائمة ----
          const SizedBox(height: 24),
          Text('ماذا تريد؟',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'سطرٌ لكل سلعة — والكمية أو سعرها بجانبها.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),

          for (var i = 0; i < _items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _items[i].name,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'خبز',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _items[i].qty,
                      decoration: const InputDecoration(
                        hintText: '١ كيلو',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  // **لا يُحذف آخر سطر.** قائمةٌ فارغة تماماً تجعل
                  // الشاشة تبدو معطوبة.
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: _items.length == 1
                        ? null
                        : () => setState(() => _items.removeAt(i).dispose()),
                  ),
                ],
              ),
            ),

          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => _items.add(_Item())),
              icon: const Icon(Icons.add),
              label: const Text('سلعة أخرى'),
            ),
          ),

          // ---- السعر ----
          const SizedBox(height: 16),
          TextField(
            controller: _total,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'السعر التقريبي للطلب كلّه',
              suffixText: 'دينار',
              helperText: 'يراه السائق قبل القبول — والسعر النهائي بعد الشراء',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),

          // **الكوبون على التوصيل وحده.** ثمن البضاعة مال البقّال لا
          // مالنا — دفعه السائق من جيبه، فخصمٌ عليه يخرج نقداً من
          // خزينتنا. والقاعدة تفرض ذلك ولا تكتفي بهذا السطر.
          const SizedBox(height: 14),
          TextField(
            controller: _coupon,
            textCapitalization: TextCapitalization.characters,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'كود خصم (اختياري)',
              helperText: 'يُخصم من أجرة التوصيل — لا من ثمن البضاعة',
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 14),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'ملاحظة للسائق (اختيارية)',
              hintText: 'الطابق الثاني · اتصل عند الوصول',
              border: OutlineInputBorder(),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error)),
          ],

          // ---- الأجرة ----
          if (_faring) ...[
            const SizedBox(height: 20),
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ),
          ] else if (_fare != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer
                    .withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(Icons.delivery_dining,
                      size: 26, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('أجرة التوصيل',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 2),
                        Text('${_fare!.round()} دينار',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  // **ثمن البضاعة تقديرُه هو لا سعرُنا.** فصلهما يمنع
                  // ظنّ أن الأجرة تشمله.
                  if ((num.tryParse(_total.text.trim()) ?? 0) > 0)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('+ بضاعة تقريباً',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 2),
                        Text('${num.parse(_total.text.trim()).round()} دينار',
                            style: theme.textTheme.titleMedium),
                      ],
                    ),
                ],
              ),
            ),

            // **الوعد يُقيَّد قبل أن يُقطع.** رقمٌ تقديريّ يُعرض بلا
            // تنبيهٍ يُقرأ وعداً، ومن دفع أكثر عند التسليم يشعر أنه
            // خُدع — ولو كان الفرق مئتي دينار.
            if ((num.tryParse(_total.text.trim()) ?? 0) > 0) ...[
              const SizedBox(height: 8),
              Text(
                'ثمن البضاعة تقديريّ وقابلٌ للتغيير حسب السعر الفعلي. '
                'أجرة التوصيل ثابتة.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],

          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_busy || !_ready) ? null : _submit,
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56)),
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Text('اطلب الآن', style: TextStyle(fontSize: 17)),
          ),

          const SizedBox(height: 12),
          Text(
            'تدفع نقداً عند التسليم: ثمن البضاعة + أجرة التوصيل.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Item {
  final name = TextEditingController();
  final qty = TextEditingController();

  void dispose() {
    name.dispose();
    qty.dispose();
  }
}


/// زرّ اختيار مكان — يعرض ما اختير أو يدعو لاختياره.
///
/// **العنوان يظهر في الزرّ نفسه.** زرٌّ يقول «اختر المحل» ثم لا يتغيّر
/// بعد الاختيار يجعل المستخدم يضغطه ثانيةً ليتأكّد.
class _PlaceButton extends StatelessWidget {
  const _PlaceButton({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = value.isNotEmpty;

    return Material(
      color: chosen
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon,
                  size: 26,
                  color: chosen
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(
                      chosen ? value : 'اضغط للاختيار على الخريطة',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: chosen ? FontWeight.w600 : null,
                        color: chosen ? null : theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(chosen ? Icons.edit_location_alt : Icons.chevron_left,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
