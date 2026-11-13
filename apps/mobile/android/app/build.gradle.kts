plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStorePath = providers.environmentVariable("BRB_SIGNING_KEYSTORE_FILE").orNull
val releasePassword = providers.environmentVariable("BRB_SIGNING_PASSWORD").orNull

android {
    namespace = "dev.mactimit.brb_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.mactimit.brb_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStorePath != null && releasePassword != null) {
            create("brbStable") {
                storeFile = file(releaseStorePath)
                storePassword = releasePassword
                storeType = "PKCS12"
                keyAlias = "brb-tracker"
                keyPassword = releasePassword
            }
        }
    }
    buildTypes {
        debug {
            // Preview builds remain debuggable so owners can use adb run-as
            // to move local reports across the one-time signing migration.
            signingConfigs.findByName("brbStable")?.let { signingConfig = it }
        }
        release {
            // Without signing secrets, a release build is unsigned and cannot
            // silently fall back to the per-run Android debug certificate.
            signingConfig = signingConfigs.findByName("brbStable")
        }
    }
    packaging {
        jniLibs.useLegacyPackaging = true
        jniLibs.pickFirsts += "**/libc++_shared.so"
        resources.excludes += setOf("META-INF/DEPENDENCIES", "META-INF/LICENSE*", "META-INF/NOTICE*")
    }
}

dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    implementation("cz.adaptech.tesseract4android:tesseract4android:4.9.0")
    implementation("com.alphacephei:vosk-android:0.3.75")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
