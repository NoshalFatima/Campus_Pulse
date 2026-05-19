plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.campuspulse.campus_pulse"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    aaptOptions {
        noCompress("tflite", "lite")
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    defaultConfig {
        applicationId = "com.campuspulse.campus_pulse"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    packagingOptions {
        pickFirst("lib/armeabi-v7a/libtensorflowlite_jni.so")
        pickFirst("lib/arm64-v8a/libtensorflowlite_jni.so")
        pickFirst("lib/x86_64/libtensorflowlite_jni.so")
    }
}
flutter {
    source = "../.."
}


dependencies {
    implementation("com.onesignal:OneSignal:[5.0.0, 5.99.99]")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")
}
