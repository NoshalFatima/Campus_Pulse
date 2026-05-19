allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        android?.apply {
            if (namespace == null) {
                namespace = "com.campus_pulse.${project.name.replace(":", "_")}"
            }
            // NDK version jo plugins ko chahiye
            ndkVersion = "28.2.13676358"

            // Drive conflict (T: vs C:) fix karne ke liye incremental build band
            project.extensions.extraProperties.set("kotlin.incremental", false)
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.google.gms:google-services:4.4.4")
        classpath("com.google.firebase:firebase-crashlytics-gradle:2.9.9")
    }
}