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
