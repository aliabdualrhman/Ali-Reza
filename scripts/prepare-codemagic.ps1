# =============================================================================
# إعداد متغيرات Codemagic (base64) لرفع TestFlight
# =============================================================================
# التشغيل من جذر المستودع:
#   powershell -ExecutionPolicy Bypass -File scripts\prepare-codemagic.ps1
#
# يقرأ الملفات المحلية المستثناة من git، يرمّزها base64، ويكتب نصوصاً
# جاهزة للصق في لوحة Codemagic ← Environment variables ← مجموعة zanbour.
#
# المخرجات في .codemagic-secrets/ (مستثناة من git) — لا ترفعها ولا ترسلها.
# =============================================================================

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out  = Join-Path $root '.codemagic-secrets'
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Encode-File([string]$path, [string]$varName) {
    if (-not (Test-Path $path)) {
        Write-Host "  [X] $varName — الملف غير موجود: $path" -ForegroundColor Red
        return $false
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $b64 = [Convert]::ToBase64String($bytes)
    $dest = Join-Path $out "$varName.txt"
    [System.IO.File]::WriteAllText($dest, $b64, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  [OK] $varName  ($([math]::Round($bytes.Length/1KB,1)) KB) → $dest" -ForegroundColor Green
    return $true
}

Write-Host ""
Write-Host "  إعداد أسرار Codemagic — زنبور" -ForegroundColor Cyan
Write-Host "  ================================" -ForegroundColor Cyan
Write-Host ""

$ok = $true
$ok = (Encode-File (Join-Path $root 'apps\rider\.env') 'RIDER_ENV_B64') -and $ok
$ok = (Encode-File (Join-Path $root 'apps\driver\.env') 'DRIVER_ENV_B64') -and $ok
$ok = (Encode-File (Join-Path $root 'apps\rider\ios\Runner\GoogleService-Info.plist') 'RIDER_GSI_B64') -and $ok
$ok = (Encode-File (Join-Path $root 'apps\driver\ios\Runner\GoogleService-Info.plist') 'DRIVER_GSI_B64') -and $ok

# GEOAPIFY من .env الراكب إن وُجد
$geoPath = Join-Path $out 'GEOAPIFY_KEY.txt'
$riderEnv = Join-Path $root 'apps\rider\.env'
if (Test-Path $riderEnv) {
    $line = Get-Content $riderEnv -Encoding UTF8 |
        Where-Object { $_ -match '^\s*GEOAPIFY_KEY\s*=' } |
        Select-Object -First 1
    if ($line) {
        $val = ($line -split '=', 2)[1].Trim().Trim('"').Trim("'")
        if ($val) {
            [System.IO.File]::WriteAllText($geoPath, $val, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  [OK] GEOAPIFY_KEY → $geoPath" -ForegroundColor Green
        } else {
            Write-Host "  [X] GEOAPIFY_KEY فارغ في apps/rider/.env" -ForegroundColor Red
            $ok = $false
        }
    } else {
        Write-Host "  [X] GEOAPIFY_KEY غير موجود في apps/rider/.env" -ForegroundColor Red
        $ok = $false
    }
}

Write-Host ""
if (-not $ok) {
    Write-Host "  ناقص ملفات — أكملها ثم أعد تشغيل السكربت:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1) apps/rider/.env و apps/driver/.env" -ForegroundColor Gray
    Write-Host "     (انسخ من .env.example واملأ القيم)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2) GoogleService-Info.plist من Firebase Console:" -ForegroundColor Gray
    Write-Host "     https://console.firebase.google.com" -ForegroundColor Gray
    Write-Host "     ← مشروع زنبور ← Project settings ← Your apps" -ForegroundColor Gray
    Write-Host "     ← أضف تطبيق iOS إن لم يكن موجوداً:" -ForegroundColor Gray
    Write-Host "        Bundle ID الراكب:  iq.zanbour.rider" -ForegroundColor White
    Write-Host "        Bundle ID السائق:  iq.zanbour.driver" -ForegroundColor White
    Write-Host "     ← نزّل GoogleService-Info.plist وضع كل ملف في:" -ForegroundColor Gray
    Write-Host "        apps/rider/ios/Runner/" -ForegroundColor White
    Write-Host "        apps/driver/ios/Runner/" -ForegroundColor White
    Write-Host ""
    exit 1
}

$checklist = @"
# الصق في Codemagic — مجموعة متغيرات باسم zanbour (كلها Secure)

| المتغير        | الملف المحلي للصق منه                          |
|----------------|------------------------------------------------|
| RIDER_ENV_B64  | .codemagic-secrets/RIDER_ENV_B64.txt           |
| DRIVER_ENV_B64 | .codemagic-secrets/DRIVER_ENV_B64.txt          |
| RIDER_GSI_B64  | .codemagic-secrets/RIDER_GSI_B64.txt           |
| DRIVER_GSI_B64 | .codemagic-secrets/DRIVER_GSI_B64.txt          |
| GEOAPIFY_KEY   | .codemagic-secrets/GEOAPIFY_KEY.txt            |

Integration App Store Connect يجب أن تُسمّى بالضبط: zanbour_asc

Workflow للتجربة الأولى: «iOS — زنبور (الراكب)»

التفاصيل الكاملة: docs/CODEMAGIC.md
"@
[System.IO.File]::WriteAllText((Join-Path $out 'CHECKLIST.txt'), $checklist, [System.Text.UTF8Encoding]::new($false))

Write-Host "  جاهز. افتح المجلد والصق القيم في Codemagic:" -ForegroundColor Cyan
Write-Host "  $out" -ForegroundColor White
Write-Host ""
Write-Host "  الدليل: docs/CODEMAGIC.md" -ForegroundColor Gray
Write-Host ""
