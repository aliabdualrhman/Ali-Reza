# قائمة رفع الراكب إلى Apple (GitHub → Codemagic → App Store)

آخر تحديث: إصدار `1.0.3` — Bundle `iq.zanbour.rider`

---

## أ) قبل البدء — جاهز في المشروع

| البند | الحالة |
|---|---|
| Bundle ID / Team / Entitlements / Info.plist | جاهز |
| `codemagic.yaml` workflow الراكب | جاهز |
| أسرار محلية بعد `prepare-codemagic.ps1` | جاهز في `.codemagic-secrets/` |
| أيقونة المتجر 1024 | `docs/store/icon_1024_rider.png` |
| نصوص المتجر | `docs/store/README.md` + `apps/rider/APP_STORE_RELEASE_1.0.3.md` |

---

## ب) GitHub

1. تأكد أن آخر التعديلات على `main` مرفوعة إلى  
   https://github.com/aliabdualrhman/Ali-Reza  
2. إن لم يُرفع تلقائياً: افتح **GitHub Desktop** → Commit → **Push origin**.

لا ترفع `.env` ولا `GoogleService-Info.plist` ولا `.codemagic-secrets/` (مستثناة من git عمداً).

---

## ج) Codemagic — مرّة واحدة إن لم تُضبط بعد

1. [codemagic.io](https://codemagic.io) ← تطبيق مستودع **Ali-Reza** (جذر المشروع).
2. Integrations ← Developer Portal ← مفتاح باسم **`zanbour_asc`** بالضبط.
3. Environment variables ← مجموعة **`zanbour`** (Secure)، الصق من `.codemagic-secrets/`:

| المتغير | الملف |
|---|---|
| `RIDER_ENV_B64` | `RIDER_ENV_B64.txt` |
| `RIDER_GSI_B64` | `RIDER_GSI_B64.txt` |
| `GEOAPIFY_KEY` | `GEOAPIFY_KEY.txt` |
| `DRIVER_ENV_B64` / `DRIVER_GSI_B64` | إن لم تكن موجودة مسبقاً |

4. Start new build → workflow **iOS — زنبور (الراكب)**.
5. عند النجاح يُرفع الـ IPA إلى **TestFlight** تلقائياً.

تفاصيل أطول: [`CODEMAGIC.md`](CODEMAGIC.md)

---

## د) App Store Connect — النشر

1. افتح التطبيق **زنبور** (`iq.zanbour.rider`).
2. **TestFlight** ← ثبّت على جهازك واختبر.
3. لرفع المتجر العام: **App Store** ← نسخة جديدة `1.0.3`  
   - الصق «ما الجديد» من `apps/rider/APP_STORE_RELEASE_1.0.3.md`  
   - الصق الاسم/الوصف/الأيقونة من `docs/store/README.md`  
   - ارفع لقطات شاشة آيفون (٢–٨) إن لم ترفع من قبل  
4. Encryption: **No**  
5. **Submit for Review**.

---

## هـ) أرقام مهمة

- Team ID: `VHLSHY892L`  
- APNs Key ID: `HYAXR2K9KQ` (مرفوع في Firebase للراكب)  
- رقم بناء Codemagic = `$BUILD_NUMBER` (يزيد تلقائياً)
