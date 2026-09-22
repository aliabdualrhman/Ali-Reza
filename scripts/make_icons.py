"""يولّد أيقونتي التطبيقين: زنبور يمتطي دراجة نارية.

يُشغَّل من جذر المستودع:  python scripts/make_icons.py
ثم في كل تطبيق:          dart run flutter_launcher_icons

**لماذا سكربت لا ملف صورة؟** الشعار تغيّر أربع مرات في ساعة — حجماً
وتدويراً ونصاً. ملف PNG يعني إعادة رسم يدوي في كل مرة؛ والسكربت يعني
تغيير رقم واحد وإعادة التشغيل.
"""
from PIL import Image, ImageDraw, ImageFont

S = 4096                      # نرسم بأربعة أضعاف ثم نصغّر: تنعيم بلا مكتبات
def u(v): return int(v * S / 1024)

BRAND = (245, 179, 1, 255)    # #F5B301 لون الهوية
DARK  = (30, 24, 14, 255)     # ظلّ داكن دافئ لا أسود صريح
CREAM = (255, 246, 224, 255)

CAPTAIN = "\uFEE6\uFE98\uFE91\uFE8E\uFEDB"   # "كابتن" بصيغ العرض المتصلة
FONT = r'C:\Windows\Fonts\DUBAI-BOLD.TTF'


def build_subject():
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def ell(dr, cx, cy, rx, ry, f):
        dr.ellipse([u(cx-rx), u(cy-ry), u(cx+rx), u(cy+ry)], fill=f)

    def ring(cx, cy, r, w, f, inner):
        ell(d, cx, cy, r, r, f); ell(d, cx, cy, r-w, r-w, inner)

    def line(dr, p1, p2, w, f):
        dr.line([u(p1[0]), u(p1[1]), u(p2[0]), u(p2[1])], fill=f, width=u(w))
        ell(dr, p1[0], p1[1], w/2, w/2, f); ell(dr, p2[0], p2[1], w/2, w/2, f)

    def rpoly(dr, pts, fill, r=11):
        """مضلّع بزوايا مستديرة.

        نملأ المضلّع ثم نرسم أضلاعه خطوطاً سميكة ودوائر عند رؤوسه، فتُغطّى
        كل زاوية حادة بقوس. أبسط من أقواس بيزييه، والنتيجة واحدة هنا.
        """
        dr.polygon([(u(x), u(y)) for x, y in pts], fill=fill)
        for i in range(len(pts)):
            a, b = pts[i], pts[(i+1) % len(pts)]
            dr.line([u(a[0]), u(a[1]), u(b[0]), u(b[1])], fill=fill, width=u(2*r))
        for x, y in pts:
            ell(dr, x, y, r, r, fill)

    # ---- الدراجة: إطارات سميكة وهيكل صلب. الخطوط الرفيعة تُقرأ هوائية ----
    RX, FX, WY, WR = 352, 706, 716, 116
    for cx in (RX, FX):
        ring(cx, WY, WR, 44, DARK, BRAND); ell(d, cx, WY, 32, 32, DARK)

    rpoly(d, [(322,642),(468,614),(556,566),(646,566),(676,606),
              (644,646),(468,670),(354,670)], DARK, 12)
    rpoly(d, [(448,570),(582,554),(592,594),(464,616)], DARK, 10)
    line(d, (680,606), (FX, WY-34), 40, DARK)
    line(d, (648,570), (716,498), 26, DARK)
    line(d, (680,486), (772,482), 22, DARK)
    ell(d, 476, 656, 58, 36, DARK)

    # ---- الأجنحة ----
    W = Image.new('RGBA', (S, S), (0,0,0,0)); dw = ImageDraw.Draw(W)
    ell(dw, 372, 338, 116, 50, (255,255,255,225))
    ell(dw, 338, 388, 94, 39, (255,255,255,168))
    img.alpha_composite(W.rotate(-24, resample=Image.BICUBIC, center=(u(400), u(366))))

    # ---- الجسم المخطّط: مرفوع عن الهيكل كي لا يلتحما كتلةً واحدة ----
    B = Image.new('RGBA', (S, S), (0,0,0,0)); db = ImageDraw.Draw(B)
    BX, BY, BRX, BRY = 468, 438, 130, 88
    ell(db, BX, BY, BRX, BRY, DARK)
    for off in (-50, 6, 62):
        rpoly(db, [(BX+off-11,BY-BRY-6),(BX+off+11,BY-BRY-6),
                   (BX+off+28,BY+BRY+6),(BX+off+6,BY+BRY+6)], CREAM, 7)
    # الإبرة برأس مستدير: الحدّة تبدو عدوانية في شعار خدمة نقل
    rpoly(db, [(BX-BRX+8,BY-22),(BX-BRX+8,BY+22),(BX-BRX-62,BY+2)], DARK, 13)
    img.alpha_composite(B.rotate(-16, resample=Image.BICUBIC, center=(u(BX), u(BY))))

    # ---- الرأس والذراع ----
    HX, HY = 598, 388
    line(d, (HX-26, HY+58), (706, 492), 38, DARK)
    ell(d, HX, HY, 72, 68, DARK); ell(d, HX+26, HY-8, 23, 18, CREAM)
    line(d, (HX+22, HY-56), (HX+70, HY-128), 13, DARK)
    line(d, (HX-16, HY-64), (HX+4, HY-138), 13, DARK)
    ell(d, HX+70, HY-128, 15, 15, DARK); ell(d, HX+4, HY-138, 15, 15, DARK)

    return img.crop(img.getbbox())


SUBJECT = build_subject()


def compose(px, frac, bg, caption=None):
    """يضع الرسم في مربّع شاغلاً النسبة المطلوبة، مع كلمة تحته اختياراً."""
    canvas = Image.new('RGBA', (px, px), bg)
    box = int(px * frac)
    limit_h = int(box * 0.74) if caption else box
    k = min(box / SUBJECT.width, limit_h / SUBJECT.height)
    sm = SUBJECT.resize((int(SUBJECT.width*k), int(SUBJECT.height*k)), Image.LANCZOS)
    top = (px - sm.height)//2 - (int(px*0.09) if caption else 0)
    canvas.alpha_composite(sm, ((px - sm.width)//2, top))

    if caption:
        dr = ImageDraw.Draw(canvas)
        f = ImageFont.truetype(FONT, int(px*0.17))
        bb = dr.textbbox((0, 0), caption, font=f)
        dr.text((px//2 - (bb[2]-bb[0])//2 - bb[0],
                 top + sm.height + int(px*0.02) - bb[1]), caption, font=f, fill=DARK)
    return canvas


# النسب: المربّعة تترك هامشاً كي لا تُقصّ العجلات عند الحافة.
#
# **والطبقة الأمامية أصغر عمداً:** أندرويد يقصّ الأيقونة التكيّفية بدائرة
# أو معيّن ولا يضمن إلا ٦٦٪ من الضلع. تكبيرها لتملأ المربّع يقطع القرون
# والإطارات على أول جهاز بقناع دائري.
compose(1024, 0.86, BRAND).convert('RGB').save('assets/app_icon.png', 'PNG')
compose(1024, 0.72, (0, 0, 0, 0)).save('assets/app_icon_fg.png')
compose(1024, 0.86, BRAND, CAPTAIN).convert('RGB').save('assets/app_icon_driver.png', 'PNG')
compose(1024, 0.70, (0, 0, 0, 0), CAPTAIN).save('assets/app_icon_driver_fg.png')
print('generated 4 icon files in assets/')
