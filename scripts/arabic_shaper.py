"""تشكيل النص العربي للرسم على الصور.

**لماذا نحتاجه؟** مكتبة Pillow هنا بلا Raqm، فترسم الحروف منفصلة
ومقلوبة: «زنبور» تصير «ر و ب ن ز». وتشكيل الحروف يدوياً — كما جرّبتُ —
يخطئ في أول كلمة غير محفوظة.

هذا يطبّق قواعد الاتصال القياسية: لكل حرف أربع صور (منفصلة، نهائية،
ابتدائية، وسطية)، وصورتُه تتحدد بجاريه. وسبعة حروف لا تتصل بما بعدها
(ا د ذ ر ز و ة وأخواتها)، فالحرف الذي يليها يبدأ من جديد.

    from arabic_shaper import shape
    draw.text(xy, shape('زنبور'), font=f)
"""

# (منفصلة، نهائية، ابتدائية، وسطية) — والأخيرتان None لغير الموصولة
FORMS = {
    'ء': ('ﺀ', None, None, None),
    'آ': ('ﺁ', 'ﺂ', None, None),
    'أ': ('ﺃ', 'ﺄ', None, None),
    'ؤ': ('ﺅ', 'ﺆ', None, None),
    'إ': ('ﺇ', 'ﺈ', None, None),
    'ئ': ('ﺉ', 'ﺊ', 'ﺋ', 'ﺌ'),
    'ا': ('ﺍ', 'ﺎ', None, None),
    'ب': ('ﺏ', 'ﺐ', 'ﺑ', 'ﺒ'),
    'ة': ('ﺓ', 'ﺔ', None, None),
    'ت': ('ﺕ', 'ﺖ', 'ﺗ', 'ﺘ'),
    'ث': ('ﺙ', 'ﺚ', 'ﺛ', 'ﺜ'),
    'ج': ('ﺝ', 'ﺞ', 'ﺟ', 'ﺠ'),
    'ح': ('ﺡ', 'ﺢ', 'ﺣ', 'ﺤ'),
    'خ': ('ﺥ', 'ﺦ', 'ﺧ', 'ﺨ'),
    'د': ('ﺩ', 'ﺪ', None, None),
    'ذ': ('ﺫ', 'ﺬ', None, None),
    'ر': ('ﺭ', 'ﺮ', None, None),
    'ز': ('ﺯ', 'ﺰ', None, None),
    'س': ('ﺱ', 'ﺲ', 'ﺳ', 'ﺴ'),
    'ش': ('ﺵ', 'ﺶ', 'ﺷ', 'ﺸ'),
    'ص': ('ﺹ', 'ﺺ', 'ﺻ', 'ﺼ'),
    'ض': ('ﺽ', 'ﺾ', 'ﺿ', 'ﻀ'),
    'ط': ('ﻁ', 'ﻂ', 'ﻃ', 'ﻄ'),
    'ظ': ('ﻅ', 'ﻆ', 'ﻇ', 'ﻈ'),
    'ع': ('ﻉ', 'ﻊ', 'ﻋ', 'ﻌ'),
    'غ': ('ﻍ', 'ﻎ', 'ﻏ', 'ﻐ'),
    'ف': ('ﻑ', 'ﻒ', 'ﻓ', 'ﻔ'),
    'ق': ('ﻕ', 'ﻖ', 'ﻗ', 'ﻘ'),
    'ك': ('ﻙ', 'ﻚ', 'ﻛ', 'ﻜ'),
    'ل': ('ﻝ', 'ﻞ', 'ﻟ', 'ﻠ'),
    'م': ('ﻡ', 'ﻢ', 'ﻣ', 'ﻤ'),
    'ن': ('ﻥ', 'ﻦ', 'ﻧ', 'ﻨ'),
    'ه': ('ﻩ', 'ﻪ', 'ﻫ', 'ﻬ'),
    'و': ('ﻭ', 'ﻮ', None, None),
    'ى': ('ﻯ', 'ﻰ', None, None),
    'ي': ('ﻱ', 'ﻲ', 'ﻳ', 'ﻴ'),
}

