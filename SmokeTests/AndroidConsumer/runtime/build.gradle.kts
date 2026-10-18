plugins {
    id("com.android.application")
    id("com.google.devtools.ksp")
}

android {
    namespace = "com.innosquad.innonetwork.runtimesmoke"
    compileSdk = 37
    defaultConfig {
        applicationId = "com.innosquad.innonetwork.runtimesmoke"
        minSdk = 21
        targetSdk = 37
        versionCode = 1
        versionName = "1.0.0"
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            // This is an isolated test app, never a registry or store artifact.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

kotlin {
    explicitApi()
    compilerOptions {
        allWarningsAsErrors.set(true)
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

dependencies {
    implementation("com.innosquad.innonetwork:innonetwork:1.0.0")
    implementation("com.innosquad.innonetwork:innonetwork-client:1.0.0")
    implementation("com.innosquad.innonetwork:innonetwork-kotlinx-serialization:1.0.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    ksp("com.innosquad.innonetwork:innonetwork-ksp:1.0.0")
}
