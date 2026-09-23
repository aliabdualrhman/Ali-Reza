# Codemagic → TestFlight — دليل عليّ خطوة بخطوة

المستودع: https://github.com/aliabdualrhman/Ali-Reza  
ملف البناء: `codemagic.yaml` في جذر المشروع  
Workflow الأول للتجربة: **iOS — زنبور (الراكب)**

---

## ٠) ما هو جاهز في المشروع (لا تعِد عمله)

| البند | الحالة |
|---|---|
| Bundle ID الراكب | `iq.zanbour.rider` |
| Bundle ID السائق | `iq.zanbour.driver` |
| اسم الشاشة | زنبور / كابتن زنبور |
| الأيقونات iOS (كل المقاسات + 1024 بلا شفافية) | جاهزة |
| أيقونة المتجر 1024 | `docs/store/icon_1024_rider.png` و `icon_1024_driver.png` |
| نصوص المتجر العربية | `docs/store/README.md` |
| توقيع Codemagic + رفع TestFlight | في `codemagic.yaml` |
| أذونات الموقع/الكاميرا/الإشعارات | في `Info.plist` |
| تشفير معفى (`ITSAppUsesNonExemptEncryption`) | مضبوط |
| Team ID آبل | `VHLSHY892L` (في Xcode الراكب) |
| APNs Auth Key في Firebase (الراكب) | **مرفوع** — Key ID `HYAXR2K9KQ` (Development + Production) |

---

## ١) حساب آبل — مرّة واحدة

