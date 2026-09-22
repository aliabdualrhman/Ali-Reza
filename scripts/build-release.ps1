# =============================================================================
# بناء نسخ الإصدار — ولا يمرّ بلا مفتاح
# =============================================================================
#   powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1 -Apk
#
# **لماذا سكربت بدل أمرٍ نكتبه في كل مرة؟**
#
# `GEOAPIFY_KEY` يُحقن وقت البناء. وحين يُنسى لا يفشل البناء ولا يحذّر —
# تخرج حزمة سليمة الشكل، تُوقَّع وتُرفع وتُراجَع، ثم تُكتشف على جوال
# مختبِر: خريطة بلا بحث ولا مسار ولا حساب أجرة.
#
# وقع هذا فعلاً: رُفعت نسختان إلى Play بلا مفتاح.
#
# فالسكربت يفحص أولاً ويرفض البناء، ثم يتحقّق من وجود المفتاح **داخل
# الحزمة** بعد البناء — لأن الأمر الصحيح قد يُكتب ومع ذلك لا يصل شيء.
# =============================================================================

# -Test : يبني بمعرّفٍ منتهٍ بـ`.test` واسمٍ «زنبور test».
#
# **بلا هذا الخيار تدوس نسخةُ الاختبار نسخةَ المتجر.** المعرّفان واحد،
# فأندرويد يراهما تطبيقاً واحداً — والمنصَّبة من Play موقّعةٌ بمفتاح
# جوجل، فحذفُها لتجريب بناءٍ محلي يُخرج الجهاز من عدّ المختبِرين.
param([switch]$Apk, [switch]$Test)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# ---- ١) الحارس: لا بناء بلا مفتاح ------------------------------------------
$key = $env:GEOAPIFY_KEY
if (-not $key) { $key = [Environment]::GetEnvironmentVariable('GEOAPIFY_KEY','User') }

if (-not $key) {
    Write-Host ""
    Write-Host "  [X] GEOAPIFY_KEY غير مضبوط - البناء متوقّف" -ForegroundColor Red
    Write-Host ""
    Write-Host "      احفظه مرة واحدة:" -ForegroundColor Gray
    Write-Host '      setx GEOAPIFY_KEY "مفتاحك"' -ForegroundColor Gray
    Write-Host "      ثم افتح نافذة PowerShell جديدة." -ForegroundColor Gray
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "  [OK] GEOAPIFY_KEY موجود ($($key.Length) حرفاً)" -ForegroundColor Green

$target = if ($Apk) { 'apk' } else { 'appbundle' }
$out    = if ($Apk) { 'flutter-apk\app-release.apk' }
                else { 'bundle\release\app-release.aab' }

New-Item -ItemType Directory -Force (Join-Path $root 'release') | Out-Null

foreach ($app in @('rider','driver')) {
    $dir = Join-Path $root "apps\$app"
    Write-Host ""
    Write-Host "  === $app ===" -ForegroundColor Cyan

    Push-Location $dir
    try {
        # **لا نستعمل splat هنا.** PowerShell 5.1 يشوّه `@arr` حين
        # يُمرَّر إلى ملفٍّ تنفيذيّ خارجي فيصل `-` وحده، فيشكو فلاتر من
        # «Target file "-" not found» — وهي رسالةٌ لا تدلّ على سببها.
        if ($Test) {
            & flutter build $target --release `
                "--dart-define=GEOAPIFY_KEY=$key" "-Ptest=true"
        } else {
            & flutter build $target --release `
                "--dart-define=GEOAPIFY_KEY=$key"
        }
        if ($LASTEXITCODE -ne 0) { throw "فشل بناء $app" }

        # ---- ٢) التحقّق: هل وصل المفتاح فعلاً؟ ---------------------------
        # **لا نثق بالأمر بل بالناتج.** خطأ مطبعي في اسم المتغيّر يمرّ
        # صامتاً، ويُنتج نفس الحزمة المكسورة بالضبط.
        $built = Join-Path $dir "build\app\outputs\$out"
        # **نفكّ الضغط قبل الفحص.** الحزمة أرشيف مضغوط، والمسح الخام
        # عليها يفشل دائماً — فيتحوّل التحقّق إلى تحذير يُتجاهَل، وهو
        # أسوأ من غيابه: يُطمئن بلا أن يفحص.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip   = [IO.Compression.ZipFile]::OpenRead($built)
        $bytes = [Text.Encoding]::ASCII.GetBytes($key)
        $hit   = $false

        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.Length -gt 200MB) { continue }
                $sr  = New-Object IO.StreamReader($entry.Open())
                $txt = $sr.ReadToEnd()
                $sr.Close()
                if ($txt.Contains($key)) { $hit = $true; break }
            }
        } finally { $zip.Dispose() }

        if ($hit) {
            Write-Host "  [OK] المفتاح مضمَّن في الحزمة" -ForegroundColor Green
        } else {
            Write-Host "  [X] المفتاح غير موجود داخل الحزمة - لا ترفعها" -ForegroundColor Red
            throw "فشل التحقّق من المفتاح في $app"
        }

        $ver = (Select-String -Path (Join-Path $dir 'pubspec.yaml') `
                              -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
        $tag  = if ($Test) { '-test' } else { '' }
        $name = "zanbour-$app-$($ver -replace '\+','-')$tag.$target" -replace 'appbundle','aab'
        Copy-Item $built (Join-Path $root "release\$name") -Force
        Write-Host "  -> release\$name" -ForegroundColor Gray
    }
    finally { Pop-Location }
}

Write-Host ""
Write-Host "  تمّ." -ForegroundColor Green
Write-Host ""
