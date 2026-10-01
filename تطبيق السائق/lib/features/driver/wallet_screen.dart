import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'driver_repository.dart';

final walletHistoryProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(driverRecordProvider);
  return ref.watch(driverRepositoryProvider).walletHistory();
});

final payoutRequestsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(driverRecordProvider);
  return ref.watch(driverRepositoryProvider).payoutRequests();
});

/// ما يجب أن يبقى في المحفظة بعد أي سحب.
///
/// **ليس حدّاً أدنى للسحبة بل رصيداً محجوزاً.** العمولة تُقيَّد ديناً بعد
/// كل رحلة، والسائق الذي صفّر رصيده يصير مديناً من أول رحلة تالية ويبلغ
/// حدّ الدين بعد رحلتين فيتوقف عن العمل. هذه وسادة تُبقيه يعمل.
///
/// القاعدة تفرضه أيضاً؛ هذا للراحة لا للحماية.
const _payoutReserve = 5000;

/// حدّ الدين. حين يبلغه السائق يمنعه النظام من الاتصال حتى يعبّئ.
const _debtLimit = 3000;

/// رصيد السائق: عرضه، وتعبئته، وسحبه.
///
/// **الرصيد السالب طبيعي هنا لا خطأ.** الدفع نقدي فالسائق يقبض الأجرة
/// كاملة بيده، ونقيّد حصة المنصة ديناً عليه. الشاشة تشرح ذلك صراحةً —
/// سائق يرى رقماً سالباً بلا تفسير يظن أن التطبيق سرقه.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final driver = ref.watch(driverRecordProvider).value;
    final history = ref.watch(walletHistoryProvider);
    final payouts = ref.watch(payoutRequestsProvider);
    final settings = ref.watch(publicSettingsProvider);
    final balance = driver?.walletBalance ?? 0;
    final bonus = driver?.bonusBalance ?? 0;
    final inDebt = balance < 0;

    return Scaffold(
      appBar: AppBar(title: const Text('الرصيد')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(walletHistoryProvider);
          ref.invalidate(payoutRequestsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            // ---- البطاقة الكبرى ----
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              color: inDebt
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.primaryContainer,
              child: Column(
                children: [
                  Text(
                    inDebt ? 'عليك' : 'رصيدك',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${balance.abs().round()} دينار',
                    style: theme.textTheme.displaySmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    inDebt
                        ? 'عمولات مستحقة على رحلاتك. تُسدَّد برمز تعبئة، '
                            'وعند بلوغ $_debtLimit ديناراً يتوقف استقبال الطلبات.'
                        : 'رصيد لك. يمكنك سحبه إلى زين كاش.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),

                  // **رصيد الهدية تحت الرصيد لا بجانبه.** رقمان متجاوران
                  // متساويان في الحجم يوحيان بأن كليهما قابل للسحب، وليس
                  // كذلك — وهو أول ما يسأل عنه السائق.
                  if (bonus > 0) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.card_giftcard,
                                  color: theme.colorScheme.primary, size: 20),
                              const SizedBox(width: 8),
                              Text('رصيد هدية ${bonus.round()} دينار',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'تُخصم منه عمولة رحلاتك أولاً، فلا تزيد ديونك '
                            'حتى ينفد. ولا يُسحب نقداً.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ---- الأزرار ----
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _topUpSheet(context, ref),
                      icon: const Icon(Icons.add_card),
                      label: const Text('تعبئة رصيد'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      // نعطّله بصرياً بدل إخفائه: زر يظهر ويختفي يربك،
                      // وزر معطّل مع سبب مكتوب يُعلّم السائق القاعدة.
                      onPressed: balance > _payoutReserve
                          ? () => _payoutSheet(context, ref, balance)
                          : null,
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('سحب الأموال'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ---- شراء رصيد ----
            //
            // **زر واتساب لا بوابة دفع.** لا توجد بوابة تقبل بطاقات محلية
            // في العراق بشروط تصلح لنا اليوم، والشراء يتم بالتفاهم: يراسل
            // السائق المدير فيرسل له رمزاً. الرقم من الإعدادات لا من الكود
            // ليتغيّر بلا إعادة بناء.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: settings.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (s) {
                  final phone = s['topup_whatsapp'];
                  if (phone == null || phone.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return OutlinedButton.icon(
                    onPressed: () => _buyCredit(context, phone, driver),
                    icon: const Icon(Icons.chat),
                    label: const Text('شراء رصيد عبر واتساب'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),

            if (balance <= _payoutReserve)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'يجب أن يبقى $_payoutReserve دينار في رصيدك، '
                  'والسحب متاح لما فوقها.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),

            // ---- طلبات السحب المعلّقة ----
            payouts.maybeWhen(
              data: (rows) {
                final open = rows.where((r) => r['status'] == 'pending').toList();
                if (open.isEmpty) return const SizedBox.shrink();
                return Column(
                  children: [
                    const _SectionTitle('طلبات سحب قيد المعالجة'),
                    for (final r in open)
                      ListTile(
                        leading: const Icon(Icons.hourglass_top),
                        title: Text('${(r['amount_iqd'] as num).round()} دينار'),
                        subtitle: Text('إلى ${r['zain_phone']}',
                            textDirection: TextDirection.ltr),
                        trailing: TextButton(
                          onPressed: () async {
                            try {
                              await ref
                                  .read(driverRepositoryProvider)
                                  .cancelPayout(r['id'] as String);
                              ref.invalidate(payoutRequestsProvider);
                            } catch (e) {
                              if (context.mounted) _toast(context, e);
                            }
                          },
                          child: const Text('إلغاء'),
                        ),
                      ),
                  ],
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),

            // ---- الدعم ----
            // موضعه هنا لا في الواجهة الرئيسية: من يفتح شاشة الرصيد
            // ولديه سؤال عن عمولة أو رمز تعبئة هو من يحتاجه فعلاً.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SupportButton(
                settingKey: 'support_whatsapp_driver',
                message: 'أنا كابتن زنبور، أحتاج مساعدة.',
                label: 'تواصل مع الدعم',
              ),
            ),

            // ---- كشف الحركات ----
            const _SectionTitle('كشف الحساب'),
            history.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text(AppError.message(e))),
              ),
              data: (rows) {
                if (rows.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('لا توجد حركات بعد')),
                  );
                }
                return Column(
                  children: [
                    for (final r in rows)
                      ListTile(
                        title: Text('${r['description'] ?? _label(r['txn_type'])}'),
                        subtitle:
                            Text('${r['created_at']}'.split('T').first),
                        trailing: Text(
                          '${(r['amount_iqd'] as num) > 0 ? '+' : ''}'
                          '${(r['amount_iqd'] as num).round()}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: (r['amount_iqd'] as num) > 0
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// تعبئة الرصيد
// =============================================================================
Future<void> _topUpSheet(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
      ),
      child: _TopUpForm(controller: controller),
    ),
  );
  controller.dispose();
}

class _TopUpForm extends ConsumerStatefulWidget {
  const _TopUpForm({required this.controller});
  final TextEditingController controller;

  @override
  ConsumerState<_TopUpForm> createState() => _TopUpFormState();
}

class _TopUpFormState extends ConsumerState<_TopUpForm> {
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final balance = await ref
          .read(driverRepositoryProvider)
          .redeemTopupCode(widget.controller.text);
      ref.invalidate(walletHistoryProvider);
      ref.invalidate(driverRecordProvider);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(balance < 0
              ? 'تمّت التعبئة. بقي عليك ${balance.abs().round()} دينار'
              : 'تمّت التعبئة. رصيدك ${balance.round()} دينار'),
        ));
      }
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('تعبئة رصيد',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'أدخل رمز التعبئة المكوّن من ١٦ رقماً',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: widget.controller,
          autofocus: true,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          // نقبل الأرقام وحدها ونمنع ما زاد على ستة عشر: تنظيف الإدخال
          // عند مصدره أوضح للسائق من رسالة خطأ بعد الإرسال.
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(16),
          ],
          style: const TextStyle(fontSize: 22, letterSpacing: 2),
          decoration: const InputDecoration(
            hintText: '0000000000000000',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _busy ? null : _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4))
              : const Text('تعبئة'),
        ),
      ],
    );
  }
}

