"""تمويه البيانات الشخصية في لقطات المتجر.

    python scripts/redact_shot.py docs/store/shots/track.png 6,64,74,70 45,78,88,82

كل مستطيل بأربعة أرقام: يسار،أعلى،يمين،أسفل — **نسبةً مئوية** من
عرض الصورة وارتفاعها لا بالبكسل، فالأرقام نفسها تصلح للقطة من هاتف
آخر بدقة مختلفة.

يكتب الناتج بلاحقة `_r` بجانب الأصل، ولا يمسّ الأصل أبداً.

**نُبكسل ولا نُشوّش.** التشويش الغاوسي عمليةٌ يمكن عكسها جزئياً
ببرامج متاحة، فيعود النص مقروءاً. والبكسلة تتلف المعلومة إتلافاً
لا رجعة فيه.
"""

import os
import sys

from PIL import Image, ImageFilter

if len(sys.argv) < 3:
    sys.exit(__doc__)

src = sys.argv[1]
img = Image.open(src).convert('RGB')
W, H = img.size

for spec in sys.argv[2:]:
    l, t, r, b = [float(v) for v in spec.split(',')]
    box = (int(W * l / 100), int(H * t / 100),
           int(W * r / 100), int(H * b / 100))
    piece = img.crop(box)
    w, h = piece.size
    if w < 2 or h < 2:
        sys.exit('rect too small: ' + spec)
    # نُصغّر إلى ~١٢ خانة عرضاً ثم نُكبّر بلا تنعيم: مربّعات صريحة
    small = piece.resize((max(1, w // 26), max(1, h // 26)), Image.BILINEAR)
    piece = small.resize((w, h), Image.NEAREST)
    # لمسة تنعيم تُذهب حدّة الحواف فتبدو البكسلة مقصودة لا عطلاً
    piece = piece.filter(ImageFilter.GaussianBlur(1.2))
    img.paste(piece, box)

root, ext = os.path.splitext(src)
out = root + '_r' + ext
img.save(out)
print(out, img.size)
