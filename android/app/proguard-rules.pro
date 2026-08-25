# Flutter/Dart code is AOT-compiled into libapp.so — R8 never sees it. These rules
# only cover the Java/Kotlin layer (plugins, Firebase, PhonePe once they land).

# Flutter embedding
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Kotlin coroutines / metadata used reflectively
-dontwarn kotlinx.coroutines.**
-keepattributes *Annotation*, InnerClasses, Signature, RuntimeVisible*AnnotationS*

# Crashlytics needs line numbers + source file to symbolicate (Phase 4).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# NO -assumenosideeffects ON android.util.Log. One shipped in build 40 (24 Aug
# 2026) to strip v/d/i from release logcat. GA4 session attribution collapsed the
# same day — source/medium (not set) on 88% of trial_started, Meta sources as well
# as Google, against ~0% on builds 38/39 — and this rule was the ONLY build-40
# change R8 can see (Dart is AOT-compiled into libapp.so and never reaches R8).
# Removed in build 41 to test that; the rule also reaches bundled Play Services
# measurement code, not just ours. If release-log hygiene is wanted back, use
# -maximumremovedandroidloglevel scoped to com.hsrutility.arul.** so it cannot
# touch Google's SDKs. The Dart half (_silenceLogsInRelease in main.dart) is
# independent and still silences every debugPrint in release.
