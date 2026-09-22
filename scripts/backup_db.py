"""نسخة احتياطية من قاعدة بيانات زنبور.

يُشغَّل هكذا (من جذر المستودع):

    $env:SUPABASE_URL = "https://xxxx.supabase.co"
    $env:SUPABASE_SERVICE_KEY = "sb_secret_..."
    python scripts/backup_db.py

يكتب مجلداً باسم اليوم والساعة في `backups/`، فيه ملف JSON لكل جدول.

**لماذا سكربت لا زر في Supabase؟** لأن النسخ التلقائية ميزة في الخطط
المدفوعة وحدها. وحتى معها، نسخةٌ على خوادم المزوّد نفسه لا تحميك من
حذفٍ بالخطأ ولا من إقفال حساب — النسخة التي تنفع هي التي تملكها أنت.

**والمفتاح من متغيّر بيئة لا من ملف في المستودع.** `service_role` يتجاوز
كل سياسات الأمان، ووضعُه في ملفٍ يُرفع يوماً إلى GitHub يعني تسليم
القاعدة كاملةً لمن يقرأه.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# **الترتيب مقصود:** الجداول المرجعية أولاً ثم ما يعتمد عليها. لا يهمّ
# للنسخ نفسه، لكنه يهمّ كثيراً لمن يقرأ الملفات ليستعيد يدوياً.
TABLES = [
    'public_settings',
    'pricing_zones',
    'profiles',
    'drivers',
    'user_documents',
    'trips',
    'trip_stops',
    'trip_offers',
    'trip_change_requests',
    'ratings',
    'wallet_transactions',
    'topup_codes',
    'payout_requests',
    'coupons',
    'coupon_redemptions',
    'audit_log',
]

PAGE = 1000  # PostgREST يحدّ الصفحة الواحدة؛ نطلبها صريحةً ونصفّح


def fetch_page(base, key, table, offset):
    url = f'{base}/rest/v1/{table}?select=*&order=1&limit={PAGE}&offset={offset}'
    req = urllib.request.Request(url, headers={
        'apikey': key,
        'Authorization': f'Bearer {key}',
        'Accept': 'application/json',
    })
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode('utf-8'))


def dump_table(base, key, table, out_dir):
    rows, offset = [], 0
    while True:
        try:
            page = fetch_page(base, key, table, offset)
        except urllib.error.HTTPError as e:
            body = e.read().decode('utf-8', 'replace')[:200]
            print(f'  ✗ {table}: {e.code} {body}')
            return None
        rows.extend(page)
        if len(page) < PAGE:
            break
        offset += PAGE

    path = os.path.join(out_dir, f'{table}.json')
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)
    return len(rows)


def main():
    base = (os.environ.get('SUPABASE_URL') or '').rstrip('/')
    key = os.environ.get('SUPABASE_SERVICE_KEY') or ''

    if not base or not key:
        print('اضبط المتغيّرين أولاً:')
        print('  $env:SUPABASE_URL = "https://xxxx.supabase.co"')
        print('  $env:SUPABASE_SERVICE_KEY = "sb_secret_..."')
        print()
        print('المفتاح من: Supabase ← Project Settings ← API ← service_role')
        return 1

    stamp = datetime.now(timezone.utc).strftime('%Y-%m-%d_%H%M')
    out_dir = os.path.join('backups', stamp)
    os.makedirs(out_dir, exist_ok=True)

    print(f'النسخة إلى: {out_dir}\n')
    total, failed = 0, []

    for table in TABLES:
        n = dump_table(base, key, table, out_dir)
        if n is None:
            failed.append(table)
        else:
            total += n
            print(f'  ✓ {table}: {n} صف')

    manifest = {
        'taken_at': datetime.now(timezone.utc).isoformat(),
        'project': base,
        'tables': TABLES,
        'total_rows': total,
        'failed': failed,
    }
    with open(os.path.join(out_dir, '_manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)

    print(f'\nالمجموع: {total} صف')
    if failed:
        # **الفشل الجزئي يُعلَن لا يُبتلع.** نسخةٌ ناقصة يظنّها صاحبها
        # كاملة أسوأ من غياب النسخة: لا يكتشف النقص إلا يوم يحتاجها.
        print(f'تعذّرت جداول: {", ".join(failed)}')
        return 2

    print('اكتملت النسخة بلا أخطاء.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
