# بناء زنبور على macOS — دليلٌ قائمٌ بذاته

**لمن هذا الملف؟** لعليّ، ولأيّ مساعدٍ برمجيّ يفتح المستودع على جهاز
ماك لا يعرف شيئاً عن محادثاتنا السابقة. اقرأه كاملاً قبل أول أمر.

> **الحالة عند كتابته (٨ أيلول ٢٠٢٦):** لم يُبنَ هذا المشروع على iOS
> **ولا مرّةً واحدة**. كلّ ما في هذا الملف مبنيٌّ على قراءة الإعدادات
> لا على تجربةٍ ناجحة. توقّع مفاجآت، ولا تصدّق أن شيئاً يعمل حتى تراه
> يعمل على جهازٍ حقيقي.

---

## ١) ما لا ينتقل مع `git clone`

الأسرار مُستبعَدة من المستودع عمداً. **انسخها يدوياً** من حاسبة
ويندوز إلى الماك بفلاشة — لا ترسلها في محادثة ولا بريد:

```
apps/rider/.env
apps/driver/.env
apps/rider/ios/Runner/GoogleService-Info.plist
apps/driver/ios/Runner/GoogleService-Info.plist
```

وهذه لبناء أندرويد فقط، لا يحتاجها الماك إن كنت تبني iOS وحده:

```
apps/rider/android/app/google-services.json
apps/driver/android/app/google-services.json
apps/*/android/key.properties
I:\keys\zanbour-upload.jks
```

**`GoogleService-Info.plist` هو أخطرها.** بدونه تفشل تهيئة فايربيز
عند الإقلاع — ويبتلع الفشلَ `try/catch` في `_initPush`، فيعمل التطبيق
كلّه ولا تصل إشعارةٌ واحدة، بلا رسالةِ خطأٍ تدلّ على السبب.

---

## ٢) الأدوات

| الأداة | النسخة المستعملة على ويندوز |
|---|---|
| Flutter | 3.47.2 (قناة stable) |
| هدف iOS الأدنى | 15.0 — في `Podfile` و`IPHONEOS_DEPLOYMENT_TARGET` |

على الماك:

```bash
brew install --cask flutter
sudo xcode-select --install
sudo gem install cocoapods      # أو brew install cocoapods
flutter doctor                  # يجب أن تخلو أسطر iOS من ✗
```

ثم في كل تطبيق:

```bash
cd apps/rider && flutter pub get && cd ios && pod install && cd ../..
cd apps/driver && flutter pub get && cd ios && pod install && cd ../..
```

**`pod install` ليس اختيارياً.** ملفّ `Podfile` فيه كتلة `post_install`
تحقن ماكرو `PERMISSION_LOCATION` و`PERMISSION_NOTIFICATIONS`
و`PERMISSION_CAMERA` و`PERMISSION_PHOTOS`. بدونها ترفض حزمة
`permission_handler` كلَّ إذنٍ صامتةً وهي لم تسأل المستخدم أصلاً.

---

## ٣) الإعداد في حساب آبل ولوحة فايربيز

هذه **لا تُصلَح بالشيفرة** وهي أشيع أسباب صمت الإشعارات على iOS:

1. **مفتاح APNs.** من `developer.apple.com` ← Keys ← مفتاح `.p8` جديد
   بقدرة *Apple Push Notifications service*. يُنزَّل **مرّةً واحدة**
   ولا يُنزَّل ثانيةً أبداً — احفظه.
2. ارفعه إلى Firebase ← Project Settings ← Cloud Messaging ← قسم iOS
   لكلٍّ من `iq.zanbour.rider` و`iq.zanbour.driver`، مع Key ID
   وTeam ID.
   **بدون هذه الخطوة تفشل `getToken()` بخطأ `apns-token-not-set`
   ولا يصل إشعارٌ واحد** مهما كانت الشيفرة سليمة.
3. **قدرة Push Notifications** في ملفّ التعريف (provisioning profile)
   لكلّ مُعرِّف.
4. `aps-environment` في `Runner.entitlements` مضبوطة على
   `development` — وهي تصحّ للتجربة ولـTestFlight، وآبل تستبدلها
   بـ`production` عند التوزيع من المتجر.

---

## ٤) البناء

```bash
cd apps/rider
flutter build ios --release --dart-define=GEOAPIFY_KEY=<المفتاح>
```

