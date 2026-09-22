/// تحويل الأرقام العربية-الهندية (٠١٢٣) والفارسية (۰۱۲۳) إلى لاتينية.
///
/// **لماذا؟** لوحة مفاتيح الهاتف بالعربية تكتب «١٠٤٣٢»، و`int.tryParse`
/// يردّ `null` عليها، و`ilike` لا يطابقها بما في القاعدة. فيبحث المدير
/// عن رقم رحلة يراه أمامه ولا يجد شيئاً.
String normalizeDigits(String input) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  final b = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    final a = arabic.indexOf(ch);
    final p = persian.indexOf(ch);
    b.write(a >= 0 ? '$a' : (p >= 0 ? '$p' : ch));
  }
  return b.toString();
}

/// رمز الرحلة كما يُقرأ ويُملى: `#10432`.
///
/// **رقم واحد يعرفه الجميع.** الراكب والسائق والمدير يسمّون الرحلة بهذا
/// الرقم حين يتصلون بالدعم — و`UUID` لا يُملى في الهاتف.
String tripCode(Object? number) {
  final n = number is num ? number.toInt() : int.tryParse('$number');
  return n == null ? '—' : '#$n';
}
