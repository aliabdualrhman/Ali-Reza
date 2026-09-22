"""يولّد صور متجر جوجل بلاي.

    python scripts/make_store_graphics.py

يكتب في docs/store/:
  feature_rider.png    ١٠٢٤×٥٠٠ — غلاف تطبيق الراكب
  feature_driver.png   ١٠٢٤×٥٠٠ — غلاف تطبيق السائق
  icon_512.png         ٥١٢×٥١٢  — أيقونة المتجر بلا شفافية

**الغلاف يُعرض مقصوصاً أحياناً** وبأحجام مختلفة حسب الجهاز، فنُبقي
الشعار والنص في الوسط ونترك الأطراف للخلفية وحدها.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from arabic_shaper import shape

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.makedirs('docs/store', exist_ok=True)

BRAND = (245, 179, 1, 255)
DARK = (30, 24, 14, 255)
FONT_BOLD = r'C:\Windows\Fonts\DUBAI-BOLD.TTF'
FONT_REG = r'C:\Windows\Fonts\DUBAI-REGULAR.TTF'


def gradient(w, h):
    """تدرّج خفيف: المساحة المصمتة تبدو خطأ طباعة لا تصميماً."""
    img = Image.new('RGBA', (w, h), BRAND)
    d = ImageDraw.Draw(img)
    for y in range(h):
        k = y / h
        d.line([(0, y), (w, y)],
               fill=(245, int(179 - 24 * k), int(1 + 12 * k), 255))
    return img


def feature(out, title, subtitle, badge):
    W, H = 1024, 500
    img = gradient(W, H)
    d = ImageDraw.Draw(img)

    logo = Image.open('assets/app_icon.png').convert('RGBA')
    logo = logo.resize((300, 300), Image.LANCZOS)
    # قناع دائري: الغلاف مساحة واحدة، والمربّع داخلها يبدو ملصقاً
    mask = Image.new('L', (300, 300), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, 299, 299], fill=255)
    img.paste(logo, (86, 100), mask)

    f_title = ImageFont.truetype(FONT_BOLD, 88)
    f_sub = ImageFont.truetype(FONT_REG, 42)
    f_badge = ImageFont.truetype(FONT_REG, 30)

    t = shape(title)
    s = shape(subtitle)
    b = shape(badge)

    # نرسم من اليمين: النص عربي، ومحاذاته يساراً تجعله يبدو مقتطعاً
    right = W - 90
    tb = d.textbbox((0, 0), t, font=f_title)
    d.text((right - (tb[2] - tb[0]), 148), t, font=f_title, fill=DARK)

    sb = d.textbbox((0, 0), s, font=f_sub)
    d.text((right - (sb[2] - sb[0]), 262), s, font=f_sub,
           fill=(74, 59, 24, 255))

    bb = d.textbbox((0, 0), b, font=f_badge)
    bw = bb[2] - bb[0]
    d.rounded_rectangle([right - bw - 44, 340, right, 340 + 58],
                        radius=29, fill=(255, 255, 255, 105))
    d.text((right - bw - 22, 352), b, font=f_badge, fill=DARK)

    img.convert('RGB').save(out, 'PNG')
    print(out)


feature('docs/store/feature_rider.png',
        'زنبور', 'رحلتك بضغطة واحدة', 'الناصرية')

feature('docs/store/feature_driver.png',
        'كابتن زنبور', 'اعمل بدراجتك وقتما تشاء', 'الناصرية')

# أيقونة المتجر: جوجل ترفض قناة الشفافية
Image.open('assets/app_icon.png').convert('RGB').resize(
    (512, 512), Image.LANCZOS).save('docs/store/icon_512.png', 'PNG')
print('docs/store/icon_512.png')
