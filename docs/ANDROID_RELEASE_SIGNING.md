# Android release signing

The Android release build no longer uses the debug signing key. A release task requires a private upload keystore and the local `android/key.properties` file; both are ignored by Git. Release builds also fail unless Gradle is explicitly told the production Firebase project and final Android application ID and all checked-in Firebase Android configuration matches those values.

## Create a private upload keystore

From the project root in PowerShell, generate the key in a secure location. Replace the alias and identity values with the team's chosen values. Keep the password private.

```powershell
keytool -genkey -v -keystore android/app/localspot-upload-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias localspot-upload
```

Create `android/key.properties` locally with this format:

```properties
storeFile=app/localspot-upload-key.jks
storePassword=REPLACE_WITH_KEYSTORE_PASSWORD
keyAlias=localspot-upload
keyPassword=REPLACE_WITH_KEY_PASSWORD
```

Use forward slashes in `storeFile`, even on Windows. Do not commit `key.properties`, the keystore, passwords, or copies in source control. Store an encrypted backup of the keystore and its credentials separately; losing the upload key can block future releases unless Play App Signing recovery is available.

## Build

After registering the final application ID in the production Firebase project and regenerating both `android/app/google-services.json` and `lib/firebase_options.dart` for that same project, build an Android App Bundle with explicit release properties:

```powershell
$env:ORG_GRADLE_PROJECT_localspotReleaseEnvironment = "production"
$env:ORG_GRADLE_PROJECT_localspotReleaseProjectId = "your-production-project-id"
$env:ORG_GRADLE_PROJECT_localspotReleaseApplicationId = "ph.yourteam.localspot"
flutter build appbundle --release
```

Gradle reads project properties from `ORG_GRADLE_PROJECT_*` environment variables. Do not put these properties into a tracked file. The release guard also requires the production project ID and app ID to match the Android client and app ID in both Firebase configuration files. [Gradle project properties](https://docs.gradle.org/current/userguide/build_environment.html)

The output is `build/app/outputs/bundle/release/app-release.aab`. Release signing only establishes the keystore configuration; production release still requires the correct Firebase project/options, final application ID, Play Integrity registration, privacy review, and Play Console checks.
