"""
قارئ وصولات زين كاش — يستخرج الرقم المستلِم والمبلغ ورقم العملية من صورة.

**القراءة عبر Google Drive، لا عبر خدمةٍ مدفوعة.** الصورة تُرفع إلى درايفك
وتُحوَّل إلى مستند جوجل — وهي العملية نفسها التي تفعلها بيدك حين تفتح صورةً
بـ«Google Docs» فتقرأ ما فيها — ثم نأخذ نصّها **ونحذف الملف فوراً**. لا حساب
استهلاك ولا فوترة؛ حصّة درايف المعتادة تكفي.

الاستعمال اليومي:
  ١) اضغط مفتاح القصّ (Insert افتراضياً) — يفتح أداة قصّ ويندوز.
  ٢) حدّد الوصل على الشاشة.
  ٣) البرنامج يلتقطه من الحافظة **وحده** ويقرأه.
  وإن أردت يدوياً: Ctrl+V داخل النافذة، أو اسحب الملف وأفلته، أو اختر ملفاً.

الإعداد مرّة واحدة:
  ١) console.cloud.google.com ← فعّل **Google Drive API** (مجاني، بلا فوترة)
  ٢) Credentials ← Create credentials ← **OAuth client ID** ← نوعه **Desktop app**
  ٣) اضغط **⬇ Download JSON** — ولا تفتحه ولا تنسخ منه شيئاً.
  ٤) شغّل البرنامج: يجده في «التنزيلات» ويستورده وحده. وإن لم يجده
     فاضغط «استورد ملف Credentials» واختره.
  ٥) «اربط حسابي بجوجل» ← اكتب أرقام محافظ زين كاش

**والملف يُنسخ إلى مجلد الإعدادات في ويندوز.** فإن حذفته من التنزيلات أو نقلت
البرنامج أو أخرجته EXE بقي يعمل: الإعدادات في مجلد ويندوز لا بجانب
الملف التنفيذي.

لإخراجه EXE:  pyinstaller --noconsole --onefile scripts/zaincash_receipt.pyw

**ولا تُكتب أسرارك في هذا الملف.** تُحفظ في %APPDATA%\\zanbour خارج المستودع،
فلا تُرفع إلى git يوماً.

السحب والإفلات وحده يحتاج حزمةً اختيارية:  pip install tkinterdnd2
"""

import base64
import ctypes
import ctypes.wintypes as wt
import hashlib
import io
import json
import os
import re
import secrets
import sys
import threading
import time
import tkinter as tk
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from tkinter import filedialog

from PIL import Image, ImageGrab, ImageTk

try:  # اختياري: السحب والإفلات
    from tkinterdnd2 import DND_FILES, TkinterDnD
    HAS_DND = True
except Exception:
    HAS_DND = False


APP_DIR = os.path.join(os.environ.get('APPDATA', os.path.expanduser('~')),
                       'zanbour')
CONFIG = os.path.join(APP_DIR, 'zaincash.json')
CREDS = os.path.join(APP_DIR, 'credentials.json')


