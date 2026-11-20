import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.artifacts.repositories.MavenArtifactRepository

plugins {
    id("com.android.application") apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
    repositories.withType<MavenArtifactRepository>().configureEach {
        if (url.toString().contains("/download.flutter.io")) {
            content { includeGroup("io.flutter") }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    if (name == "flutter_secure_storage") {
        // Version 11.2.0's Groovy hasProperty check misses the AGP 9 library namespace.
        pluginManager.withPlugin("com.android.library") {
            extensions.configure<LibraryExtension> {
                namespace = "com.it_nomads.fluttersecurestorage"
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
