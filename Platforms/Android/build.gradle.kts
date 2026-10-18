plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.dokka) apply false
    alias(libs.plugins.kotlin.jvm) apply false
}

allprojects {
    group = "com.innosquad.innonetwork"
    version = "1.0.0"
}
