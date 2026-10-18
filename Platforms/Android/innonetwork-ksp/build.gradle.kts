plugins {
    alias(libs.plugins.dokka)
    alias(libs.plugins.kotlin.jvm)
    `java-library`
    `maven-publish`
}

val dokkaJavadocJar by tasks.registering(Jar::class) {
    description = "Builds API documentation for Maven publication"
    dependsOn("dokkaGeneratePublicationHtml")
    from(layout.buildDirectory.dir("dokka/html"))
    archiveClassifier.set("javadoc")
    from(rootProject.file("../../LICENSE")) { into("META-INF/innonetwork-ksp") }
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
    withSourcesJar()
}

kotlin {
    explicitApi()
    @OptIn(org.jetbrains.kotlin.gradle.dsl.abi.ExperimentalAbiValidation::class)
    abiValidation {}
    compilerOptions {
        allWarningsAsErrors.set(true)
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

dependencies {
    implementation(libs.ksp.symbol.processing.api)

    testImplementation(libs.junit)
}

publishing {
    publications {
        create<MavenPublication>("release") {
            from(components["java"])
            artifact(dokkaJavadocJar)
            pom {
                name.set(project.name)
                description.set("Compile-time endpoint generator for InnoNetwork Android")
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
