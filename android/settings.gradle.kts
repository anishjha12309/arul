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
    // google-services.json is git-ignored -> app/build.gradle.kts applies these only when it exists.
    // google-services processes that file -> Firebase.initializeApp() resolves natively -> no Dart-side options are passed.
    // crashlytics 3.0.7 and firebase-perf 2.0.2 are the first AGP 9 compatible releases -> never downgrade them.
    id("com.google.gms.google-services") version "4.5.0" apply false
    id("com.google.firebase.crashlytics") version "3.0.7" apply false
    id("com.google.firebase.firebase-perf") version "2.0.2" apply false
}

include(":app")
