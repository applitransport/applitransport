import java.io.FileInputStream
import java.util.Properties

// Signature release avec le keystore personnel. Le mot de passe n'est enregistré nulle part :
// compiler_release.sh le demande et le passe par des variables d'environnement, le temps d'une
// compilation. (Variante possible : android/key.properties, jamais versionné, avec storeFile,
// storePassword, keyAlias et keyPassword.)
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) {
        load(FileInputStream(f))
    } else if (System.getenv("APPLI_KEYSTORE") != null) {
        setProperty("storeFile", System.getenv("APPLI_KEYSTORE"))
        setProperty("storePassword", System.getenv("APPLI_KEYSTORE_PASSWORD") ?: "")
        setProperty("keyAlias", System.getenv("APPLI_KEY_ALIAS") ?: "applitransport")
        setProperty("keyPassword", System.getenv("APPLI_KEY_PASSWORD") ?: System.getenv("APPLI_KEYSTORE_PASSWORD") ?: "")
    }
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "fr.applitransport.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "fr.applitransport.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyProperties.isNotEmpty()) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Pas de signature de secours : un APK release doit toujours porter la clé personnelle, sans quoi
// Android refuserait les mises à jour. Les compilations de développement ne sont pas concernées.
gradle.taskGraph.whenReady {
    if (keyProperties.isEmpty() && allTasks.any { it.name.contains("Release") }) {
        throw GradleException("Signature release : lancez appli/compiler_release.sh (voir en tête de app/build.gradle.kts)")
    }
}
