    if (url.isEmpty || key.isEmpty || url.contains('xxxx')) {
      bootError = 'ملف .env غير مكتمل — راجع .env.example';
```example:.env.example

إذن التشغيل السابق كان إما بنسخة `.env` محلية لم تُنسخ مع المشروع، أو APK بُني على جهاز آخر وفيه المفاتيح، أو نسخة أقدم من الكود.

---

يمكنني وضع الرابط الحقيقي في `.env` الآن، لكن **بدون المفتاح العام (anon)** سيبقى التطبيق غير قادر على الاتصال بـ Supabase.

أرسل من لوحة Supabase → **Settings → API**:
1. **anon / publishable key**
2. (اختياري) مفتاح Google Maps للـ Android

وسأُكمل `.env` فوراً وأعيد بناء الـ APK.