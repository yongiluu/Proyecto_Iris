allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Redirección del directorio de build requerida por Flutter 3.44+
// para que Flutter pueda localizar el APK generado.
val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

// Forzar compileSdk 36 en TODOS los plugins de Flutter.
// Soluciona: "Dependency 'androidx.fragment:fragment' requires compile against version 34+"
// Usa plugins.withId (reactivo) en vez de afterEvaluate (imperativo)
// para evitar "Cannot run afterEvaluate when the project is already evaluated".
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension> {
            compileSdk = 34
            defaultConfig.targetSdk = 34
        }
    }
}

// tflite_flutter compila Java con target 11 pero no fija el de Kotlin (queda en el del JDK, 21):
// "Inconsistent JVM-target compatibility". Se alinea Kotlin a 11 solo en ese plugin.
subprojects {
    if (name == "tflite_flutter") {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
