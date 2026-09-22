import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/staff/staff_page.dart'
    show isOwnerProvider, myPermissionsProvider;

/// هل يملك من فتح اللوحة هذه الصلاحية؟
///
/// **فارغةٌ حتى تصل** — لا نُظهر زرّاً ثم نُخفيه، نُظهره حين نعرف. والقفل
/// الحقيقي في القاعدة: هذا يُخفي ما سيُرفض، ولا يحمي شيئاً بنفسه.
///
/// **والمالك يرى كل شيء دائماً** — لا من القائمة. لو اعتمدنا القائمة وحدها
/// لاختفت عنه صفحةٌ نُشرت قبل ترحيل صلاحيتها، أو نُسيت في القائمة.
bool can(WidgetRef ref, String code) =>
    isOwner(ref) ||
    (ref.watch(myPermissionsProvider).value ?? const <String>{})
        .contains(code);

/// يملك واحدةً منها على الأقل — لصفحةٍ تُفتح بالرؤية أو بالفعل.
bool canAny(WidgetRef ref, List<String> codes) => codes.any((c) => can(ref, c));

/// المالك — لما لا يُوزَّع أصلاً: توزيع الصلاحيات، وتصفير اللوحة.
bool isOwner(WidgetRef ref) => ref.watch(isOwnerProvider).value ?? false;