// =============================================================================
// سحب الأموال
// =============================================================================
Future<void> _payoutSheet(
    BuildContext context, WidgetRef ref, double balance) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
      ),
      child: _PayoutForm(balance: balance),
    ),
  );
}

class _PayoutForm extends ConsumerStatefulWidget {
  const _PayoutForm({required this.balance});
  final double balance;

  @override
  ConsumerState<_PayoutForm> createState() => _PayoutFormState();
}

class _PayoutFormState extends ConsumerState<_PayoutForm> {
  /// المتاح للسحب = الرصيد ناقص المحجوز. القاعدة تطرح الطلبات المعلّقة
  /// كذلك، فقد يكون المتاح الحقيقي أقل — ورسالتها هي الحكم.
  late final int _available =
      (widget.balance.floor() - _payoutReserve).clamp(0, 1 << 31);

  late final _amount = TextEditingController(text: _available.toString());
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = int.tryParse(_amount.text.trim()) ?? 0;
    if (value <= 0) {
      setState(() => _error = 'أدخل مبلغاً صحيحاً');
      return;
    }
    if (value > _available) {
      setState(() => _error =
          'أقصى ما يمكن سحبه $_available دينار — '
          'يجب أن يبقى $_payoutReserve في رصيدك');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(driverRepositoryProvider).requestPayout(value);
      ref.invalidate(payoutRequestsProvider);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('أُرسل طلب السحب. سيصلك المبلغ على زين كاش'),
        ));
      }
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('سحب الأموال',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'يُحوَّل المبلغ إلى زين كاش على رقم هاتفك المسجّل. '
          'تأكّد أن الرقم مفعّل على زين كاش. '
          'يبقى $_payoutReserve دينار في رصيدك ولا تُسحب.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _amount,
          autofocus: true,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 22),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            suffixText: 'دينار',
            helperText: 'المتاح للسحب $_available دينار',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4))
              : const Text('إرسال الطلب'),
        ),
      ],
    );
  }
}

// =============================================================================
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      );
}

void _toast(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(AppError.message(e))));
}

String _label(Object? type) => switch ('$type') {
      'trip_earning' => 'أجرة رحلة',
      'commission' => 'عمولة المنصة',
      'topup' => 'تعبئة رصيد',
      'payout' => 'سحب',
      'cancellation_fee' => 'رسوم إلغاء',
      _ => 'تسوية',
    };


/// يفتح محادثة واتساب مع المدير برسالة تعريف جاهزة.
///
/// نضمّن اسم السائق ورصيده: المدير الذي يستقبل عشرين رسالة يومياً لا
/// يجب أن يسأل كل واحد "من أنت وكم عليك".
Future<void> _buyCredit(
    BuildContext context, String phone, DriverRecord? driver) async {
  final owed = (driver?.walletBalance ?? 0) < 0
      ? 'وعليّ ${(driver!.walletBalance).abs().round()} دينار.'
      : '';
  final text = Uri.encodeComponent('مرحباً، أريد شراء رصيد لحساب زنبور. $owed');
  final uri = Uri.parse('https://wa.me/'
      '${phone.replaceAll(RegExp(r'[^0-9]'), '')}?text=$text');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
