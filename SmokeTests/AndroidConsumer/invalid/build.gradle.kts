plugins {
    id("com.android.library")
    id("com.google.devtools.ksp")
}

android {
    namespace = "com.innosquad.innonetwork.invalidsmoke"
    compileSdk = 37

    defaultConfig {
        minSdk = 21
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
    implementation("com.innosquad.innonetwork:innonetwork-client:1.0.0")
    ksp("com.innosquad.innonetwork:innonetwork-ksp:1.0.0")
}
