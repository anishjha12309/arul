pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    // Firebase — declared here (apply false) and applied CONDITIONALLY in
    // app/build.gradle.kts (only when android/app/google-services.json exists, so
    // the build stays green until the Firebase project is provisioned).
    // google-services processes google-services.json so Firebase.initializeApp()
    // resolves natively. crashlytics 3.0.7 + firebase-perf 2.0.2 are the versions
    // that fixed AGP 9.0.0 compatibility (we're on AGP 9.0.1).
    id("com.google.gms.google-services") version "4.5.0" apply false
    id("com.google.firebase.crashlytics") version "3.0.7" apply false
    id("com.google.firebase.firebase-perf") version "2.0.2" apply false
}

include(":app")