def here() -> str:
    """مجلد البرنامج — وهو مجلد الـEXE حين يكون مُجمَّعاً.

    **`sys.executable` لا `__file__`.** بعد التجميع بـPyInstaller يصير
    `__file__` مساراً داخل أرشيفٍ مؤقّت يُمحى عند الإغلاق.
    """
    if getattr(sys, 'frozen', False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def read_creds_file(path: str) -> tuple:
    """يقرأ ملف الاعتماد من جوجل ويعيد (المعرّف، السرّ).

    جوجل تُغلّفه بمفتاح `installed` لتطبيقات سطح المكتب و`web` لغيرها —
    ونقبل الاثنين لئلا يحتار من نزّل النوع الخطأ.
    """
    with io.open(path, encoding='utf-8') as f:
        data = json.load(f)
    node = data.get('installed') or data.get('web') or data
    cid = (node.get('client_id') or '').strip()
    sec = (node.get('client_secret') or '').strip()
    if not cid or not sec:
        raise ValueError('هذا ليس ملف اعتماد OAuth — نزّله من Credentials')
    return cid, sec


def import_creds(cfg: dict, path: str) -> str:
    """يستورد الملف، **وينسخه** إلى مجلد الإعدادات، ويعيد المعرّف."""
    cid, sec = read_creds_file(path)
    os.makedirs(APP_DIR, exist_ok=True)
    with io.open(path, encoding='utf-8') as src, \
            io.open(CREDS, 'w', encoding='utf-8') as dst:
        dst.write(src.read())

    # حسابٌ مربوطٌ بمعرّفٍ قديم لا يصلح لمعرّفٍ جديد — نُنهيه بصمت.
    if cfg.get('client_id') and cfg['client_id'] != cid:
        cfg['refresh_token'] = ''
        cfg['account'] = ''
    cfg['client_id'] = cid
    cfg['client_secret'] = sec
    save_config(cfg)
    return cid


def find_creds() -> str:
    """يبحث عن ملف الاعتماد: مجلد الإعدادات، فمجلد البرنامج، فالتنزيلات.

    **الأحدث في التنزيلات لا الأول.** من جرّب مرّتين عنده ملفان، والثاني
    هو المقصود.
    """
    if os.path.exists(CREDS):
        return CREDS

    found = []
    for folder in (here(),
                   os.path.join(os.path.expanduser('~'), 'Downloads'),
                   os.path.join(os.path.expanduser('~'), 'التنزيلات')):
        try:
            for name in os.listdir(folder):
                low = name.lower()
                if low.endswith('.json') and (
                        low.startswith('client_secret')
                        or low.startswith('credentials')):
                    full = os.path.join(folder, name)
                    found.append((os.path.getmtime(full), full))
        except Exception:
            continue

    for _, path in sorted(found, reverse=True):
        try:
            read_creds_file(path)
            return path
        except Exception:
            continue
    return ''

AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'
TOKEN_URL = 'https://oauth2.googleapis.com/token'
UPLOAD_URL = ('https://www.googleapis.com/upload/drive/v3/files'
              '?uploadType=multipart&ocrLanguage=ar&fields=id')
EXPORT_URL = ('https://www.googleapis.com/drive/v3/files/{fid}/export'
              '?mimeType=text/plain')
DELETE_URL = 'https://www.googleapis.com/drive/v3/files/{fid}'

# **`drive.file` لا `drive`.** هذا النطاق يعطي البرنامج ما أنشأه هو فقط —
# لا يرى ملفاً واحداً من ملفاتك القديمة. وهو كل ما نحتاج.
#
# ومعه البريد وحده — لا لشيء إلا أن تعرف **أيّ حساب مربوط الآن** قبل أن
# ترفع إليه وصولاتك. ورابطٌ صامتٌ لا يقول لمن هو بابُ خطأ.
SCOPE = ('https://www.googleapis.com/auth/drive.file '
         'https://www.googleapis.com/auth/userinfo.email')

REVOKE_URL = 'https://oauth2.googleapis.com/revoke'
USERINFO_URL = 'https://www.googleapis.com/oauth2/v3/userinfo'

BG = '#1c1a16'
FG = '#f2ece2'
DIM = '#9a9186'
GOLD = '#d9a441'
OK = '#5db85c'
BAD = '#d9534f'

# مفاتيحُ صالحةٌ للماكرو: لا تصطدم بشيء في أكثر البرامج.
HOTKEYS = {
    'Insert': 0x2D, 'F2': 0x71, 'F3': 0x72, 'F4': 0x73, 'F6': 0x75,
    'F7': 0x76, 'F8': 0x77, 'F9': 0x78, 'F10': 0x79, 'F12': 0x7B,
    'Pause': 0x13, 'Scroll Lock': 0x91,
}

DEFAULTS = {
    'client_id': '', 'client_secret': '', 'refresh_token': '', 'account': '',
    'wallets': [], 'hotkey_snip': 'Insert', 'hotkey_paste': 'F2',
}


# =============================================================================
# الإعدادات
# =============================================================================
def load_config() -> dict:
    cfg = dict(DEFAULTS)
    try:
        with io.open(CONFIG, encoding='utf-8') as f:
            cfg.update(json.load(f))
    except Exception:
        pass
    return cfg


def save_config(cfg: dict) -> None:
    os.makedirs(APP_DIR, exist_ok=True)
    with io.open(CONFIG, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


# =============================================================================
# التطبيع والاستخراج
# =============================================================================
AR_DIGITS = str.maketrans('٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789')


def norm_digits(s: str) -> str:
    return s.translate(AR_DIGITS)


def norm_phone(raw: str) -> str:
    """يوحّد صيغ الرقم العراقي: +9647… و009647… و7… → 07XXXXXXXXX."""
    d = re.sub(r'\D', '', norm_digits(raw))
    if d.startswith('00964'):
        d = d[5:]
    elif d.startswith('964'):
        d = d[3:]
    if not d.startswith('0'):
        d = '0' + d
    return d


# كلماتٌ تدلّ على المستلِم. الوصل يحمل رقمين — المرسِل والمستلِم — وخلطهما
# يجعل البرنامج يقول «أخضر» لوصلٍ ذهب إلى محفظةٍ أخرى.
TO_HINTS = ('إلى', 'الى', 'المستلم', 'المستفيد', 'استلم', 'to', 'recipient',
            'receiver', 'beneficiary')
FROM_HINTS = ('من', 'المرسل', 'from', 'sender')

ID_HINTS = ('رقم العملية', 'رقم المعاملة', 'رقم المرجع', 'المرجع',
            'transaction', 'trx', 'reference', 'ref', 'operation', 'id')
AMOUNT_HINTS = ('المبلغ', 'مبلغ', 'amount', 'iqd', 'د.ع', 'دينار', 'total')

PHONE_RE = re.compile(
    r'(?:\+?964|00964)?\s*0?7[\s\-]?\d{2}[\s\-]?\d{3}[\s\-]?\d{4}')
NUM_RE = re.compile(r'\d[\d,\.]{2,}')


def extract(text: str) -> dict:
    """يستخرج الحقول الثلاثة من نصّ الوصل."""
    lines = [norm_digits(l.strip()) for l in text.splitlines() if l.strip()]
    flat = '\n'.join(lines)

    # ---- الهواتف ----
    phones = []
    for i, line in enumerate(lines):
        for m in PHONE_RE.finditer(line):
            p = norm_phone(m.group())
            if len(p) == 11 and p.startswith('07'):
                phones.append((i, p, line.lower()))

    recipient = ''
    # ١) رقمٌ في سطرٍ فيه «إلى»، أو تحت سطرٍ فيه «إلى» مباشرةً.
    #
    # **ولا ننظر إلى السطر التالي.** الوصل يصفّ الطرفين هكذا:
    #     المرسل / 0771… / المستلم / 0780…
    # فلو ضممنا ما بعد الرقم لرأينا «المستلم» تحت رقم المرسِل ونسبناه
    # إليه — وهو أسوأ خطأ ممكن هنا: أخضرُ لوصلٍ ذهب إلى غيرك.
    for i, p, low in phones:
        ctx = ((lines[i - 1] if i > 0 else '') + ' ' + low).lower()
        if any(h in ctx for h in FROM_HINTS):
            continue
        if any(h in ctx for h in TO_HINTS):
            recipient = p
            break
    # ٢) وإلا: أوّل رقمٍ لا يخصّ المرسِل.
    if not recipient:
        for i, p, low in phones:
            ctx = ((lines[i - 1] if i > 0 else '') + ' ' + low).lower()
            if not any(h in ctx for h in FROM_HINTS):
                recipient = p
                break
    if not recipient and phones:
        recipient = phones[-1][1]

    # ---- المبلغ ----
    amount = ''
    for i, line in enumerate(lines):
        low = line.lower()
        if any(h in low for h in AMOUNT_HINTS):
            for cand in (line, lines[i + 1] if i + 1 < len(lines) else ''):
                for m in NUM_RE.finditer(cand):
                    v = m.group().replace(',', '').split('.')[0]
                    # المبلغ لا يكون رقم هاتف، ولا خانةً أو خانتين.
                    if v.isdigit() and 3 <= len(v) <= 9 and not v.startswith('07'):
                        amount = str(int(v))
                        break
                if amount:
                    break
        if amount:
            break

    # ---- رقم العملية ----
    trans = ''
    for i, line in enumerate(lines):
        low = line.lower()
        if any(h in low for h in ID_HINTS):
            for cand in (line, lines[i + 1] if i + 1 < len(lines) else ''):
                for m in re.finditer(r'[A-Za-z0-9]{6,}', cand):
                    v = m.group()
                    if any(h in v.lower() for h in ('transaction', 'reference')):
                        continue
                    digits = re.sub(r'\D', '', v)
                    if len(digits) >= 5 and norm_phone(v) != recipient:
                        trans = v
                        break
                if trans:
                    break
        if trans:
            break
    # احتياط: أطول سلسلة أرقامٍ ليست هاتفاً ولا المبلغ.
    if not trans:
        cands = [m.group() for m in re.finditer(r'\d{6,}', flat)]
        cands = [c for c in cands if norm_phone(c) != recipient and c != amount]
        if cands:
            trans = max(cands, key=len)

    return {'recipient': recipient, 'amount': amount, 'trans': trans,
            'phones': [p for _, p, _ in phones], 'text': flat}


# =============================================================================
# جوجل درايف: ربط الحساب، والقراءة
# =============================================================================
def _post_form(url: str, data: dict) -> dict:
    req = urllib.request.Request(
        url, data=urllib.parse.urlencode(data).encode(),
        headers={'Content-Type': 'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(req, timeout=30) as res:
        return json.loads(res.read().decode())


class _AuthHandler(BaseHTTPRequestHandler):
    """يستقبل ردّ جوجل على المتصفّح ويعيده إلى البرنامج."""

    code = None

    def do_GET(self):
        q = urllib.parse.urlparse(self.path).query
        _AuthHandler.code = urllib.parse.parse_qs(q).get('code', [None])[0]
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(
            '<html dir="rtl"><body style="font-family:sans-serif;'
            'background:#1c1a16;color:#f2ece2;text-align:center;padding:60px">'
            '<h2>تمّ الربط ✓</h2><p>أغلق هذه الصفحة وعُد إلى البرنامج.</p>'
            '</body></html>'.encode('utf-8'))

    def log_message(self, *_):
        pass


def account_email(token: str) -> str:
    try:
        req = urllib.request.Request(
            USERINFO_URL, headers={'Authorization': f'Bearer {token}'})
        with urllib.request.urlopen(req, timeout=20) as res:
            return json.loads(res.read().decode()).get('email', '')
    except Exception:
        return ''


def unlink_account(cfg: dict) -> None:
    """يُبطل الرمز عند جوجل ثم يمسحه من الجهاز.

    **الإبطال أولاً.** مسحُه من الملف وحده يترك إذناً قائماً في حسابك
    لبرنامجٍ لم يعد عندك — وهو ما يجعل «تسجيل الخروج» كلمةً بلا أثر.
    """
    token = cfg.get('refresh_token', '')
    if token:
        try:
            _post_form(REVOKE_URL, {'token': token})
        except Exception:
            # أُبطل من صفحة الحساب، أو لا شبكة — لا نمنع الخروج محلياً.
            pass
    cfg['refresh_token'] = ''
    cfg['account'] = ''
    save_config(cfg)


def link_account(client_id: str, client_secret: str) -> tuple:
    """يفتح المتصفّح ليأذن المستخدم، ويعيد `refresh_token`.

    **حلقة محلّية لا لصقُ رمزٍ بيد المستخدم.** جوجل أوقفت طريقة «انسخ
    الرمز والصقه»، والمسار المعتمد اليوم أن يردّ المتصفّح على منفذٍ
    محلّيّ يستمع للحظة.
    """
    server = HTTPServer(('127.0.0.1', 0), _AuthHandler)
    redirect = f'http://127.0.0.1:{server.server_port}'

    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')

    params = {
        'client_id': client_id,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': SCOPE,
        'access_type': 'offline',
        # **`select_account` مع `consent`.** بلا الأولى يربط جوجل الحساب
        # المفتوح في المتصفّح بلا سؤال — فمن أراد تبديل حسابه لا يستطيع.
        'prompt': 'select_account consent',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
    }
    webbrowser.open(AUTH_URL + '?' + urllib.parse.urlencode(params))

    _AuthHandler.code = None
    server.timeout = 180
    while _AuthHandler.code is None:
        server.handle_request()
        if _AuthHandler.code is None:
            raise RuntimeError('لم يصل ردّ من جوجل — أعد المحاولة')

    tok = _post_form(TOKEN_URL, {
        'client_id': client_id,
        'client_secret': client_secret,
        'code': _AuthHandler.code,
        'code_verifier': verifier,
        'grant_type': 'authorization_code',
        'redirect_uri': redirect,
    })
    rt = tok.get('refresh_token')
    if not rt:
        raise RuntimeError('لم يُعطِ جوجل رمز تجديد — جرّب الربط مرة أخرى')
    return rt, account_email(tok.get('access_token', ''))


def access_token(cfg: dict) -> str:
    tok = _post_form(TOKEN_URL, {
        'client_id': cfg['client_id'],
        'client_secret': cfg['client_secret'],
        'refresh_token': cfg['refresh_token'],
        'grant_type': 'refresh_token',
    })
    return tok['access_token']


def ocr_via_drive(image: Image.Image, token: str) -> str:
    """يرفع الصورة مستنداً، يقرأ نصّها، ثم **يحذفها**."""
    buf = io.BytesIO()
    image.convert('RGB').save(buf, format='PNG')
    png = buf.getvalue()

    boundary = '----zanbour' + secrets.token_hex(8)
    meta = json.dumps({
        'name': 'zaincash-ocr',
        # التحويل إلى مستند جوجل هو ما يُشغّل القراءة الضوئية.
        'mimeType': 'application/vnd.google-apps.document',
    }).encode()

    body = b''.join([
        f'--{boundary}\r\n'.encode(),
        b'Content-Type: application/json; charset=UTF-8\r\n\r\n',
        meta, b'\r\n',
        f'--{boundary}\r\n'.encode(),
        b'Content-Type: image/png\r\n\r\n',
        png, b'\r\n',
        f'--{boundary}--\r\n'.encode(),
    ])

    req = urllib.request.Request(
        UPLOAD_URL, data=body,
        headers={'Authorization': f'Bearer {token}',
                 'Content-Type': f'multipart/related; boundary={boundary}'})
    with urllib.request.urlopen(req, timeout=90) as res:
        fid = json.loads(res.read().decode())['id']

    try:
        req = urllib.request.Request(
            EXPORT_URL.format(fid=fid),
            headers={'Authorization': f'Bearer {token}'})
        with urllib.request.urlopen(req, timeout=90) as res:
            return res.read().decode('utf-8', errors='replace')
    finally:
        # **الحذف في `finally`.** لو فشلت القراءة لبقي الوصل في درايفك
        # يتراكم صورةً كل مرة.
        try:
            req = urllib.request.Request(
                DELETE_URL.format(fid=fid), method='DELETE',
                headers={'Authorization': f'Bearer {token}'})
            urllib.request.urlopen(req, timeout=30).close()
        except Exception:
            pass


# =============================================================================
# الماكرو: مفاتيح عامّة تعمل والبرنامج خلف نافذةٍ أخرى
# =============================================================================
WM_HOTKEY = 0x0312
MOD_NOREPEAT = 0x4000
KEYEVENTF_KEYUP = 0x0002
VK_LWIN, VK_SHIFT, VK_S, VK_CONTROL, VK_V = 0x5B, 0x10, 0x53, 0x11, 0x56


def press_snip():
    """يضغط Win+Shift+S — أداة القصّ في ويندوز."""
    u = ctypes.windll.user32
    # **تأخيرٌ صغير أولاً.** مفتاح الماكرو نفسه قد يكون مضغوطاً بعد،
    # فيبتلع ويندوز الاختصار الجديد.
    time.sleep(0.12)
    for vk in (VK_LWIN, VK_SHIFT, VK_S):
        u.keybd_event(vk, 0, 0, 0)
    for vk in (VK_S, VK_SHIFT, VK_LWIN):
        u.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)


class Hotkeys(threading.Thread):
    """يسجّل مفاتيح ويندوز العامّة في خيطٍ له حلقةُ رسائله.

    **`RegisterHotKey` يخصّ الخيط الذي سجّله**، ورسائله لا تصل إلا إلى حلقة
    رسائل ذلك الخيط — فلا يصلح تسجيلها في خيط الواجهة ثم انتظارها فيه.
    """

    def __init__(self, on_snip, on_paste):
        super().__init__(daemon=True)
        self.on_snip, self.on_paste = on_snip, on_paste
        self.keys = {}          # id -> callback
        self.pending = []       # (id, vk) لتسجيلها عند الإقلاع
        self.error = None

    def set_keys(self, snip_vk, paste_vk):
        self.pending = [(1, snip_vk), (2, paste_vk)]

    def run(self):
        u = ctypes.windll.user32
        for hid, vk in self.pending:
            if not u.RegisterHotKey(None, hid, MOD_NOREPEAT, vk):
                self.error = hid
        self.keys = {1: self.on_snip, 2: self.on_paste}

        msg = wt.MSG()
        while u.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            if msg.message == WM_HOTKEY:
                cb = self.keys.get(msg.wParam)
                if cb:
                    cb()


# =============================================================================
# الواجهة
# =============================================================================
class Field(tk.Frame):
    """حقلٌ بعنوانه وزرّ نسخه — والقيمة قابلة للتصحيح بيدك."""

    def __init__(self, master, label, mono=False):
        super().__init__(master, bg=BG)
        tk.Label(self, text=label, bg=BG, fg=DIM,
                 font=('Segoe UI', 10)).pack(anchor='e')

        row = tk.Frame(self, bg=BG)
        row.pack(fill='x', pady=(2, 0))

        self.var = tk.StringVar()
        self.entry = tk.Entry(
            row, textvariable=self.var, bg='#26231e', fg=FG,
            insertbackground=FG, relief='flat', justify='left',
            font=('Consolas' if mono else 'Segoe UI', 14))
        self.entry.pack(side='left', fill='x', expand=True, ipady=6)

        tk.Button(row, text='نسخ', command=self.copy, bg=GOLD, fg='#1c1a16',
                  relief='flat', font=('Segoe UI', 10, 'bold'),
                  activebackground='#e9b756', cursor='hand2',
                  padx=14).pack(side='left', padx=(8, 0))

        self.note = tk.Label(self, text='', bg=BG, fg=DIM,
                             font=('Segoe UI', 10))
        self.note.pack(anchor='e', pady=(2, 0))

    def set(self, value):
        self.var.set(value or '')

    def get(self):
        return self.var.get().strip()

    def copy(self):
        v = self.get()
        if not v:
            return
        self.clipboard_clear()
        self.clipboard_append(v)
        self.note.config(text='نُسخ ✓', fg=OK)
        self.after(1500, lambda: self.note.config(text=''))


class App:
    def __init__(self, root):
        self.root = root
        self.cfg = load_config()
        self.preview = None
        self.raw_text = ''
        self.last_sig = None
        self.watching = False

        root.title('قارئ وصولات زين كاش')
        root.configure(bg=BG)
        root.geometry('780x700')

        head = tk.Frame(root, bg=BG)
        head.pack(fill='x', padx=18, pady=(16, 8))
        tk.Label(head, text='قارئ وصولات زين كاش', bg=BG, fg=GOLD,
                 font=('Segoe UI', 16, 'bold')).pack(side='right')
        tk.Button(head, text='الإعدادات', command=self.settings, bg='#2e2a24',
                  fg=FG, relief='flat', cursor='hand2',
                  font=('Segoe UI', 10), padx=12).pack(side='left')

        self.drop = tk.Label(
            root, bg='#26231e', fg=DIM, font=('Segoe UI', 12), height=7,
            cursor='hand2')
        self.drop.pack(fill='x', padx=18)
        self.drop.bind('<Button-1>', lambda _: self.pick_file())
        if HAS_DND:
            self.drop.drop_target_register(DND_FILES)
            self.drop.dnd_bind('<<Drop>>', self.on_drop)

        self.status = tk.Label(root, text='', bg=BG, fg=DIM,
                               font=('Segoe UI', 10))
        self.status.pack(pady=6)

        body = tk.Frame(root, bg=BG)
        body.pack(fill='both', expand=True, padx=18, pady=(4, 12))

        self.f_recipient = Field(body, 'الرقم المُرسَل إليه', mono=True)
        self.f_recipient.pack(fill='x', pady=6)
        self.f_amount = Field(body, 'المبلغ المُرسَل', mono=True)
        self.f_amount.pack(fill='x', pady=6)
        self.f_trans = Field(body, 'رقم العملية (Trans ID)', mono=True)
        self.f_trans.pack(fill='x', pady=6)

        self.verdict = tk.Label(body, text='', bg=BG, fg=DIM,
                                font=('Segoe UI', 13, 'bold'))
        self.verdict.pack(fill='x', pady=(10, 4), ipady=8)

        tk.Button(body, text='النصّ المقروء كاملاً', command=self.show_text,
                  bg='#2e2a24', fg=DIM, relief='flat', cursor='hand2',
                  font=('Segoe UI', 9)).pack(anchor='w')

        root.bind('<Control-v>', lambda _: self.paste())
        root.bind('<Control-V>', lambda _: self.paste())

        self.hot = Hotkeys(
            on_snip=lambda: self.root.after(0, self.snip),
            on_paste=lambda: self.root.after(0, self.paste))
        self.start_hotkeys()
        self.refresh_hint()

        # **الاستيراد قبل فتح الإعدادات.** من نزّل الملف للتوّ لا يُسأل
        # عن معرّفٍ وسرٍّ ينسخهما بيده — نجده ونقرؤه.
        if not self.cfg.get('client_id'):
            path = find_creds()
            if path:
                try:
                    import_creds(self.cfg, path)
                    self.say('استُورد ملف الاعتماد ✓ — اربط حسابك', OK)
                except Exception:
                    pass

        if not self.cfg.get('refresh_token'):
            self.root.after(400, self.settings)

    # ---- الماكرو ----
    def start_hotkeys(self):
        snip = HOTKEYS.get(self.cfg.get('hotkey_snip', 'Insert'), 0x2D)
        paste = HOTKEYS.get(self.cfg.get('hotkey_paste', 'F2'), 0x71)
        self.hot.set_keys(snip, paste)
        self.hot.start()

    def refresh_hint(self):
        self.drop.config(
            text=f'اضغط  {self.cfg.get("hotkey_snip")}  لقصّ الشاشة — '
                 f'ويُقرأ وحده\n\n'
                 f'أو  {self.cfg.get("hotkey_paste")}  للصق ما في الحافظة\n'
                 'أو اسحب الصورة وأفلتها، أو اضغط هنا لاختيار ملف',
            image='')

    def snip(self):
        """يفتح أداة القصّ ثم يراقب الحافظة حتى تظهر الصورة."""
        self.say('افتح تحديد الشاشة… سيُقرأ الوصل وحده بعد القصّ', GOLD)
        threading.Thread(target=press_snip, daemon=True).start()
        self.watch_clipboard(until=time.time() + 60)

    def watch_clipboard(self, until):
        """**المراقبة بدل طلب لصقٍ ثانٍ.** بعد القصّ تصير الصورة في
        الحافظة، فلا معنى لأن نطلب من المستخدم لصقها بيده."""
        if self.watching and time.time() > until:
            self.watching = False
            return
        self.watching = True
        try:
            img = ImageGrab.grabclipboard()
        except Exception:
            img = None
        if isinstance(img, Image.Image):
            sig = hashlib.md5(img.tobytes()).hexdigest()
            if sig != self.last_sig:
                self.last_sig = sig
                self.watching = False
                self.run(img)
                return
        if time.time() < until:
            self.root.after(600, lambda: self.watch_clipboard(until))
        else:
            self.watching = False

    # ---- مصادر الصورة ----
    def paste(self):
        try:
            img = ImageGrab.grabclipboard()
        except Exception as e:
            self.say(f'تعذّرت قراءة الحافظة: {e}', BAD)
            return
        if isinstance(img, list) and img:
            self.load_path(img[0])
        elif isinstance(img, Image.Image):
            self.last_sig = hashlib.md5(img.tobytes()).hexdigest()
            self.run(img)
        else:
            self.say('لا توجد صورة في الحافظة', BAD)

    def pick_file(self):
        p = filedialog.askopenfilename(
            filetypes=[('صور', '*.png *.jpg *.jpeg *.webp *.bmp')])
        if p:
            self.load_path(p)

    def on_drop(self, event):
        self.load_path(event.data.strip().strip('{}'))

    def load_path(self, path):
        try:
            self.run(Image.open(path))
        except Exception as e:
            self.say(f'تعذّر فتح الصورة: {e}', BAD)

    # ---- التشغيل ----
    def run(self, image):
        if not self.cfg.get('refresh_token'):
            self.settings()
            return

        self.root.deiconify()
        self.root.lift()

        thumb = image.copy()
        thumb.thumbnail((380, 150))
        self.preview = ImageTk.PhotoImage(thumb)
        self.drop.config(image=self.preview, text='')

        self.say('يرفع الصورة إلى درايف ويقرأها…', GOLD)
        self.verdict.config(text='', bg=BG)
        threading.Thread(target=self._work, args=(image,), daemon=True).start()

    def _work(self, image):
        # **في خيطٍ منفصل.** الرفع والقراءة يأخذان ثوانيَ، وتجميد النافذة
        # فيها يجعل البرنامج يبدو معلّقاً.
        try:
            token = access_token(self.cfg)
            text = ocr_via_drive(image, token)
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors='replace')[:300]
            self.root.after(0, self.say, f'رفضت جوجل الطلب: {body}', BAD)
            return
        except Exception as e:
            self.root.after(0, self.say, f'تعذّرت القراءة: {e}', BAD)
            return
        self.root.after(0, self.apply, text)

    def apply(self, text):
        self.raw_text = text
        if not text.strip():
            self.say('لم يُقرأ نصّ من الصورة — جرّب صورةً أوضح', BAD)
            return

        d = extract(text)
        self.f_recipient.set(d['recipient'])
        self.f_amount.set(d['amount'])
        self.f_trans.set(d['trans'])

        missing = [n for n, v in (('الرقم', d['recipient']),
                                  ('المبلغ', d['amount']),
                                  ('رقم العملية', d['trans'])) if not v]
        self.say('قُرئت ✓' if not missing
                 else 'تعذّر استخراج: ' + '، '.join(missing) + ' — صحّحه بيدك',
                 OK if not missing else GOLD)
        self.check()

    def check(self):
        """أخضر إن ذهب المبلغ إلى إحدى محافظنا، وأحمر إن ذهب إلى غيرها."""
        wallets = [norm_phone(w) for w in self.cfg.get('wallets', []) if w]
        got = norm_phone(self.f_recipient.get()) if self.f_recipient.get() else ''

        if not wallets:
            self.verdict.config(text='لم تُضف أرقام محافظك بعد — افتح الإعدادات',
                                bg='#3a332a', fg=GOLD)
        elif not got:
            self.verdict.config(text='لا رقم مستلِم', bg='#3a332a', fg=GOLD)
        elif got in wallets:
            self.verdict.config(text=f'✓  أُرسل إلى محفظتك  {got}',
                                bg='#1e3a20', fg='#8ce39a')
        else:
            self.verdict.config(text=f'✗  أُرسل إلى رقمٍ ليس لك:  {got}',
                                bg='#3a1e1e', fg='#ff9b95')

    def say(self, text, color=DIM):
        self.status.config(text=text, fg=color)

    def show_text(self):
        win = tk.Toplevel(self.root)
        win.title('النصّ المقروء')
        win.configure(bg=BG)
        win.geometry('520x520')
        box = tk.Text(win, bg='#26231e', fg=FG, relief='flat',
                      font=('Consolas', 11), wrap='word')
        box.pack(fill='both', expand=True, padx=12, pady=12)
        box.insert('1.0', self.raw_text or '(لا شيء بعد)')

    # ---- الإعدادات ----
    def settings(self):
        win = tk.Toplevel(self.root)
        win.title('الإعدادات')
        win.configure(bg=BG)
        win.geometry('600x640')
        win.transient(self.root)

        def label(t):
            tk.Label(win, text=t, bg=BG, fg=DIM, font=('Segoe UI', 10),
                     justify='right').pack(anchor='e', padx=16, pady=(14, 2))

        # **الملف أولاً، والحقلان تحته للاطّلاع.** نسخُ سلسلتين طويلتين
        # بيدٍ بابُ خطأٍ لا داعي له، وجوجل تعطيك الملف جاهزاً.
        def pick_creds():
            path = filedialog.askopenfilename(
                title='اختر ملف الاعتماد من جوجل',
                initialdir=os.path.join(os.path.expanduser('~'), 'Downloads'),
                filetypes=[('ملف JSON', '*.json')])
            if not path:
                return
            try:
                import_creds(self.cfg, path)
                cid.delete(0, 'end')
                cid.insert(0, self.cfg['client_id'])
                csec.delete(0, 'end')
                csec.insert(0, self.cfg['client_secret'])
                show_state()
                creds_note.config(text=f'استُورد ونُسخ إلى {CREDS}', fg=OK)
            except Exception as e:
                creds_note.config(text=f'{e}', fg=BAD)

        tk.Button(win, text='⬇  استورد ملف Credentials', command=pick_creds,
                  bg=GOLD, fg='#1c1a16', relief='flat', cursor='hand2',
                  font=('Segoe UI', 11, 'bold'), padx=18,
                  pady=6).pack(anchor='e', padx=16, pady=(16, 4))

        creds_note = tk.Label(
            win,
            text='نزّله من: Credentials ← عميل OAuth ← ⬇ Download JSON',
            bg=BG, fg=DIM, font=('Segoe UI', 9), justify='right')
        creds_note.pack(anchor='e', padx=16)

        label('Client ID  (يُملأ من الملف)')
        cid = tk.Entry(win, bg='#26231e', fg=FG, insertbackground=FG,
                       relief='flat', font=('Consolas', 10))
        cid.pack(fill='x', padx=16, ipady=5)
        cid.insert(0, self.cfg.get('client_id', ''))

        label('Client secret (يُملأ من الملف)')
        csec = tk.Entry(win, bg='#26231e', fg=FG, insertbackground=FG,
                        relief='flat', font=('Consolas', 10), show='•')
        csec.pack(fill='x', padx=16, ipady=5)
        csec.insert(0, self.cfg.get('client_secret', ''))

        state = tk.Label(win, text='', bg=BG, fg=DIM,
                         font=('Segoe UI', 10), justify='right')
        state.pack(anchor='e', padx=16, pady=(8, 0))

        btns = tk.Frame(win, bg=BG)
        btns.pack(anchor='e', padx=16, pady=6)

        def show_state():
            linked = bool(self.cfg.get('refresh_token'))
            who = self.cfg.get('account') or ''
            state.config(
                text=(f'مربوط: {who}' if who else 'الحساب مربوط ✓')
                     if linked else 'الحساب غير مربوط',
                fg=OK if linked else GOLD)
            link_btn.config(text='تبديل الحساب' if linked
                            else 'اربط حسابي بجوجل')
            out_btn.pack_forget() if not linked else out_btn.pack(
                side='left', padx=(0, 8))

        def link():
            self.cfg['client_id'] = cid.get().strip()
            self.cfg['client_secret'] = csec.get().strip()
            if not self.cfg['client_id'] or not self.cfg['client_secret']:
                state.config(text='اكتب Client ID و secret أولاً', fg=BAD)
                return
            # تبديل الحساب خروجٌ ثم دخول — وإلا بقي الإذن القديم قائماً.
            if self.cfg.get('refresh_token'):
                unlink_account(self.cfg)
            state.config(text='افتح المتصفّح واختر حسابك…', fg=GOLD)
            win.update()
            try:
                rt, who = link_account(self.cfg['client_id'],
                                       self.cfg['client_secret'])
                self.cfg['refresh_token'] = rt
                self.cfg['account'] = who
                save_config(self.cfg)
                show_state()
                self.say('رُبط الحساب ✓', OK)
            except Exception as e:
                state.config(text=f'فشل الربط: {e}', fg=BAD)

        def logout():
            unlink_account(self.cfg)
            show_state()
            self.say('سُجّل الخروج — لن يُرفع شيء حتى تربط حساباً', GOLD)

        link_btn = tk.Button(btns, text='اربط حسابي بجوجل', command=link,
                             bg='#2e2a24', fg=FG, relief='flat',
                             cursor='hand2', font=('Segoe UI', 10),
                             padx=14, pady=4)
        link_btn.pack(side='left')

        out_btn = tk.Button(btns, text='تسجيل الخروج', command=logout,
                            bg='#3a1e1e', fg='#ff9b95', relief='flat',
                            cursor='hand2', font=('Segoe UI', 10),
                            padx=14, pady=4)

        show_state()

        # ---- الماكرو ----
        label('مفاتيح الماكرو')
        keys = tk.Frame(win, bg=BG)
        keys.pack(fill='x', padx=16)

        snip_var = tk.StringVar(value=self.cfg.get('hotkey_snip', 'Insert'))
        paste_var = tk.StringVar(value=self.cfg.get('hotkey_paste', 'F2'))

        tk.Label(keys, text='قصّ الشاشة', bg=BG, fg=DIM,
                 font=('Segoe UI', 10)).grid(row=0, column=1, sticky='e')
        tk.OptionMenu(keys, snip_var, *HOTKEYS).grid(row=0, column=0,
                                                     sticky='w', padx=8)
        tk.Label(keys, text='لصق من الحافظة', bg=BG, fg=DIM,
                 font=('Segoe UI', 10)).grid(row=1, column=1, sticky='e')
        tk.OptionMenu(keys, paste_var, *HOTKEYS).grid(row=1, column=0,
                                                      sticky='w', padx=8)
        tk.Label(win,
                 text='تعمل المفاتيح والبرنامج خلف نافذةٍ أخرى. '
                      'تغييرها يحتاج إعادة تشغيل البرنامج.',
                 bg=BG, fg=DIM, font=('Segoe UI', 9),
                 justify='right').pack(anchor='e', padx=16, pady=(6, 0))

        label('أرقام محافظ زين كاش (رقمٌ في كل سطر)')
        box = tk.Text(win, bg='#26231e', fg=FG, insertbackground=FG,
                      relief='flat', height=6, font=('Consolas', 12))
        box.pack(fill='both', expand=True, padx=16, pady=(2, 10))
        box.insert('1.0', '\n'.join(self.cfg.get('wallets', [])))

        def save():
            self.cfg['client_id'] = cid.get().strip()
            self.cfg['client_secret'] = csec.get().strip()
            self.cfg['hotkey_snip'] = snip_var.get()
            self.cfg['hotkey_paste'] = paste_var.get()
            self.cfg['wallets'] = [
                norm_phone(l) for l in box.get('1.0', 'end').splitlines()
                if l.strip()]
            save_config(self.cfg)
            win.destroy()
            self.refresh_hint()
            self.check()
            self.say('حُفظت الإعدادات ✓', OK)

        tk.Button(win, text='حفظ', command=save, bg=GOLD, fg='#1c1a16',
                  relief='flat', font=('Segoe UI', 11, 'bold'), cursor='hand2',
                  padx=24, pady=6).pack(pady=(0, 14))


def main():
    root = TkinterDnD.Tk() if HAS_DND else tk.Tk()
    App(root)
    root.mainloop()


if __name__ == '__main__':
    main()
