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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            //
            // ⚠️ THIS MAKES RELEASES MACHINE-BOUND. The debug keystore
            // (~/.android/debug.keystore) is generated per machine, so the APK's
            // signature identifies the BUILD HOST. Every published release has
            // been built on the MacBook — cert SHA-256 35546f7c…afebe8, confirmed
            // 2026-08-28 against app-v1.16.2. Build a release anywhere else and
            // Android refuses to install it over the installed app (signature
            // mismatch), forcing an uninstall and losing app data.
            //
            // So: BUILD APP RELEASES ON THE MACBOOK until this is replaced with a
            // real keystore. (Device .apk packages are the opposite — those must
            // be built on the desktop. See HANDOFF.md "WHICH MACHINE BUILDS WHAT".)
            //
            // The proper fix: a real keystore, kept in 1Password and referenced
            // from android/key.properties. The app SELF-UPDATES, and a debug key
            // has the publicly known password "android" — so today the signature
            // authenticates nobody.
            signingConfig = signingConfigs.getByName("debug")
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
