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
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.hsrutility.arul"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

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

// facebook_app_events pulls the whole facebook-android-sdk, but Arul and the plugin only touch
// facebook-core and facebook-applinks -> the rest shipped unused dex and an exported, permission-less
// CustomTabActivity (fbconnect://). Neither kept module depends on these (their POMs: core -> bolts only).
configurations.all {
    listOf(
        "facebook-common",
        "facebook-login",
        "facebook-share",
        "facebook-messenger",
        "facebook-gamingservices",
    ).forEach { exclude(group = "com.facebook.android", module = it) }
}

dependencies {
    // Java 8+ API desugaring -> flutter_local_notifications needs it for zonedSchedule -> version kept in step with Pakiza's.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    implementation("androidx.core:core-splashscreen:1.0.1")

    // Every media3 artifact below must share one version -> mixed versions fail at runtime, not at build time.
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-common:1.10.1")

    implementation("androidx.media3:media3-transformer:1.10.1")
    implementation("androidx.media3:media3-effect:1.10.1")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    // MainActivity.fetchMetaDeferredLink needs AppLinkData/FacebookSdk -> a plugin's `implementation` deps are off our classpath.
    // facebook_app_events asks for facebook-android-sdk:[18.0,19.0); Gradle selects a static version inside a range, so
    // these pins keep an unchosen 18.x out of the APK. Keep all three equal and inside the plugin's range on any bump.
    implementation("com.facebook.android:facebook-core:18.3.0")
    implementation("com.facebook.android:facebook-applinks:18.3.0")
    constraints {
        implementation("com.facebook.android:facebook-android-sdk:18.3.0")
    }

    // push/ArulMessagingService extends the firebase_messaging plugin's service -> the plugin's Firebase deps are off our classpath too.
    // Same BoM as firebase_core's FirebaseSDKVersion (4.14.0 -> 34.18.0) -> Gradle resolves ONE firebase-messaging -> bump them together.
    implementation(platform("com.google.firebase:firebase-bom:34.18.0"))
    implementation("com.google.firebase:firebase-messaging")

    // auth/PlayServicesChannel needs GoogleApiAvailability -> the sign-in plugin's copy is off our classpath too.
    // A floor, not a pin: Gradle resolves the highest version any dependency asks for, and 18.9.0 is what it resolves today.
    implementation("com.google.android.gms:play-services-base:18.9.0")

    // upload/MediaPickChannel builds the Photo Picker intent with androidx's PickVisualMedia contract (1.7.0+).
    // Same floor rule: the transitive copy is off our classpath, and 1.9.0 is what Gradle resolves today.
    implementation("androidx.activity:activity:1.9.0")

    implementation("com.google.android.play:app-update:2.1.0")
}

flutter {
    source = "../.."
}
