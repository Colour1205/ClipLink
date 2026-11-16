plugins {
    alias(libs.plugins.android.application)
    // AGP 9 applies Kotlin itself (built-in Kotlin support), so there is no
    // kotlin-android plugin here on purpose - adding one conflicts. The
    // Compose compiler plugin still has to be applied explicitly.
    alias(libs.plugins.compose.compiler)
}

android {
    namespace = "io.uaena.cliplink"
    compileSdk {
        // 37.1, not 37.0: the alpha Compose artifacts (ui 1.13.0-alpha03)
        // refuse to be consumed by anything compiled against an older minor
        // API level. targetSdk stays at 37 - compiling against newer APIs is
        // independent of opting in to newer runtime behavior.
        version = release(37) { minorApiLevel = 1 }
    }

    defaultConfig {
        applicationId = "io.uaena.cliplink"
        minSdk = 31
        targetSdk = 37
        versionCode = 8
        versionName = "2.2.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            // R8: code shrinking, optimisation and resource shrinking. Off, the
            // release APK was 52 MB, nearly all of it library code the app never
            // calls, stored uncompressed and kept as such on the phone. The
            // default optimize rules come with it (keepRules.includeDefault);
            // proguard-rules.pro says why nothing else needs keeping.
            optimization {
                enable = true
            }
            proguardFiles("proguard-rules.pro")
            // No 32-bit x86 phone runs Android 12 (minSdk 31); the emulator
            // runs debug builds. x86_64 stays for Chromebooks and the like.
            ndk {
                abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            // Kotlin's builtins descriptors, read only by kotlin-reflect, which
            // the app doesn't use.
            excludes += "/kotlin/**"
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.activity.compose)
    implementation(libs.kotlinx.coroutines.android)

    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.zxing.core)
    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)

    testImplementation(libs.junit)
    testImplementation(libs.android.json)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
}
