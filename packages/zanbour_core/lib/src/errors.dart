import 'package:supabase_flutter/supabase_flutter.dart';

/// تحويل أخطاء Supabase وبوستغرس إلى رسائل عربية مفهومة.
///
/// **لماذا نحتاج هذا؟** الأخطاء تصل بالإنجليزية وبصياغة تقنية:
/// `duplicate key value violates unique constraint "profiles_phone_key"`.
/// عرضها كما هي يربك المستخدم ويكشف بنية قاعدة بياناتنا في آن واحد.
///
/// أضفنا رسائل عربية داخل دوال القاعدة نفسها، فما يصل منها يُعرض كما هو.
/// هذه الدالة تعالج ما تبقّى: أخطاء Supabase Auth وقيود القاعدة الخام.
class AppError {
  AppError._();

  static String message(Object e) {
    if (e is AuthException) return _auth(e);
    if (e is PostgrestException) return _postgrest(e);
    if (e is StorageException) return 'تعذّر رفع الصورة. تحقق من اتصالك.';

    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Connection refused')) {
      return 'لا يوجد اتصال بالإنترنت';
    }
    if (s.contains('TimeoutException')) {
      return 'انتهت مهلة الاتصال. حاول مرة أخرى.';
    }
    return 'حدث خطأ غير متوقع. حاول مرة أخرى.';
  }

  static String _auth(AuthException e) {
    final m = e.message.toLowerCase();

    if (m.contains('invalid login credentials')) {
      return 'البريد أو كلمة المرور غير صحيحة';
    }
    if (m.contains('email not confirmed')) {
      return 'لم تُفعّل بريدك بعد. افتح رسالة التفعيل الواصلة إليك.';
    }
    if (m.contains('user already registered') ||
        m.contains('already been registered')) {
      return 'هذا البريد مسجّل مسبقاً. سجّل دخولك أو استعد كلمة المرور.';
    }
    if (m.contains('password should be at least')) {
      return 'كلمة المرور قصيرة جداً';
    }
    if (m.contains('for security purposes') || m.contains('rate limit')) {
      return 'محاولات كثيرة متتالية. انتظر دقيقة ثم أعد المحاولة.';
    }
    if (m.contains('email address') && m.contains('invalid')) {
      return 'صيغة البريد غير صحيحة';
    }
    if (m.contains('same password')) {
      return 'كلمة المرور الجديدة مطابقة للقديمة';
    }

    // الرسائل التي نطلقها من مُشغّل handle_new_user تصل هنا بالعربية أصلاً
    if (RegExp(r'[؀-ۿ]').hasMatch(e.message)) return e.message;

    // **قيود القاعدة تصل هنا مطموسة.** حين يخالف الحقلُ قيداً في
    // `profiles`، يبتلع GoTrue الخطأ ويردّ «Database error saving new
    // user» — فيقرأ المستخدم «تعذّر إتمام العملية» ولا يعرف أيّ حقلٍ
    // أخطأ فيه، ويعيد المحاولة بنفس الخطأ حتى ييأس.
    //
    // واسم القيد يبقى في النصّ الخام، فنترجمه إلى ما يفعله المستخدم.
    if (m.contains('profiles_phone_iraqi_format') || m.contains('phone')) {
      if (m.contains('constraint') || m.contains('database error')) {
        return 'رقم الهاتف يجب أن يبدأ بـ+964 — مثال: +9647801711922';
      }
    }
    if (m.contains('profiles_full_name_triple')) {
      return 'الاسم يجب أن يكون ثلاثياً — ثلاث كلمات على الأقل';
    }
    if (m.contains('profiles_address') || m.contains('address')) {
      if (m.contains('constraint')) return 'العنوان قصير جداً';
    }
    if (m.contains('date_of_birth') || m.contains('age')) {
      if (m.contains('constraint')) return 'تاريخ الميلاد غير مقبول';
    }
    if (m.contains('duplicate key') || m.contains('unique')) {
      if (m.contains('phone')) return 'رقم الهاتف مسجّل بحساب آخر';
      if (m.contains('full_name')) return 'هذا الاسم مستعمل. أضف اسم جدّك.';
      return 'إحدى بياناتك مسجّلة بحساب آخر';
    }

    // **آخر ملاذ يحمل دليلاً.** الرسالة الصمّاء لا تدلّ على شيء، وإرفاق
    // النصّ الخام يجعل بلاغ المستخدم صالحاً للتشخيص بدل «لا يعمل».
    if (m.contains('database error')) {
      return 'تعذّر حفظ بياناتك — تحقّق من صيغة الهاتف (+964…) '
          'والاسم الثلاثي.';
    }

    return 'تعذّر إتمام العملية. حاول مرة أخرى.';
  }

  static String _postgrest(PostgrestException e) {
    // رسائلنا العربية من دوال القاعدة (raise exception) تُمرَّر كما هي
    if (RegExp(r'[؀-ۿ]').hasMatch(e.message)) return e.message;

    switch (e.code) {
      case '23505': // unique_violation
        final m = e.message;
        if (m.contains('phone')) return 'رقم الهاتف مسجّل مسبقاً';
        if (m.contains('email')) return 'البريد الإلكتروني مسجّل مسبقاً';
        if (m.contains('full_name')) return 'الاسم مسجّل مسبقاً';
        return 'هذه البيانات مسجّلة مسبقاً';

      case '23514': // check_violation
        return 'إحدى القيم المدخلة غير صالحة';

      case '23503': // foreign_key_violation
        return 'البيانات المرتبطة غير موجودة';

      case '42501': // insufficient_privilege
        return 'لا تملك صلاحية هذه العملية';

      case 'PGRST301':
        return 'انتهت جلستك. سجّل دخولك مرة أخرى.';

      // نُلحق رمز الخطأ بالرسالة العامة. يبدو تقنياً للمستخدم، لكنه
      // يختصر ساعات تشخيص حين يبلّغ عن عطل — الرسالة الصمّاء لا تدلّ
      // على شيء، والرمز يحدد السبب فوراً.
      default:
        return 'تعذّر إتمام العملية. حاول مرة أخرى.'
            '${e.code != null ? ' (رمز: ${e.code})' : ''}';
    }
  }
}