**`--dart-define=GEOAPIFY_KEY` إلزاميّ.** مفتاح الخرائط لا يُقرأ من
`.env` في نسخة الإصدار — يُحقن وقت الترجمة. تجده في سكربت ويندوز
`scripts/build-release.ps1` وفي `apps/*/.env`. وبدونه تُبنى الحزمة
بنجاح وتُنصَّب ولا تظهر الخرائط.

ثم من Xcode: `apps/rider/ios/Runner.xcworkspace` (لا `.xcodeproj`)
← Product ← Archive ← Distribute ← TestFlight.

---

## ٥) ما فُحص ووُجد سليماً — لا تُضِع وقتك فيه

| البند | الحال |
|---|---|
| مُعرّفا الحزمة | يطابقان `BUNDLE_ID` في ملفَّي فايربيز |
| `notice.wav` / `offer.wav` | مسجّلة في `Resources` في مشروعَي Xcode |
| `GoogleService-Info.plist` | سُجّل في المشروعين في ٨ أيلول — **لم يكن مسجّلاً قبله** |
| ماكرو `permission_handler` | في `post_install` في الـPodfile |
| `LSApplicationQueriesSchemes` | `whatsapp` و`tel` — بدونها يفشل زرّ الواتساب صامتاً. وعند السائق `waze` و`comgooglemaps` للملاحة (١٩ أيلول) |
| تتبّع موقع السائق | `AppleSettings` كاملة في `location_tracker.dart` |
| الأذون والخلفية | `Info.plist` مضبوط في التطبيقين |
| الأيقونات | ٢١ في كلٍّ منهما |

### مراجعة ١٩ أيلول — ما أُضيف بعد كتابة الدليل

طلب المندوب، والأرباح، واسم المحل، ومستحقات المتاجر، وإعادة اتصال
السائق: **شيفرة دارت واحدة للنظامين، بلا حزمٍ جديدة** تحتاج إعداداً في
iOS. ودوال الإشعار الثلاث تحمل قسم `apns` بصوته وأولويته.

وأُصلح يومها فرقان كانا يخصّان آيفون:
- **الملاحة:** `google.navigation:` و`geo:` لا يعرفهما iOS، فكان زرّ
  الملاحة يسقط إلى صفحة ويب. صار يجرّب Waze، ثم تطبيق خرائط جوجل
  (`comgooglemaps://`)، ثم خرائط آبل.
- **نوع الجهاز:** كان يُسجَّل `android` لكل هاتف. للإحصاء وحده.

**تطبيق المدير (`apps/admin_shell`) أندرويد وحده** — مديرٌ على آيفون
يفتح اللوحة في المتصفح، ولا تصله إشعاراتها إلا إن دخل تطبيق زنبور
بحسابه.

---

## ٦) أعطالٌ متوقّعة وتفسيرها

| ما تراه | السبب الأرجح |
|---|---|
| لا إشعارات إطلاقاً، والتطبيق سليم | مفتاح APNs غير مرفوع إلى فايربيز — انظر §٣ |
| `Could not locate configuration file` عند الإقلاع | `GoogleService-Info.plist` غير منسوخ إلى الماك — §١ |
| كل إذنٍ مرفوض بلا أن يُسأل المستخدم | `pod install` لم يُشغَّل — §٢ |
| خريطةٌ رمادية فارغة | `GEOAPIFY_KEY` لم يُمرَّر — §٤ |
| موقع السائق يتجمّد والشاشة مقفلة | إذن `Always` مرفوض، أو `UIBackgroundModes: location` ناقص |
| خطأٌ في `Podfile` بعد ترقية فلاتر | `pod repo update` ثم `pod install --repo-update` |

---

## ٧) للمساعد البرمجي الذي يقرأ هذا

- المشروع كلّه **عربيّ**: الواجهة، والتعليقات في الشيفرة، والحوار مع
  عليّ. اكتب بالعربية.
- الخادم Supabase. الترحيلات في `backend/supabase/migrations/`
  مرقّمة، وتُطبَّق **يدوياً** من محرّر SQL في اللوحة — لا CLI.
  والصقها كاملةً دفعةً واحدة، فاللصق المقطوع يُنتج
  `unterminated dollar-quoted string`.
- دوال الحافة في `backend/supabase/functions/` تُنشر يدوياً كذلك.
- `service_role` لا يدخل التطبيق ولا لوحة الوِب أبداً — أسرار دوال
  الحافة وحدها.
- علي مبتدئ/متوسط في البرمجة. اشرح السبب لا الأمر فقط، ولا تدّعِ أن
  شيئاً «يعمل» قبل أن تراه يعمل — قل «عدّلتُ كذا، جرّبه».
