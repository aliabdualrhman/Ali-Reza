# ردّ رفض آبل 2.1(a) — تطبيق السائق `1.0.5`

## ما الذي حدث؟

المراجع دخل بحساب تجريبي على **iPad Air 11" (M3)** فرأى شاشةً حمراء
أو رسالة خطأ فور تسجيل الدخول. السبب في الكود:

1. بطاقة «مهم — إعداداتٌ ناقصة» كانت تظهر قبل أن يجيب على إذن الإشعارات
   (`notDetermined` عُومل كرفض).
2. تتبّع الموقع يبدأ تلقائياً إن كان الحساب `online` — وفشل GPS على
   جهاز المراجعة يرمي استثناءً بلا التقاط.
3. قراءة الموقع عند فتح الخريطة كانت تعرض شريطاً أحمر فوراً.

## ما أُصلح في `1.0.5+36`

- إذن الإشعارات: `provisional` مقبول، و`notDetermined` لا يُظهر تنبيهاً.
- البطاقة الحمراء على الرئيسية فقط عند رفض صريح أو تجميد بطارية.
- بدء التتبّع التلقائي يُلتقط ولا يُسقط الواجهة.
- فشل GPS عند فتح الشاشة صامت؛ الخطأ يظهر فقط عند ضغط «متصل» أو زر الموقع.
- تحريك الخريطة محمي إن لم تُبنَ بعد (وضع توافق iPad).

## نص الرد في Resolution Center (انسخه)

```
Hello,

Thank you for the report. We have fixed the issue that could appear
right after login on iPad (iPhone compatibility mode).

Root cause: a temporary “settings incomplete” alert and location
lookup could surface as an error immediately after sign-in, before
the user finished permission dialogs or when GPS was briefly
unavailable on the review device.

In version 1.0.5 we:
• Only show the push/settings alert after an explicit permission denial
• Soft-fail automatic location start so it never blocks the home screen
• Keep the map usable while location settles

Please re-test with the same demo account after installing 1.0.5.

Demo account notes:
• Sign in with the driver credentials provided in App Review notes
• Allow Location (While Using) and Notifications when prompted
• After login you should land on the driver home map (approved demo)
  or the “account under review / documents” screen (pending demo)

If anything still fails, please share a screenshot of the exact
message after login and we will address it immediately.

Best regards
```

## قبل الرفع

1. تأكد أن حساب المراجعة في App Review Information:
   - `role = driver` في `profiles`
   - صف في `drivers` مع `verification_status = approved`
   - كلمة مرور تعمل
2. ابنِ من Codemagic workflow السائق → TestFlight
3. Submit for Review مع النص أعلاه في Resolution Center
