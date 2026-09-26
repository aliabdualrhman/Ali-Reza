# رفع زنبور (الراكب) إلى Apple — الإصدار 1.0.3

| الحقل | القيمة |
|--------|--------|
| Bundle ID | `iq.zanbour.rider` |
| اسم التطبيق | زنبور |
| versionName (CFBundleShortVersionString) | `1.0.3` |
| versionCode المحلي | `36` (Codemagic يستبدل رقم البناء بـ `$BUILD_NUMBER`) |
| Team ID | `VHLSHY892L` |
| المستودع | https://github.com/aliabdualrhman/Ali-Reza |
| Workflow Codemagic | **iOS — زنبور (الراكب)** |

---

## ما الجديد (What's New) — انسخه إلى App Store Connect

```
ما الجديد في هذا التحديث:
• تحسين استقرار التطبيق أثناء طلب ومتابعة الرحلة
• إصلاحات عامة لتحسين الأداء وتقليل التوقفات
• تحسين تجربة الاستخدام وسلاسة التنقّل داخل التطبيق

نوصي بتحديث التطبيق للحصول على أفضل تجربة.
```

**English (اختياري):**

```
Improved stability while requesting and tracking rides, plus general performance fixes for a smoother experience.
```

---

## حقول المتجر — انسخ من `docs/store/README.md`

- **Name:** زنبور  
- **Subtitle:** توصيل دراجة وتكتك  
- **Category:** Navigation  
- **Age:** 12+  
- **Encryption:** No (مضبوط في Info.plist: `ITSAppUsesNonExemptEncryption = false`)  
- **Icon 1024:** `docs/store/icon_1024_rider.png`  
- **الوصف الكامل:** قسم «تطبيق الراكب» في `docs/store/README.md`

---

## مسار الرفع التقني

1. **GitHub:** push فرع `main` (هذا الإصدار)  
2. **Codemagic:** workflow «iOS — زنبور (الراكب)» → يبني IPA ويرفع TestFlight تلقائياً  
3. **App Store Connect:** TestFlight للمراجعة الداخلية، ثم Submit for Review للنشر العام
