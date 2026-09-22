"""يولّد نصوص الاتفاقيات للموقع من مصدرها في الحزمة المشتركة.

    python scripts/build_site.py

**مصدر واحد لا نسختان.** لو كتبنا النص مرة في التطبيق ومرة في الموقع
لاختلفا عند أول تعديل — والمستخدم يوافق على نسخة، ومحاميك يقرأ أخرى،
وجوجل تراجع ثالثة. يُحرَّر المصدر ثم يُعاد التوليد.
"""

import io
import os
import re

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

SRC = 'packages/zanbour_core/lib/src/legal_text.dart'
OUT = 'site/terms.js'


def grab(source: str, name: str) -> str:
    m = re.search(r"const k" + name + r" = r'''(.*?)''';", source, re.S)
    if not m:
        raise SystemExit(f'تعذّر العثور على k{name} في {SRC}')
    return m.group(1).strip()


def to_js_template(s: str) -> str:
    """يهرّب ما يكسر قالب JavaScript النصّي."""
    s = s.replace('\\', '\\\\')
    s = s.replace('`', '\\`')
    s = s.replace('$', '\\$')
    return s


def main() -> int:
    src = io.open(SRC, encoding='utf-8').read()
    body = (
        '// مولَّد آلياً من ' + SRC + '\n'
        '// لا تحرّره هنا — حرّر المصدر ثم شغّل scripts/build_site.py\n\n'
        'const RIDER_TERMS = `' + to_js_template(grab(src, 'RiderTerms')) + '`;\n\n'
        'const DRIVER_TERMS = `' + to_js_template(grab(src, 'DriverTerms')) + '`;\n'
    )
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(body)
    # نطبع بالإنجليزية: طرفية ويندوز الافتراضية cp1252 لا تعرف العربية
    # وتُسقط السكربت بخطأ ترميز بعد أن يكون قد نجح فعلاً.
    print(f'{OUT}: {len(body)} chars')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
