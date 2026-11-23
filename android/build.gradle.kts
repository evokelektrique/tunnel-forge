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

    val pluginNamespaces = mapOf(
        "flutter_secure_storage" to "com.it_nomads.fluttersecurestorage",
        "jni" to "com.github.dart_lang.jni",
        "jni_flutter" to "com.github.dart_lang.jni_flutter",
    )
    pluginNamespaces[name]?.let { ns ->
        // Older Groovy hasProperty("namespace") checks miss AGP 9's library namespace DSL.
        pluginManager.withPlugin("com.android.library") {
            extensions.configure<LibraryExtension> {
                namespace = ns
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
