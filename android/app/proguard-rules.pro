# Keep JNI bridge entry points used by the downloaded FFmpegKit shared library.
-keepclasseswithmembers,includedescriptorclasses class * {
    native <methods>;
}

# Keep WorkManager workers instantiated by name after process recreation.
-keep class * extends androidx.work.ListenableWorker { *; }
