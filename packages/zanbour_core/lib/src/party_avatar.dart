import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// صورة أحد طرفي الرحلة.
///
/// **لماذا رابط موقّع لا رابط عام؟** الصورة الحية وثيقة هوية، ومخزنها
/// خاص. جعلُه عاماً يعني أن أي شخص يخمّن المسار يرى وجه أي مستخدم إلى
/// الأبد. الرابط الموقّع ينتهي بعد ساعة، وسياسة التخزين في 0019 لا تصدره
/// أصلاً إلا لطرف رحلة نشطة.
///
/// وإن غابت الصورة أو فشل توليد الرابط نعرض الأيقونة الرمادية بدل شاشة
/// خطأ: صورة ناقصة لا تستحق تعطيل بطاقة فيها اسم وهاتف ولوحة.
class PartyAvatar extends ConsumerWidget {
  const PartyAvatar({super.key, required this.storagePath, this.radius = 28});

  /// مسار الملف داخل مخزن `documents` كما يعيده `trip_party_info.avatar_url`.
  final String? storagePath;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Icon(Icons.person,
          size: radius * 1.1, color: theme.colorScheme.onPrimaryContainer),
    );

    final path = storagePath;
    if (path == null || path.isEmpty) return fallback;

    return ref.watch(signedAvatarUrlProvider(path)).when(
          loading: () => fallback,
          error: (_, _) => fallback,
          data: (url) => url == null
              ? fallback
              : CircleAvatar(
                  radius: radius,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  foregroundImage: NetworkImage(url),
                  // يُعرض أثناء التحميل وعند فشله معاً
                  child: Icon(Icons.person,
                      size: radius * 1.1,
                      color: theme.colorScheme.onPrimaryContainer),
                ),
        );
  }
}

/// رابط موقّع صالح ساعة لملف في مخزن `documents`.
final signedAvatarUrlProvider =
    FutureProvider.family<String?, String>((ref, storagePath) async {
  try {
    return await Supabase.instance.client.storage
        .from('documents')
        .createSignedUrl(storagePath, 3600);
  } catch (_) {
    // لا صلاحية (الرحلة انتهت)، أو الملف محذوف. الأيقونة الرمادية تكفي.
    return null;
  }
});
