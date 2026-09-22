import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
// intl يصدّر صنفاً باسم TextDirection يحجب نظيره في dart:ui الذي نستعمله
// في الحقول اللاتينية. نخفيه ليبقى TextDirection.ltr مفهوماً.
import 'package:intl/intl.dart' hide TextDirection;
import 'package:zanbour_core/zanbour_core.dart';

import 'auth_repository.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _vehicle = TextEditingController();
  final _plate = TextEditingController();
  final _color = TextEditingController();

  DateTime? _birthDate;

  /// نوع المركبة — يُحدَّد مرة عند التسجيل ولا يتغيّر بعدها.
  String _vehicleKind = 'bike';
  /// قناة الوصول ورمز الدعوة — يُمرَّران في بيانات الحساب،
  /// ويلتقطهما مُشغّل في القاعدة لحظة الإنشاء (0055).
  String? _heardFrom;
  String? _heardNote;
  String? _referralCode;

  bool _busy = false;
  bool _obscure = true;
  bool _acceptedTerms = false;
  String? _error;

  /// العمر الأدنى للسائق ١٨ — يقود مركبة وينقل ركّاباً.
  /// القاعدة تفرضه أيضاً في handle_new_user؛ هذا للراحة لا للحماية.
  static const int _minAge = 18;

  @override
  void dispose() {
    for (final c in [
      _name, _email, _password, _confirm, _phone, _address,
      _vehicle, _plate, _color,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      // نفتح المنتقي عند سنّ معقول لا عند اليوم — يوفّر على المستخدم
      // تمرير عشرين سنة للخلف في كل مرة.
      initialDate: _birthDate ?? DateTime(now.year - 25, 1, 1),
      firstDate: DateTime(now.year - 100),
      lastDate: DateTime(now.year - _minAge, now.month, now.day),
      helpText: 'اختر تاريخ ميلادك',
      cancelText: 'إلغاء',
      confirmText: 'تأكيد',
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    final dobError = Validators.birthDate(_birthDate, minAge: _minAge);
    if (dobError != null) {
      setState(() => _error = dobError);
      return;
    }
    if (!_acceptedTerms) {
      setState(() => _error = 'يجب الموافقة على الشروط للمتابعة');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final outcome = await ref.read(authRepositoryProvider).signUp(
            email: _email.text,
            password: _password.text,
            fullName: _name.text,
            // نرسل الصيغة الموحّدة لا ما كتبه المستخدم — القاعدة توحّدها
            // أيضاً، لكن الاتفاق على صيغة واحدة من الطرفين يمنع المفاجآت.
            phoneE164: Validators.normalizePhone(_phone.text)!,
            birthDate: _birthDate!,
            address: _address.text,
            vehicleType: _vehicle.text,
            vehiclePlate: _plate.text,
            vehicleColor: _color.text,
            vehicleKind: _vehicleKind,
            heardFrom: _heardFrom,
            heardFromNote: _heardNote,
            referralCode: _referralCode,
          );

      if (!mounted) return;

      // **الوجهة تتبع الوضع لا ردّ GoTrue وحده.** في وضع الهاتف
      // يؤكّد مُشغّلٌ البريدَ لحظة الإنشاء (0064)، فشاشة تأكيد البريد
      // تصير حاجزاً بلا معنى — ووجهته شاشة الرمز.
      // **الجلسة هي الفيصل لا الوضع.** في وضع الهاتف نُدخل المستخدم
      // نيابةً عنه بعد التسجيل (انظر `signUp`)، فإن نجح صار عنده جلسة
      // ويستطيع طلب رمز الواتساب. وإن فشل فالبريد مطلوب فعلاً — ولا
      // معنى لإرساله إلى شاشة رمزٍ لن يستطيع طلبه.
      // **الراية لا النداء.** كان هنا نداءٌ واحد لقراءة وضع التوثيق،
      // خطؤه مبتلَع وتأخّرُه يُسقط الشرط بصمت — فيمضي المستخدم بلا رمز
      // ونظنّ الإعداد خاطئاً. صار القرار للموجّه: يقرأ الراية في كل
      // تقييم، ويعيد التقييم كلما وصلت بيانات التوثيق.
      if (outcome == SignUpOutcome.signedIn) {
        ref.read(justSignedUpProvider.notifier).set(true);
        ref.invalidate(verificationProvider);
        return;
      }

      if (outcome == SignUpOutcome.needsEmailConfirmation) {
        context.pushReplacement('/verify-email', extra: _email.text.trim());
      }
      // الحالة الأخرى: الجلسة نشطة، والموجّه ينقل تلقائياً
    } catch (e) {
      if (mounted) setState(() => _error = AppError.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLabel = _birthDate == null
        ? 'اختر تاريخ ميلادك'
        : DateFormat('d MMMM y', 'ar').format(_birthDate!);

    return Scaffold(
      appBar: AppBar(title: const Text('تسجيل سائق جديد')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'الاسم الثلاثي',
                        hintText: 'مثال: علي حسن محمد',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: Validators.fullName,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'البريد الإلكتروني',
                        prefixIcon: Icon(Icons.alternate_email),
                      ),
                      validator: Validators.email,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      textDirection: TextDirection.ltr,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                        LengthLimitingTextInputFormatter(16),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'رقم الهاتف',
                        hintText: '07701234567',
                        prefixIcon: Icon(Icons.phone_outlined),
                        helperText: 'يستخدمه السائق للاتصال بك عند الوصول',
                      ),
                      validator: Validators.phone,
                    ),
                    const SizedBox(height: 16),

                    // منتقي التاريخ داخل InputDecorator ليطابق شكل بقية
                    // الحقول ويظهر خطأه بنفس الطريقة.
                    InkWell(
                      onTap: _busy ? null : _pickBirthDate,
                      borderRadius: BorderRadius.circular(12),
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'تاريخ الميلاد',
                          prefixIcon: Icon(Icons.cake_outlined),
                        ),
                        child: Text(
                          dateLabel,
                          style: TextStyle(
                            color: _birthDate == null
                                ? theme.colorScheme.onSurfaceVariant
                                : theme.colorScheme.onSurface,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _address,
                      textInputAction: TextInputAction.next,
                      maxLines: 2,
                      minLines: 1,
                      decoration: const InputDecoration(
                        labelText: 'العنوان',
                        hintText: 'بغداد - الكرادة - شارع 62',
                        prefixIcon: Icon(Icons.location_on_outlined),
                      ),
                      validator: Validators.address,
                    ),
                    const SizedBox(height: 16),

                    // **نوع المركبة أولاً.** ما بعده من حقول يصفه —
                    // اللوحة واللون — ولا معنى لسؤالها قبل معرفة ما نصف.
                    Text('ما الذي تعمل عليه؟',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'bike',
                          icon: Icon(Icons.two_wheeler),
                          label: Text('دراجة نارية'),
                        ),
                        ButtonSegment(
                          value: 'tuktuk',
                          icon: Icon(Icons.electric_rickshaw),
                          label: Text('تكتك'),
                        ),
                        ButtonSegment(
                          value: 'stoota',
                          icon: Icon(Icons.local_shipping_outlined),
                          label: Text('ستوتة'),
                        ),
                      ],
                      selected: {_vehicleKind},
                      onSelectionChanged: (v) =>
                          setState(() => _vehicleKind = v.first),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _vehicle,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: switch (_vehicleKind) {
                          'tuktuk' => 'نوع التكتك',
                          'stoota' => 'نوع الستوتة',
                          _ => 'نوع الدراجة',
                        },
                        hintText: 'مثال: هوندا CG 150',
                        prefixIcon: const Icon(Icons.two_wheeler),
                      ),
                      validator: (v) => (v ?? '').trim().length < 3
                          ? 'اكتب نوع مركبتك'
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // اللوحة واللون: بهما يميّز الراكب دراجتك في الشارع.
                    // الاسم وحده لا يكفي حين تقف ثلاث دراجات على الرصيف.
                    TextFormField(
                      controller: _plate,
                      textInputAction: TextInputAction.next,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'رقم اللوحة (اختياري)',
                        hintText: '12345 بغداد',
                        helperText: 'تستطيع إضافته لاحقاً من حسابك',
                        prefixIcon: Icon(Icons.confirmation_number_outlined),
                      ),
                      // **اختياريّ عمداً.** كثيرٌ من الدراجات في سوقنا
                      // بلا لوحة أو بلوحةٍ لا يحفظها صاحبها، وحقلٌ
                      // إجباريّ يوقف تسجيله عند بابنا. والمدير يراجع
                      // وثائقه قبل اعتماده، فاللوحة تُستكمل هناك.
                      validator: null,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _color,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'لون الدراجة',
                        hintText: 'مثال: أحمر',
                        prefixIcon: Icon(Icons.palette_outlined),
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'اكتب لون دراجتك' : null,
                    ),
                    const SizedBox(height: 16),

                    HeardFromField(

                      onChanged: (source, note, code) {

                        _heardFrom = source;

                        _heardNote = note;

                        _referralCode = code;

                      },

                    ),

                    const SizedBox(height: 16),


                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock_outline),
                        helperText: '٨ أحرف على الأقل، وتحوي رقماً',
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: Validators.password,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _confirm,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      textDirection: TextDirection.ltr,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: 'تأكيد كلمة المرور',
                        prefixIcon: Icon(Icons.lock_reset_outlined),
                      ),
                      validator: (v) =>
                          Validators.confirmPassword(v, _password.text),
                    ),
                    const SizedBox(height: 8),

                    // النص قابل للفتح لا مجرد جملة: موافقةٌ على ما لا
                    // يستطيع المستخدم قراءته أول ما يسقط في أي نزاع.
                    TermsCheckbox(
                      value: _acceptedTerms,
                      driver: true,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _acceptedTerms = v),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                size: 20,
                                color: theme.colorScheme.onErrorContainer),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                    color: theme.colorScheme.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : const Text('إنشاء الحساب'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'بعد التسجيل ترفع وثائقك ثم ينتظر حسابك موافقة الإدارة',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