# لام + ألف تُدمجان في محرف واحد. تركُهما منفصلين يظهر خطأً واضحاً
# لكل قارئ عربي، ولذلك تُعالَج قبل التشكيل لا بعده.
LAM_ALEF = {
    'آ': ('ﻵ', 'ﻶ'),
    'أ': ('ﻷ', 'ﻸ'),
    'إ': ('ﻹ', 'ﻺ'),
    'ا': ('ﻻ', 'ﻼ'),
}

# علامات التشكيل تُحذف: ترسمها Pillow في مواضع خاطئة بلا Raqm
DIACRITICS = set('ًٌٍَُِّْٓ'
                 'ٰٕٔ')


def _connects_forward(ch):
    f = FORMS.get(ch)
    return bool(f and f[2])


def _connects_backward(ch):
    f = FORMS.get(ch)
    return bool(f and f[1])


def shape(text: str) -> str:
    """يعيد النص بصيغه المتصلة ومرتّباً ليُرسم من اليسار."""
    out_lines = []

    for line in text.split('\n'):
        src = [c for c in line if c not in DIACRITICS]

        # دمج لام-ألف أولاً
        merged, i = [], 0
        while i < len(src):
            if (src[i] == 'ل' and i + 1 < len(src)
                    and src[i + 1] in LAM_ALEF):
                merged.append(('LA', LAM_ALEF[src[i + 1]]))
                i += 2
            else:
                merged.append(src[i])
                i += 1

        shaped = []
        for idx, item in enumerate(merged):
            prev = merged[idx - 1] if idx > 0 else None
            nxt = merged[idx + 1] if idx + 1 < len(merged) else None

            prev_ch = None if isinstance(prev, tuple) else prev
            nxt_ch = None if isinstance(nxt, tuple) else nxt

            # لام-ألف: لا تتصل بما بعدها، وتتصل بما قبلها
            if isinstance(item, tuple):
                joined = prev_ch is not None and _connects_forward(prev_ch)
                shaped.append(item[1][1] if joined else item[1][0])
                continue

            if item not in FORMS:
                shaped.append(item)
                continue

            _, fin, ini, med = FORMS[item]
            # **الصورة المنفصلة = الحرف الأصلي نفسه.** كثير من الخطوط
            # العربية — ومنها Dubai — لا تحوي صيغ العرض المنفصلة
            # (ﺍ ﺭ ﺯ ﻭ ﺀ) فتُرسم مربعات فارغة، بينما الحرف الأساسي
            # موجود دائماً ويظهر بالشكل نفسه.
            iso = item
            # الحرف السابق يصل إلينا؟ (ولام-ألف تصل بما بعدها لا)
            join_prev = (prev_ch is not None and _connects_forward(prev_ch))
            join_next = (nxt_ch is not None and _connects_backward(nxt_ch)) or \
                        (isinstance(nxt, tuple))

            if join_prev and join_next and med:
                shaped.append(med)
            elif join_prev and fin:
                shaped.append(fin)
            elif join_next and ini:
                shaped.append(ini)
            else:
                shaped.append(iso)

        # **العكس في النهاية.** Pillow ترسم من اليسار دائماً، فنسلّمها
        # النص معكوساً ليخرج بالاتجاه الصحيح على الصورة.
        out_lines.append(''.join(reversed(shaped)))

    return '\n'.join(out_lines)


if __name__ == '__main__':
    # نكتب إلى ملف لا إلى الطرفية: cp1252 في ويندوز لا تعرف العربية
    # وتُسقط السكربت بخطأ ترميز بعد أن يكون قد نجح.
    import io as _io
    with _io.open('docs/store/_shaper_test.txt', 'w', encoding='utf-8') as f:
        for w in ['زنبور', 'كابتن زنبور', 'الناصرية', 'رحلتك بضغطة واحدة',
                  'اعمل بدراجتك وقتما تشاء', 'لا إله إلا الله']:
            f.write(w + '  ->  ' + shape(w) + '\n')
    print('wrote docs/store/_shaper_test.txt')
