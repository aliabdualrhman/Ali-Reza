# =============================================================================
# فحص بيئة التطوير — شغّله في أي وقت لتعرف ما الذي أُنجز وما تبقّى
# =============================================================================
#   powershell -ExecutionPolicy Bypass -File scripts\check-env.ps1
# =============================================================================

$ErrorActionPreference = 'SilentlyContinue'
$ok = 0; $missing = 0

function Test-Tool {
    param([string]$Name, [string]$Command, [string]$Hint)
    $found = Get-Command $Command -ErrorAction SilentlyContinue
    if ($found) {
        Write-Host ("  [OK]   {0,-18}" -f $Name) -ForegroundColor Green -NoNewline
        Write-Host $found.Source -ForegroundColor DarkGray
        $script:ok++
    } else {
        Write-Host ("  [--]   {0,-18}" -f $Name) -ForegroundColor Yellow -NoNewline
        Write-Host $Hint -ForegroundColor DarkGray
        $script:missing++
    }
}

function Test-EnvVar {
    param([string]$Name, [string]$Hint)
    $val = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($val) {
        Write-Host ("  [OK]   {0,-18}" -f $Name) -ForegroundColor Green -NoNewline
        Write-Host $val -ForegroundColor DarkGray
        $script:ok++
    } else {
        Write-Host ("  [--]   {0,-18}" -f $Name) -ForegroundColor Yellow -NoNewline
        Write-Host $Hint -ForegroundColor DarkGray
        $script:missing++
    }
}

Write-Host ""
Write-Host "===== فحص بيئة تطوير V4 =====" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------------------------
Write-Host "الأدوات:" -ForegroundColor White
Test-Tool "git"     "git"     "مثبّت مسبقاً"
Test-Tool "flutter" "flutter" "القسم 1.1 من SETUP.md"
Test-Tool "dart"    "dart"    "يأتي مع Flutter"
Test-Tool "node"    "node"    "القسم 1.5 من SETUP.md"
Test-Tool "adb"     "adb"     "يأتي مع Android SDK Platform-Tools"

Write-Host ""
Write-Host "متغيرات البيئة (توجيه التخزين بعيداً عن C:):" -ForegroundColor White
Test-EnvVar "ANDROID_HOME"      "القسم 0 من SETUP.md"
Test-EnvVar "GRADLE_USER_HOME"  "القسم 0 — بدونه يمتلئ C: بمخبأ Gradle"
Test-EnvVar "PUB_CACHE"         "القسم 0 — مخبأ حزم Dart"
Test-EnvVar "ANDROID_USER_HOME" "القسم 0 — مجلد .android"

# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "المساحة الحرة:" -ForegroundColor White
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $free = $_.FreeSpace / 1GB
    $color = if ($free -lt 20) { 'Red' } elseif ($free -lt 50) { 'Yellow' } else { 'Green' }
    Write-Host ("  {0} {1,7:N1} GB حرة" -f $_.DeviceID, $free) -ForegroundColor $color
}

# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "الأجهزة المتصلة:" -ForegroundColor White
if (Get-Command flutter -ErrorAction SilentlyContinue) {
    flutter devices 2>&1 | Select-Object -Skip 1 | ForEach-Object {
        if ($_ -match '\S') { Write-Host "  $_" -ForegroundColor DarkGray }
    }
} else {
    Write-Host "  (يحتاج Flutter)" -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "ملفات الإعداد:" -ForegroundColor White
foreach ($f in @('apps\rider\.env', 'apps\driver\.env')) {
    $p = Join-Path (Split-Path $PSScriptRoot -Parent) $f
    if (Test-Path $p) {
        Write-Host ("  [OK]   {0}" -f $f) -ForegroundColor Green
        $script:ok++
    } else {
        Write-Host ("  [--]   {0,-18} " -f $f) -ForegroundColor Yellow -NoNewline
        Write-Host "لم يُنشأ بعد" -ForegroundColor DarkGray
        $script:missing++
    }
}

Write-Host ""
Write-Host ("النتيجة: {0} جاهز، {1} ناقص" -f $ok, $missing) -ForegroundColor Cyan
Write-Host ""
