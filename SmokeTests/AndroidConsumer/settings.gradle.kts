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
        if (providers.gradleProperty("usePublishedPreview").orNull == "true") {
            maven {
                url = uri(file("../../Platforms/Android/build/preview-repository"))
            }
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "InnoNetworkAndroidConsumerSmoke"

include(":consumer")
include(":invalid")
include(":runtime")

if (providers.gradleProperty("usePublishedPreview").orNull != "true") {
    includeBuild("../../Platforms/Android")
}
