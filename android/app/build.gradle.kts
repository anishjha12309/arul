import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Phase 2/4 (with the port, once android/app/google-services.json exists):
    //   id("com.google.gms.google-services")
    //   id("com.google.firebase.crashlytics")
}

// Release signing. key.properties is git-ignored; when absent the build silently
// falls back to DEBUG keys — the release-build skill verifies CN=HSR Apps for
// exactly this reason.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.containsKey("storeFile")

android {
    namespace = "com.hsrapps.arul"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.hsrapps.arul"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion   // 36 -> edge-to-edge is ENFORCED
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Launcher + themed icons are vectors; render at build time for old APIs
        // instead of shipping extra PNG densities.
        vectorDrawables.useSupportLibrary = true
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
            // R8 only shrinks the Java/Kotlin layer — the APK is dominated by
            // libflutter/libapp — but it earns its keep once Firebase, Play
            // Services and PhonePe land. shrinkResources requires minify.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Media3 ExoPlayer — the app's single video runtime, used by BOTH:
    //   • feedvideo/FeedVideoPlugin  — the in-feed live-preview texture pool
    //   • wallpaper/VideoRenderer    — the applied live wallpaper's own service
    // Keep the media3 modules in version lockstep.
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-common:1.10.1")

    // Share-time watermarking (share/ShareWatermarkChannel): Transformer re-encodes
    // the live clip with a full-frame PNG BitmapOverlay burned in. Same version
    // lockstep rule as above — ALL media3 artifacts must match.
    implementation("androidx.media3:media3-transformer:1.10.1")
    implementation("androidx.media3:media3-effect:1.10.1")

    // Coroutines — off-main-thread file persistence in the apply channel.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}

flutter {
    source = "../.."
}