1. اشترك في [Apple Developer Program](https://developer.apple.com/programs/) (٩٩$/سنة) إن لم تكن مشتركاً.
2. افتح [App Store Connect](https://appstoreconnect.apple.com) ← **Apps** ← **+** ← New App:
   - **Platforms:** iOS  
   - **Name:** زنبور  
   - **Bundle ID:** `iq.zanbour.rider` (أنشئه أولاً في Certificates, Identifiers & Profiles إن لم يظهر)  
   - **SKU:** `zanbour-rider`  
   - Primary language: Arabic
3. كرّر للسائق: الاسم **كابتن زنبور**، Bundle ID `iq.zanbour.driver`، SKU `zanbour-driver`.
4. في كل تطبيق: **TestFlight** ← Internal Testing ← أضف بريدك كمختبر.

### مفتاح API لـ Codemagic

1. App Store Connect ← **Users and Access** ← **Integrations** ← **App Store Connect API** ← Generate Key  
   الصلاحية: **Admin** أو **App Manager**
2. احفظ ملف `.p8` وKey ID وIssuer ID — يُنزَّل الملف **مرّة واحدة فقط**.

---

## ٢) Firebase — ملفات iOS (إلزامي للإشعارات)

بدون `GoogleService-Info.plist` يرفض سكربت Codemagic البناء عمداً.

التطبيقات **مسجّلة مسبقاً** في مشروع `zanbour-3b774` (لا تضغط Add app):
`iq.zanbour.rider` و`iq.zanbour.driver` على Android وiOS، بالإضافة إلى `.test` و`admin`.

1. [Firebase Console](https://console.firebase.google.com) ← مشروع زنبور  
2. ⚙️ Project settings ← **Your apps**  
3. بجانب **`iq.zanbour.rider` (iOS)** اضغط الترس ⚙️ ← نزّل `GoogleService-Info.plist` →

```
apps/rider/ios/Runner/GoogleService-Info.plist
```

4. بجانب **`iq.zanbour.driver` (iOS)** اضغط الترس ⚙️ ← نزّل الملف →

```
apps/driver/ios/Runner/GoogleService-Info.plist
```

5. **إشعارات iOS (الراكب) — APNs Auth Key** ✅ **تم** (لا تعِد الرفع):

   | الحقل | القيمة |
   |-------|--------|
   | التطبيق في Firebase | `iq.zanbour.rider` |
   | Key ID | `HYAXR2K9KQ` |
   | Team ID | `VHLSHY892L` |
   | Development + Production | كلاهما مضبوط |

   المفتاح المحلي محفوظ في `.codemagic-secrets/AuthKey_HYAXR2K9KQ.p8` (ليس في Git).

إن لم يكن عندك بعد `apps/driver/.env` فانسخ قالب السائق واملأه:

```
copy apps\driver\.env.example apps\driver\.env
```

(غالباً نفس `SUPABASE_*` و`GEOAPIFY_KEY` كـالراكب.)

---

## ٣) ترميز الأسرار على ويندوز

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare-codemagic.ps1
```

إن نجح، ستجد في `.codemagic-secrets/` ملفات جاهزة للصق.  
إن فشل، السكربت يخبرك أي ملف ناقص.

---

## ٤) إضافة التطبيق في Codemagic

1. ادخل [codemagic.io](https://codemagic.io) وسجّل الدخول بـ GitHub.
2. **Add application** ← اختر مستودع **Ali-Reza**.
3. **Project type:** Flutter App  
4. **Select project root:** اترك الجذر (حيث `codemagic.yaml`) — **لا** تختر `apps/rider`.
5. Finish.

---

## ٥) ربط App Store Connect في Codemagic

1. Teams ← **Integrations** ← Developer Portal  
2. أضف مفتاح API بالاسم **بالضبط:** `zanbour_asc`  
   (Issuer ID + Key ID + ملف `.p8`)

Codemagic يقرأ هذا الاسم من `codemagic.yaml` — أي اسم آخر يفشل البناء.

---

## ٦) مجموعة المتغيرات `zanbour`

App settings ← **Environment variables** ← مجموعة باسم **`zanbour`**، كلها **Secure**:

| المتغير | المصدر |
|---|---|
| `RIDER_ENV_B64` | محتوى `.codemagic-secrets/RIDER_ENV_B64.txt` |
| `DRIVER_ENV_B64` | `.codemagic-secrets/DRIVER_ENV_B64.txt` |
| `RIDER_GSI_B64` | `.codemagic-secrets/RIDER_GSI_B64.txt` |
| `DRIVER_GSI_B64` | `.codemagic-secrets/DRIVER_GSI_B64.txt` |
| `GEOAPIFY_KEY` | `.codemagic-secrets/GEOAPIFY_KEY.txt` (نص عادي لا base64) |

---

## ٧) تشغيل البناء وTestFlight

1. في Codemagic اختر workflow **iOS — زنبور (الراكب)**  
2. Start new build  
3. انتظر (~٢٠–٤٠ دقيقة على `mac_mini_m2`)  
4. عند النجاح: `submit_to_testflight: true` يرفع الـ IPA تلقائياً  
5. بعد دقائق إلى ساعة: App Store Connect ← TestFlight ← Internal ← ثبّت على آيفونك من تطبيق TestFlight

**رقم البناء** يأتي من `$BUILD_NUMBER` في Codemagic — يزيد تلقائياً؛ لا تغيّره يدوياً إلا عند تعارض مع رقم قديم في App Store Connect.

---

## ٨) تفاصيل المتجر (الصق عند إنشاء الصفحة)

### الراكب — `iq.zanbour.rider`

- **Name:** زنبور  
- **Subtitle:** توصيل دراجة وتكتك  
- **Icon 1024:** `docs/store/icon_1024_rider.png`  
- **الوصف:** انسخ من `docs/store/README.md` قسم «تطبيق الراكب»  
- **Category:** Navigation  
- **Age:** 12+ (عادةً لتطبيقات النقل)  
- **Encryption:** لا يستخدم تشفيراً غير معفى — أجب No (مضبوط أيضاً في Info.plist)

### السائق — `iq.zanbour.driver`

- **Name:** كابتن زنبور  
- **Icon 1024:** `docs/store/icon_1024_driver.png`  
- **الوصف:** من نفس الملف قسم السائق

لقطات الشاشة لـ TestFlight الداخلي **اختيارية**؛ للنشر العام على App Store تحتاج لقطات آيفون.

---

## أعطال شائعة

| الرسالة / العرض | الحل |
|---|---|
| `RIDER_GSI_B64 غير مضبوط` | نزّل plist من Firebase وشغّل السكربت وأعد لصق المتغير |
| فشل التوقيع / no profiles | تأكد أن Integration اسمها `zanbour_asc` وأن Bundle ID موجود في حسابك |
| خريطة فارغة بعد التثبيت | `GEOAPIFY_KEY` ناقص أو خاطئ في مجموعة zanbour |
| لا إشعارات | APNs غير مرفوع إلى Firebase — التطبيق يعمل لكن الإشعار صامت |
| رفض Apple «alpha channel» | أيقوناتنا RGB بلا شفافية — إن استبدلت الأيقونة أعد توليد `flutter_launcher_icons` |

---

## ملاحظة عن GitHub Desktop

بعد أي تعديل ترفعه للبناء، اعمل **Commit** ثم **Push** من GitHub Desktop حتى يقرأ Codemagic آخر الشيفرة.  
ملفات `.env` و`GoogleService-Info.plist` **لا تُرفع** إلى GitHub — تذهب فقط كمتغيرات Secure في Codemagic.
