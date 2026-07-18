import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase plugins are declared (apply false) in settings.gradle.kts but
    // applied CONDITIONALLY below — the plugins {} DSL block can't be conditional,
    // so we apply(plugin = …) only when android/app/google-services.json exists.
}

// Firebase — applied ONLY when android/app/google-services.json is present. This
// keeps the build green until the Firebase project is provisioned: without the
// file the google-services plugin fails ("File google-services.json is missing"),
// so dev/CI builds must not apply it. Dropping the file in enables Firebase
// natively (pair it with FIREBASE_ENABLED=true in env/*.json for the Dart side).
// Order matters: google-services MUST come before crashlytics/perf. crashlytics
// auto-uploads the R8 mapping (isMinifyEnabled = true below) for deobfuscated
// release stack traces.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
    apply(plugin = "com.google.firebase.firebase-perf")
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

        // Meta SDK app id + client token → AndroidManifest meta-data. Empty when
        // unset/placeholder (see realDefine), which leaves the SDK inert; the
        // Dart side is gated in parallel by AppConfig.metaEnabled. A build with
        // no META defines therefore still works (placeholders resolve to "").
        val defines = dartDefines()
        manifestPlaceholders["facebookAppId"] = realDefine(defines, "META_APP_ID")
        manifestPlaceholders["facebookClientToken"] =
            realDefine(defines, "META_CLIENT_TOKEN")
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

// ── Meta (Facebook) SDK config from dart-defines ──────────────────────────────
// Flutter forwards `--dart-define[-from-file]` values to Gradle as the
// `dart-defines` project property: a comma-separated list of base64-encoded
// `KEY=VALUE` pairs. Decode it so META_APP_ID / META_CLIENT_TOKEN can be baked
// into the AndroidManifest meta-data via manifestPlaceholders (see the
// com.facebook.sdk.* entries in AndroidManifest.xml). Keeping the values here —
// not committed in strings.xml — means no Meta config lives in the repo and the
// same source of truth (env/*.json) drives both the Dart and native sides.
fun dartDefines(): Map<String, String> {
    val raw = (project.findProperty("dart-defines") as String?) ?: return emptyMap()
    return raw.split(",")
        .mapNotNull { entry ->
            if (entry.isBlank()) return@mapNotNull null
            val decoded = String(Base64.getDecoder().decode(entry.trim()))
            val idx = decoded.indexOf('=')
            if (idx < 0) null else decoded.substring(0, idx) to decoded.substring(idx + 1)
        }
        .toMap()
}

// Treat env-file placeholders (`YOUR_…`, `placeholder-…`) as "unset" so a
// half-configured build produces an inert SDK rather than a bogus app id.
fun realDefine(defines: Map<String, String>, key: String): String {
    val v = defines[key] ?: return ""
    return if (v.startsWith("YOUR_") || v.startsWith("placeholder")) "" else v
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
