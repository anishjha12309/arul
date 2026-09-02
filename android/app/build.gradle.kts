import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter plugin reads the Android and Kotlin extensions -> it must be applied after both.
    id("dev.flutter.flutter-gradle-plugin")
    // The plugins {} DSL cannot be conditional -> Firebase is applied with apply(plugin = …) below instead.
}

// google-services.json is git-ignored -> the plugin fails outright when it is missing -> apply Firebase only if it exists.
// Dropping the file in enables Firebase natively -> pair it with FIREBASE_ENABLED=true in env/*.json for the Dart side.
// google-services MUST be applied before crashlytics and perf -> the order of these three lines is load-bearing.
// crashlytics auto-uploads the R8 mapping -> release stack traces come back deobfuscated -> keep minify on below.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
    apply(plugin = "com.google.firebase.firebase-perf")
}

// key.properties is git-ignored -> when absent the build silently signs with DEBUG keys.
// The release-build skill checks CN=HSR Apps for exactly that reason.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.containsKey("storeFile")

android {
    namespace = "com.hsrutility.arul"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Native debug-only logging gates on BuildConfig.DEBUG -> that constant only exists if BuildConfig is generated.
    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        // flutter_local_notifications' zonedSchedule uses java.time -> old API levels need the desugaring backport.
        // Turn it off and the build fails outright at checkDebugAarMetadata -> not a runtime-only concern.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.hsrutility.arul"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion   // 36 -> edge-to-edge is ENFORCED
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Launcher and themed icons are vectors -> old APIs cannot render them -> rasterise at build time.
        vectorDrawables.useSupportLibrary = true

        // These feed the com.facebook.sdk.* manifest meta-data -> unset or placeholder resolves to "" -> the SDK stays inert.
        // AppConfig.metaEnabled gates the Dart side in parallel -> a build with no META defines still works.
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
            // R8 shrinks only the Java/Kotlin layer -> libflutter/libapp dominate the APK -> expect a modest win, not a big one.
            // shrinkResources requires minify -> the two flags move together.
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
// Flutter hands `--dart-define` values to Gradle as `dart-defines` -> a comma-separated list of base64 `KEY=VALUE` pairs.
// Reading them here keeps Meta config out of strings.xml -> env/*.json stays the one source for both Dart and native.
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

// Env-file placeholders count as UNSET -> a half-configured build gets an inert SDK, never a bogus app id.
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
    // Java 8+ API desugaring -> flutter_local_notifications needs it for zonedSchedule -> version kept in step with Pakiza's.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // BACKPORTS the Android 12 splash (icon on a field) to API 23+ -> the platform attrs alone apply only on Android 12+.
    // Without it API<=30 falls back to `windowBackground` -> a flat iconless colour for the whole cold start.
    // Android's migration guide says the direct SplashScreen API leaves Android 11 and earlier unchanged -> use this library.
    implementation("androidx.core:core-splashscreen:1.0.1")

    // Media3 is the app's ONLY video runtime -> feedvideo/FeedVideoPlugin and wallpaper/VideoRenderer both build on it.
    // Every media3 artifact below must share one version -> mixed versions fail at runtime, not at build time.
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-common:1.10.1")

    // Share-time watermarking -> Transformer re-encodes the live clip with a full-frame BitmapOverlay burned in.
    implementation("androidx.media3:media3-transformer:1.10.1")
    implementation("androidx.media3:media3-effect:1.10.1")

    // Coroutines carry the apply channel's file writes off the main thread.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    // MainActivity.fetchMetaDeferredLink needs AppLinkData/FacebookSdk -> a plugin's `implementation` deps are off our classpath.
    // facebook_app_events pulls the SAME range -> declaring a RANGE, not a pin, keeps Gradle resolving ONE version for both.
    // Two different pins here and in the plugin would be a runtime mismatch -> never pin these.
    implementation("com.facebook.android:facebook-core:[18.0,19.0)")
    implementation("com.facebook.android:facebook-applinks:[18.0,19.0)")
}

flutter {
    source = "../.."
}
