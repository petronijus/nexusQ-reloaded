plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.nexusq.nexusq_companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications (release alerts) uses java.time, which
        // needs library desugaring below Android 8.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.nexusq.nexusq_companion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Where the APK is distributed, `--flavor` on every build (build-apk.sh):
    //  github  the APK on GitHub releases and on Petr's phone; updates itself
    //          (lib/update/app_update.dart), so only it may install packages
    //          (src/github/AndroidManifest.xml);
    //  play    Google Play, which updates it; an app from Play may not
    //          update itself by any other means;
    //  fdroid  F-Droid, built by F-Droid from this source; same rule.
    // One application id for all three: a store and GitHub are channels of
    // the same app, not three apps.
    flavorDimensions += "distribution"
    productFlavors {
        create("github") { dimension = "distribution" }
        create("play") { dimension = "distribution" }
        create("fdroid") { dimension = "distribution" }
    }

    // The app's release key (since 2026-09-30), cert SHA-256 5B:EC:C7:0A…:5A:1D:
    // 1Password's "nexusQ companion Android release key" (a Document with its
    // alias and passwords as fields). build-apk.sh fetches it to a private temp
    // file and passes it here, on any machine; it is also the Google Play upload
    // key. The github APK is re-signed afterwards with the old key (the debug
    // keystore every install before 1.27 carries, 35:54:6F:7C…) and the rotation
    // record android/signing/rotation.lineage, so installed apps move to this key
    // (build-apk.sh, "Signing").
    val nqKeystore = System.getenv("NQ_ANDROID_KEYSTORE")
    if (nqKeystore != null) {
        signingConfigs {
            create("nexusq") {
                storeFile = file(nqKeystore)
                storePassword = System.getenv("NQ_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("NQ_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("NQ_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        // With the key, debug builds are signed with it too, so `flutter run`
        // and build-apk.sh's debug build install over the phone's app.
        if (nqKeystore != null) {
            getByName("debug") {
                signingConfig = signingConfigs.getByName("nexusq")
            }
        }
        release {
            // With the key (build-apk.sh) a release is signed with it. Without it
            // this machine's debug key signs, which yields an APK no phone with
            // the app will take as an update: fine for a compile check (`just
            // ci` builds debug anyway), never for a phone -- build-apk.sh
            // --release refuses to run without the key.
            signingConfig =
                if (nqKeystore != null) {
                    signingConfigs.getByName("nexusq")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
