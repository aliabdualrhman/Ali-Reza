plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")

    // يقرأ google-services.json من هذا المجلد — وهو يعرف المعرّفين
    // الأصلي و`.test` معاً، فيُطبَّق بلا شرط.
    id("com.google.gms.google-services")
}

import java.util.Properties
import java.io.FileInputStream

// **مفاتيح التوقيع من ملف خارج المستودع.** كتابتها في هذا الملف تعني
// رفعها إلى git يوماً، ومن يقرأها يستطيع توقيع تحديث باسمك.
//
// وغيابُ الملف لا يُسقط البناء: من ينسخ المشروع للتطوير يبني بمفاتيح
// التصحيح ولا يحتاج مفتاح النشر أصلاً.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "iq.zanbour.driver"
    // 37 صراحةً لا flutter.compileSdkVersion (الذي يعطي 36).
    // بعض الحزم التي نستعملها بُنيت على منصة 37، وGradle يرفض بناء
    // تطبيق يعتمد مكتبة مترجمة على منصة أحدث من منصته.
    //
    // compileSdk يحدد الواجهات المتاحة وقت الترجمة فقط — لا علاقة له
    // بأي أجهزة تستطيع تشغيل التطبيق (ذلك minSdk).
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        // flutter_local_notifications يستعمل واجهات Java 8 الحديثة
        // (java.time خصوصاً) التي لا تدعمها أندرويد القديمة.
        //
        // desugaring يترجمها وقت البناء إلى ما تفهمه أندرويد ٥ فما فوق.
        // بدونه يفشل البناء — أو أسوأ: ينجح وينهار التطبيق على الأجهزة
        // القديمة، وهي منتشرة في سوقنا.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "iq.zanbour.driver"

        // **نسخة اختبار تتعايش مع نسخة المتجر.**
        //
        // بلا معرّفٍ مختلف يرفض أندرويد تثبيت الاثنين معاً — والنسخة
        // المثبَّتة من Play موقّعة بمفتاح جوجل، فحذفُها لتجريب بناءٍ
        // محلي يُخرج الجهاز من عدّ المختبِرين. ونحن على بُعد مختبِرٍ
        // واحد من بدء العدّاد.
        //
        //     flutter build apk --release -Ptest=true
        //
        // **خاصيةٌ اختيارية لا نكهة (flavor).** النكهة تُجبر كل أمر بناء
        // على ذكرها، فينكسر ما نبني به للمتجر اليوم. وهذه لا تُغيّر شيئاً
        // ما لم تُمرَّر.
        // **بديلٌ عن `resValue`** — AGP 9 يعطّلها افتراضياً ويردّ
        // «defaultConfig contains custom resource values, but the
        // feature is disabled». والحشوة تُستبدل في البيان وقت الدمج بلا
        // خاصيةٍ تُفعَّل.
        if (project.hasProperty("test")) {
            applicationIdSuffix = ".test"
            manifestPlaceholders["appLabel"] = "كابتن زنبور test"
        } else {
            manifestPlaceholders["appLabel"] = "كابتن زنبور"
        }

        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // مفاتيح النشر إن وُجدت، وإلا مفاتيح التصحيح للتطوير المحلي
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // المكتبة التي يحقنها desugaring في التطبيق
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
