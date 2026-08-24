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

# Release hygiene: strip the debug-chatter half of android.util.Log from the
# Java/Kotlin layer (R8 minify is already on for release). v/d/i are developer
# narration and must not reach a user's logcat from a Play install.
#
# w/e are KEPT deliberately — they are operational error diagnostics (decoder
# fallbacks, OEM wallpaper refusals, PhonePe failures), the lines that make a
# field report actionable. Silencing them would buy nothing and cost triage.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
