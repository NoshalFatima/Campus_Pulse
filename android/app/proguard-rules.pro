-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-dontwarn org.tensorflow.lite.**
-dontwarn org.tensorflow.lite.gpu.**


# OneSignal
-keep class com.onesignal.** { *; }
-dontwarn com.onesignal.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**