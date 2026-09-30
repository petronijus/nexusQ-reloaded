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

    // The app's signing key: the one every installed app trusts, cert SHA-256
    // 35:54:6F:7C…:AF:EB:E8. It is 1Password's "nexusQ companion Android signing
    // key" (a Document, with its alias and passwords as fields); build-apk.sh
    // fetches it to a private temp file and passes it here, on any machine. It
    // is the debug keystore the MacBook and the desktop carry by hand (HANDOFF,
    // 2026-08-28); from the vault a machine without that copy (the macOS VM, a
    // new one) signs the same, and a release never depends on which host it is.
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
