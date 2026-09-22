import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:zanbour_core/zanbour_core.dart';

import 'auth_repository.dart';

/// التقاط الصورة الحية ورفعها.
///
/// **حدّ يجب معرفته:** هذا ليس كشفاً حقيقياً عن الحياة (liveness detection).
/// من يصوّر صورة مطبوعة بالكاميرا سيمرّ. الكشف الحقيقي المضاد للانتحال
/// يحتاج مكتبة متخصصة مدفوعة.
///
/// ما نبنيه هنا **رادع + مراجعة بشرية**: نمنع الاختيار من معرض الصور
/// (`source: camera` حصراً) فيصعّب استعمال صورة جاهزة، والمراجعة اليدوية
/// للسائقين هي الضمان الفعلي.
class SelfieScreen extends ConsumerStatefulWidget {
  const SelfieScreen({super.key});

  @override
  ConsumerState<SelfieScreen> createState() => _SelfieScreenState();
}

class _SelfieScreenState extends ConsumerState<SelfieScreen> {
  File? _photo;
  bool _busy = false;
  String? _error;

  Future<void> _capture() async {
    setState(() => _error = null);
    try {
      final picked = await ImagePicker().pickImage(
        // camera حصراً لا gallery — الاختيار من المعرض يبطل الغرض كله
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        // نضغط الصورة قبل الرفع: صور هواتف اليوم تتجاوز ٥ ميجا وهو الحد
        // الذي ضبطناه على البكت، والوضوح المطلوب للتحقق أقل بكثير.
        maxWidth: 1080,
        imageQuality: 82,
      );
      if (picked != null && mounted) {
        setState(() => _photo = File(picked.path));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'تعذّر فتح الكاميرا. تأكد من منح التطبيق إذن الكاميرا.');
      }
    }
  }

  Future<void> _upload() async {
    if (_photo == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).uploadDocument(
            file: _photo!,
            docType: 'live_selfie',
          );
      // نُبطل مزوّد الملف الشخصي ليعيد قراءة identity_verified الذي
      // حدّثه المُشغّل في القاعدة، فيُحدَّث توجيه الموجّه تلقائياً.
      //
      // الراكب يُعتمد فوراً بمُشغّل auto_approve_rider_docs، فينتقل مباشرة
      // للرئيسية. السائق يبقى هنا حتى يراجع المدير وثائقه.
      ref.invalidate(myProfileProvider);
      // ننتظر إعادة القراءة قبل إخفاء مؤشر الانتظار، وإلا ومض زر
      // "متابعة" لحظة قبل أن ينقلنا الموجّه.
      await ref.read(myProfileProvider.future);
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
      appBar: AppBar(title: const Text('التحقق من الهوية')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'صورة حية لوجهك',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'خطوة واحدة تحمي حسابك وتزيد ثقة السائقين',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),

                  // معاينة دائرية بنسبة ١:١ — تشبه إطار الوجه وتوجّه
                  // المستخدم لتوسيط رأسه بلا تعليمات مكتوبة.
                  Center(
                    child: Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.surfaceContainerHighest,
                        border: Border.all(
                          color: _photo == null
                              ? theme.colorScheme.outlineVariant
                              : theme.colorScheme.primary,
                          width: 3,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _photo == null
                          ? Icon(Icons.person_outline,
                              size: 96,
                              color: theme.colorScheme.onSurfaceVariant)
                          : Image.file(_photo!, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 28),

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          _Tip('أزل النظارة الشمسية والكمامة'),
                          SizedBox(height: 8),
                          _Tip('اجعل الإضاءة على وجهك لا خلفك'),
                          SizedBox(height: 8),
                          _Tip('انظر مباشرة إلى الكاميرا'),
                        ],
                      ),
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ],

                  const SizedBox(height: 24),
                  if (_photo == null)
                    FilledButton.icon(
                      onPressed: _busy ? null : _capture,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('التقاط الصورة'),
                    )
                  else ...[
                    FilledButton(
                      onPressed: _busy ? null : _upload,
                      child: _busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.4))
                          : const Text('متابعة'),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _busy ? null : _capture,
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة الالتقاط'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_outline, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    );
  }
}
