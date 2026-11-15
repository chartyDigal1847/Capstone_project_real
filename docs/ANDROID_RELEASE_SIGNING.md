# Android release signing

The Android release build never uses the debug signing key. The guarded trial path requires an isolated Firebase project, registered trial app, private release keystore, and local `android/key.properties` file. A separately named **preview** path is available for a signed, read-only APK against the already registered configured Firebase app. Preview builds require an explicit preview Gradle mode and `LOCALSPOT_PREVIEW=true`; they still verify that the checked-in Firebase Android and Dart options agree, require a local private keystore, and keep Firebase emulators disabled. Preview mode blocks all Cloud Functions, all application-data writes, R2 operations, and publication. It allows existing-account Auth sign-in and Firestore reads. It does not make the configured Firebase project an isolated trial backend.

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

### Free preview APK

The project inventory verified that the configured Firestore database is on the free tier and contains existing application data. Treat the project as live. The preview app uses its already registered Android package ID and permits sign-in/profile/catalog reads only. Do not use registration, data mutation, media upload/retrieval, moderation, storage administration, or publication from this APK. Panorama processing and review are local and do not submit a server review.

```powershell
$env:ORG_GRADLE_PROJECT_localspotReleaseEnvironment = "preview"
$env:ORG_GRADLE_PROJECT_localspotPreviewProjectId = "capstone-project-561a2"
flutter build apk --release `
  --dart-define=LOCALSPOT_PREVIEW=true `
  --dart-define=USE_FIREBASE_EMULATORS=false `
  --android-project-arg=localspotReleaseEnvironment=preview `
  --android-project-arg=localspotPreviewProjectId=capstone-project-561a2
```

The APK is signed with the local preview key at `android/app/localspot-preview-release.jks`. Its password is stored only in ignored `android/key.properties`; back up both securely. Do not share the key or signing properties. `LOCALSPOT_PREVIEW` is required at runtime: a release APK without this flag fails closed before initializing Firebase.

### Isolated trial release (not currently buildable)

After the user approves trial resource setup, create the dedicated Firebase trial project, register the selected trial application ID, and regenerate both `android/app/google-services.json` and `lib/firebase_options.dart` for that project. Do not use `capstone-project-561a2` for a trial build. Then set the environment properties and build:

```powershell
$env:ORG_GRADLE_PROJECT_localspotReleaseEnvironment = "trial"
$env:ORG_GRADLE_PROJECT_localspotReleaseProjectId = "your-trial-project-id"
$env:ORG_GRADLE_PROJECT_localspotReleaseApplicationId = "ph.yourteam.localspot"
flutter build appbundle --release
```

Gradle reads project properties from `ORG_GRADLE_PROJECT_*` environment variables. Do not put these properties into a tracked file. The release guard rejects the configured production Firebase project and placeholder application IDs, verifies the project/app IDs against `google-services.json` and the Android `FirebaseOptions`, requires a non-example package name, and requires the private keystore. It cannot verify that Cloud Functions or the Worker have been deployed; confirm those separately before distribution. The Worker HTTPS URL is configured in Firebase Functions as `R2_GATEWAY_URL`, so the Flutter bundle receives the secure gateway URL only through authorized backend responses. [Gradle project properties](https://docs.gradle.org/current/userguide/build_environment.html)

The output is `build/app/outputs/bundle/release/app-release.aab`. For a directly installable arm64 trial APK, use `flutter build apk --release --target-platform android-arm64`; use the same configured upload keystore for both artifacts. Release signing only establishes the keystore configuration; trial release still requires the isolated backend, successful R2 reconciliation, Play Integrity/App Check setup, privacy review, and tested trial endpoints.
