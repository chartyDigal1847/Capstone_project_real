import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningPropertiesFile = rootProject.file("key.properties")
val releaseSigningProperties = Properties().apply {
    if (releaseSigningPropertiesFile.exists()) {
        releaseSigningPropertiesFile.inputStream().use { stream -> load(stream) }
    }
}
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseTaskRequested) {
    val requiredKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    val missingKeys = requiredKeys.filter { releaseSigningProperties.getProperty(it).isNullOrBlank() }
    require(releaseSigningPropertiesFile.exists() && missingKeys.isEmpty()) {
        "Release builds require android/key.properties with storeFile, storePassword, keyAlias, and keyPassword. See docs/ANDROID_RELEASE_SIGNING.md."
    }
    val configuredKeystore = File(requireNotNull(releaseSigningProperties.getProperty("storeFile")))
    val resolvedKeystore = if (configuredKeystore.isAbsolute) configuredKeystore else rootProject.file(configuredKeystore.path)
    require(resolvedKeystore.isFile) {
        "The upload keystore configured in android/key.properties does not exist. See docs/ANDROID_RELEASE_SIGNING.md."
    }
}

android {
    namespace = "com.example.test_1"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (releaseSigningPropertiesFile.exists()) {
            create("release") {
                val keystorePath = releaseSigningProperties.getProperty("storeFile")
                storeFile = if (file(keystorePath).isAbsolute) file(keystorePath) else rootProject.file(keystorePath)
                storePassword = releaseSigningProperties.getProperty("storePassword")
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.test_1"
        if (releaseTaskRequested) {
            val releaseEnvironment = providers.gradleProperty("localspotReleaseEnvironment").orNull
            val releaseProjectId = providers.gradleProperty("localspotReleaseProjectId").orNull
            val releaseApplicationId = providers.gradleProperty("localspotReleaseApplicationId").orNull
            require(releaseEnvironment == "production") {
                "Release builds require -PlocalspotReleaseEnvironment=production after selecting the production Firebase project."
            }
            require(!releaseProjectId.isNullOrBlank() && !releaseApplicationId.isNullOrBlank()) {
                "Release builds require localspotReleaseProjectId and localspotReleaseApplicationId Gradle properties."
            }
            val configuredApplicationId = applicationId.orEmpty()
            require(!configuredApplicationId.startsWith("com.example.") && configuredApplicationId == releaseApplicationId) {
                "Replace the template Android applicationId and match it to -PlocalspotReleaseApplicationId before release."
            }

            val googleServicesFile = file("google-services.json")
            require(googleServicesFile.exists()) { "Missing android/app/google-services.json for release." }
            val googleServices = groovy.json.JsonSlurper().parse(googleServicesFile) as Map<*, *>
            val firebaseProjectId = (googleServices["project_info"] as? Map<*, *>)?.get("project_id") as? String
            require(firebaseProjectId == releaseProjectId) {
                "google-services.json project_id must match -PlocalspotReleaseProjectId."
            }
            val matchingAndroidApps = (googleServices["client"] as? List<*>)
                .orEmpty()
                .filterIsInstance<Map<*, *>>()
                .filter { client ->
                    val info = client["client_info"] as? Map<*, *>
                    val android = info?.get("android_client_info") as? Map<*, *>
                    android?.get("package_name") == applicationId
                }
            require(matchingAndroidApps.size == 1) {
                "google-services.json must contain exactly one Android client matching $applicationId."
            }
            val googleServicesAppId = ((matchingAndroidApps.single()["client_info"] as Map<*, *>)
                ["mobilesdk_app_id"]) as? String
            val firebaseOptionsFile = rootProject.file("../lib/firebase_options.dart")
            require(firebaseOptionsFile.exists()) { "Missing lib/firebase_options.dart for release." }
            val firebaseOptionsSource = firebaseOptionsFile.readText()
            val androidOptions = Regex("static const FirebaseOptions android = FirebaseOptions\\(([\\s\\S]*?)\\);")
                .find(firebaseOptionsSource)?.groupValues?.get(1)
            val optionsProjectId = androidOptions?.let {
                Regex("projectId: '([^']+)'").find(it)?.groupValues?.get(1)
            }
            val optionsAppId = androidOptions?.let {
                Regex("appId: '([^']+)'").find(it)?.groupValues?.get(1)
            }
            require(optionsProjectId == releaseProjectId && optionsAppId == googleServicesAppId) {
                "Android FirebaseOptions must match the production google-services.json project and app registration."
            }
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (releaseSigningPropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
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
