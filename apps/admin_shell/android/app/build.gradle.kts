plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

// **المفتاح خارج المستودع.** `key.properties` مُستثنى في .gitignore،
// ومن يقرؤه يوقّع تحديثاً باسمك.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "iq.zanbour.zanbour_admin_shell"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "iq.zanbour.admin"
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
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            // **نفس مفتاح التطبيقين.** مفتاحُ التصحيح يختلف بين
            // الأجهزة، فحزمةٌ موقّعةٌ به لا تُحدَّث فوق سابقتها ولا
            // تُرفع إلى Play أبداً.
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

flutter {
    source = "../.."
}

// **مكوّن Firebase حين يوجد ملفّه فقط.** بلا `google-services.json` يفشل
// البناء كله — والتطبيق يعمل بلا إشعارات إن لم يُسجَّل في Firebase بعد.
// فيُبنى في الحالين، والإشعارات تبدأ يوم يوضع الملف.
//
// **في آخر الملف لا بعد `plugins`:** سطور `import` يجب أن تسبق كل شيء
// في ملفّ kts، وكتلةٌ قبلها تُسقط البناء بـ «Expecting an element».
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}
