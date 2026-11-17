import groovy.json.JsonSlurper
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val taskNames = gradle.startParameter.taskNames.joinToString(" ").lowercase()
val releaseBuildRequested = taskNames.contains("release")
val requestedReleaseFlavor = when {
    taskNames.contains("trialrelease") -> "trial"
    taskNames.contains("previewrelease") -> "preview"
    releaseBuildRequested -> null
    else -> null
}
val localspotReleaseEnvironment = providers.gradleProperty("localspotReleaseEnvironment").orNull
val localspotReleaseProjectId = providers.gradleProperty("localspotReleaseProjectId").orNull
val localspotPreviewProjectId = providers.gradleProperty("localspotPreviewProjectId").orNull
val localspotReleaseApplicationId = providers.gradleProperty("localspotReleaseApplicationId").orNull
val localspotApplicationId = if (releaseBuildRequested && localspotReleaseEnvironment == "trial") {
    val configuredApplicationId = requireNotNull(localspotReleaseApplicationId) {
        "Trial releases require -PlocalspotReleaseApplicationId for the registered trial Android app."
    }
    require(configuredApplicationId == "app.locentra.mobile") {
        "The registered Locentra trial Android app uses application ID app.locentra.mobile."
    }
    configuredApplicationId
} else {
    // The preview uses only the Android app ID already registered in the
    // checked-in Firebase config. It does not relax the trial release checks.
    "com.example.test1"
}

if (releaseBuildRequested) {
    require(localspotReleaseEnvironment == "trial" || localspotReleaseEnvironment == "preview") {
        "Release tasks require an explicit trial or preview mode. No implicit release configuration is allowed."
    }
    require(requestedReleaseFlavor == localspotReleaseEnvironment) {
        "Release flavor must match -PlocalspotReleaseEnvironment (trial or preview). Use --flavor ${localspotReleaseEnvironment}."
    }
    val trialRelease = localspotReleaseEnvironment == "trial"
    val googleServicesFile = if (trialRelease) {
        file("src/trial/google-services.json")
    } else {
        file("google-services.json")
    }
    require(googleServicesFile.isFile) { "Missing Firebase Android config at ${googleServicesFile.path}." }
    val googleServices = JsonSlurper().parse(googleServicesFile) as Map<*, *>
    val firebaseProjectId = (googleServices["project_info"] as? Map<*, *>)?.get("project_id")
    val expectedFirebaseProjectId = if (trialRelease) {
        require(!localspotReleaseProjectId.isNullOrBlank() && localspotReleaseProjectId != "capstone-project-561a2") {
            "Trial release requires an isolated Firebase project; the configured application project is not allowed."
        }
        localspotReleaseProjectId
    } else {
        require(localspotPreviewProjectId == "capstone-project-561a2") {
            "Preview release must explicitly confirm the configured Firebase project ID."
        }
        localspotPreviewProjectId
    }
    require(firebaseProjectId == expectedFirebaseProjectId) {
        "Firebase Android project mismatch: expected $expectedFirebaseProjectId, got $firebaseProjectId."
    }
    if (trialRelease) {
        require(localspotApplicationId.matches(Regex("^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z][a-zA-Z0-9_]*)+$")) &&
            !localspotApplicationId.startsWith("com.example.")) {
            "Set a registered non-placeholder trial application ID."
        }
    }
    val matchingClient = (googleServices["client"] as? List<*>)
        ?.filterIsInstance<Map<*, *>>()
        ?.firstOrNull { client ->
            val info = client["client_info"] as? Map<*, *>
            val android = info?.get("android_client_info") as? Map<*, *>
            android?.get("package_name") == localspotApplicationId
        }
    require(matchingClient != null) {
        "google-services.json has no client registered for $localspotApplicationId."
    }
    val googleAppId = ((matchingClient["client_info"] as? Map<*, *>)?.get("mobilesdk_app_id") as? String)
    val optionsFile = if (trialRelease) {
        file("../../lib/firebase_options_trial.dart")
    } else {
        file("../../lib/firebase_options.dart")
    }
    require(optionsFile.isFile) { "Missing Firebase Dart options at ${optionsFile.path}." }
    val optionsText = optionsFile.readText()
    val androidOptions = Regex(
        "static const FirebaseOptions android = FirebaseOptions\\((.*?)\\);",
        RegexOption.DOT_MATCHES_ALL,
    ).find(optionsText)?.groupValues?.get(1)
    require(androidOptions != null) { "Could not read the Android Firebase options." }
    val dartProjectId = Regex("projectId:\\s*'([^']+)'").find(androidOptions)?.groupValues?.get(1)
    val dartAppId = Regex("appId:\\s*'([^']+)'").find(androidOptions)?.groupValues?.get(1)
    require(dartProjectId == expectedFirebaseProjectId && googleAppId == dartAppId) {
        "Firebase Android options do not match the selected release project and app in google-services.json."
    }

    val keyPropertiesFile = rootProject.file("key.properties")
    require(keyPropertiesFile.isFile) {
        "Release signing is not configured. Create android/key.properties and provide a private upload keystore; debug signing is prohibited."
    }
    val keyProperties = Properties().apply { keyPropertiesFile.inputStream().use(::load) }
    for (key in listOf("storeFile", "storePassword", "keyAlias", "keyPassword")) {
        require(!keyProperties.getProperty(key).isNullOrBlank()) {
            "android/key.properties is missing $key."
        }
    }
    val releaseKeystore = rootProject.file(keyProperties.getProperty("storeFile"))
    require(releaseKeystore.isFile) { "Configured release keystore does not exist." }
}

android {
    namespace = "com.example.test_1"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Flavor identities are explicit below. The default is only a fallback.
        applicationId = "com.example.test1"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ML Kit bundled face detection and the panorama native pipeline require API 24+.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "environment"
    productFlavors {
        create("local") {
            dimension = "environment"
            applicationId = "com.example.test1"
        }
        create("preview") {
            dimension = "environment"
            applicationId = "com.example.test1"
        }
        create("trial") {
            dimension = "environment"
            applicationId = "app.locentra.mobile"
        }
    }

    buildTypes {
        release {
            if (releaseBuildRequested) {
                val keyProperties = Properties().apply {
                    rootProject.file("key.properties").inputStream().use(::load)
                }
                signingConfig = signingConfigs.create("localspotTrialRelease") {
                    storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                    storePassword = keyProperties.getProperty("storePassword")
                    keyAlias = keyProperties.getProperty("keyAlias")
                    keyPassword = keyProperties.getProperty("keyPassword")
                }
            } else {
                // Keep release variants unsigned unless all trial release guards pass.
                signingConfig = null
            }
        }
    }
}

dependencies {
    implementation("com.google.mlkit:face-detection:16.1.7")
    implementation("com.google.mediapipe:tasks-vision:0.10.35")
    implementation("androidx.exifinterface:exifinterface:1.4.2")
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
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
