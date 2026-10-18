plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.dokka)
    `maven-publish`
}

val dokkaJavadocJar by tasks.registering(Jar::class) {
    description = "Builds API documentation for Maven publication"
    dependsOn("dokkaGeneratePublicationHtml")
    from(layout.buildDirectory.dir("dokka/html"))
    archiveClassifier.set("javadoc")
    from(rootProject.file("../../LICENSE")) { into("META-INF/innonetwork-client") }
}

tasks.withType<Jar>().matching { it.name == "sourceReleaseJar" }.configureEach {
    from(rootProject.file("../../LICENSE")) { into("META-INF/innonetwork-client") }
}

afterEvaluate {
    publishing {
        publications {
            create<org.gradle.api.publish.maven.MavenPublication>("release") {
                from(components["release"])
                artifact(dokkaJavadocJar)
                pom {
                    name.set(project.name)
                    description.set("Platform-native InnoNetwork Android module")
                    url.set("https://github.com/InnoSquadCorp/InnoNetwork")
                    licenses {
                        license {
                            name.set("MIT License")
                            url.set("https://opensource.org/licenses/MIT")
                            distribution.set("repo")
                        }
                    }
                    developers {
                        developer {
                            id.set("innosquad")
                            name.set("InnoSquad")
                            url.set("https://github.com/InnoSquadCorp")
                        }
                    }
                    scm {
                        connection.set("scm:git:https://github.com/InnoSquadCorp/InnoNetwork.git")
                        developerConnection.set("scm:git:ssh://git@github.com/InnoSquadCorp/InnoNetwork.git")
                        url.set("https://github.com/InnoSquadCorp/InnoNetwork")
                    }
                }
            }
        }
        repositories {
            maven {
                name = "preview"
                url = uri(rootProject.layout.buildDirectory.dir("preview-repository"))
            }
        }
    }
}


android {
    namespace = "com.innosquad.innonetwork.client"
    compileSdk = 37

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
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
    api(project(":innonetwork"))

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.okhttp.mockwebserver)
}
