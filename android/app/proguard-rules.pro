# Keep release shrinker conservative; aggressive legacy tuning can break
# reflection-heavy libraries (yt-dlp/commons-compress path).

# Flutter required
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable

# Google Play Core - Don't warn about missing classes (we're not using Play Store features)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

# NanoHTTPD - keep all classes in the package
-keep class org.nanohttpd.** { *; }
-dontwarn org.nanohttpd.**

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep class okio.** { *; }

# yt-dlp android - keep all classes to avoid runtime issues
-keep class com.yausername.** { *; }
-dontwarn com.yausername.**

# yt-dlp transitive dependency (Apache Commons Compress) uses reflection
# in zip extra-field bootstrap (ExtraFieldUtils). Keep it intact.
-keep class org.apache.commons.compress.** { *; }
-dontwarn org.apache.commons.compress.**

# Additional rules for native libraries
-keepclasseswithmembernames class * {
    native <methods>;
}
