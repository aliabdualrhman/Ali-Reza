# V4 — تطبيق تكسي الدراجات

منصة طلب رحلات بالدراجات النارية للسوق العراقي — تطبيق راكب، تطبيق سائق،
وباك إند مبني على Supabase.

## الحالة

المرحلة ٠ منجزة: مخطط قاعدة البيانات ومحرك المطابقة والتسعير وسياسات
الأمان مكتوبة كاملة. **لم تُطبَّق على قاعدة بيانات حقيقية بعد.**

## البنية

```
backend/supabase/migrations/   مخطط قاعدة البيانات ومنطق العمل
apps/rider/                    تطبيق الراكب (Flutter)
apps/driver/                   تطبيق السائق (Flutter)
packages/shared/               نماذج وأدوات مشتركة
docs/                          التوثيق
```

## ابدأ من هنا

| المستند | المحتوى |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | تثبيت الأدوات وتجهيز Supabase وخرائط جوجل |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | كيف يعمل النظام ولماذا صُمّم هكذا |
| [docs/ROADMAP.md](docs/ROADMAP.md) | ما أُنجز وما تبقّى |
| [docs/IOS.md](docs/IOS.md) | خطة iOS وما نلتزم به الآن ليبقى ممكناً |
| [docs/COSTS.md](docs/COSTS.md) | تكاليف التطوير والتشغيل بأرقام محدثة |

## التقنيات

- **الجوال:** Flutter (أندرويد + iOS من كود واحد)
- **الباك إند:** Supabase — PostgreSQL + PostGIS + Realtime + Auth + Storage
- **الخرائط:** Google Maps SDK + Directions API
- **الإشعارات:** Firebase Cloud Messaging

## أمان

- لا تضع مفاتيح في الكود. استخدم ملفات `.env` المستبعدة من git.
- لا تضع `service_role key` في أي تطبيق جوال — يتجاوز كل سياسات الأمان.
- قيّد مفاتيح خرائط جوجل فور إنشائها وضع تنبيه ميزانية.
