pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "InnoNetworkAndroid"

include(":innonetwork")
include(":innonetwork-client")
include(":innonetwork-ksp")
include(":innonetwork-kotlinx-serialization")
