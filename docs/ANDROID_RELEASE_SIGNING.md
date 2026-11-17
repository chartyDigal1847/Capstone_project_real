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
flutter build apk --flavor preview --release `
  --dart-define=LOCALSPOT_PREVIEW=true `
  --dart-define=USE_FIREBASE_EMULATORS=false `
  --android-project-arg=localspotReleaseEnvironment=preview `
  --android-project-arg=localspotPreviewProjectId=capstone-project-561a2
```

The APK is signed with the local preview key at `android/app/localspot-preview-release.jks`. Its password is stored only in ignored `android/key.properties`; back up both securely. Do not share the key or signing properties. `LOCALSPOT_PREVIEW` is required at runtime: a release APK without this flag fails closed before initializing Firebase.

### Isolated trial release (build verified; online readiness pending)

The dedicated Firebase project now has email/password Auth enabled and a registered Android app with package ID `app.locentra.mobile` and Firebase App ID `1:295175740638:android:5c69d12e29c215ca51f64f`. Local, preview, and trial Android product flavors select separate Firebase configs; the trial native config is under `android/app/src/trial/google-services.json`, and `lib/firebase_options_trial.dart` contains its Dart client options. `local` is the default flavor, preserving the existing emulator workflow. Play Integrity App Check remains incomplete, so a release APK is not ready for online use. The current debug application ID is `com.example.test1` (Android namespace `com.example.test_1`); neither legacy example ID should be used for the isolated trial. Do not use `capstone-project-561a2` for a trial build.

```powershell
$env:ORG_GRADLE_PROJECT_localspotReleaseEnvironment = "trial"
$env:ORG_GRADLE_PROJECT_localspotReleaseProjectId = "locentra-spark-trial-20261117"
$env:ORG_GRADLE_PROJECT_localspotReleaseApplicationId = "app.locentra.mobile"
flutter build appbundle --flavor trial --release `
  --dart-define=LOCALSPOT_TRIAL_RELEASE=true `
  --dart-define=LOCALSPOT_BACKEND_URL=https://<approved-worker-host> `
  --android-project-arg=localspotReleaseEnvironment=trial `
  --android-project-arg=localspotReleaseProjectId=locentra-spark-trial-20261117 `
  --android-project-arg=localspotReleaseApplicationId=app.locentra.mobile
```

Gradle reads project properties from `ORG_GRADLE_PROJECT_*` environment variables. Do not put these properties into a tracked file. The release guard rejects the configured production Firebase project and placeholder application IDs, verifies the project/app IDs against the selected flavor config and matching Android `FirebaseOptions`, requires a non-example package name, and requires the private keystore. It cannot verify that the backend has been deployed; confirm the isolated Worker endpoint and trial configuration separately before distribution. The Flutter Worker base URL is supplied at build time with `--dart-define=LOCALSPOT_BACKEND_URL=https://<approved-worker-host>`. The Worker-to-gateway URL and signing secret stay in Worker configuration/secrets and are never placed in Flutter. [Gradle project properties](https://docs.gradle.org/current/userguide/build_environment.html)

The output is `build/app/outputs/bundle/trialRelease/app-trial-release.aab`. For a directly installable arm64 trial APK, use `flutter build apk --flavor trial --release --target-platform android-arm64` with the same two Dart defines; use the same configured upload keystore for both artifacts. App startup fails closed unless `LOCALSPOT_TRIAL_RELEASE=true` and `LOCALSPOT_BACKEND_URL` names a remote HTTPS hostname. HTTP, local/LAN hostnames, and literal IP addresses are rejected for trial builds. This prevents silent fallback to Firebase Functions. Release signing only establishes the keystore configuration; trial release still requires the isolated backend, successful R2 reconciliation, Play Integrity/App Check setup, privacy review, and tested trial endpoints.

Flavored build check (2026-11-17): the no-flag debug command selected default flavor `local` and built `build/app/outputs/flutter-apk/app-local-debug.apk`. The preview release flavor built successfully with package `com.example.test1`. The trial arm64 APK and `build/app/outputs/bundle/trialRelease/app-trial-release.aab` both built and their signatures verified. Android tooling confirmed the trial APK package `app.locentra.mobile` and app label `Locentra`. It was installed and launched on the Pixel 9 emulator, then uninstalled after the smoke check. The trial smoke builds used a placeholder Worker URL and were not connected to or tested against a deployed backend; do not distribute them.

Trial release validation (2026-11-17): Firebase Firestore rules and indexes were deployed to the isolated trial project. The project is Spark, email/password Auth is enabled, and the trial Android app's App Check Play Integrity provider is configured for sideloading. The active release key is the JKS at `android/app/locentra-trial-upload-v2.jks`; its local passwords are in ignored `android/key.properties`. This replaces the earlier shared test signing key after its PKCS#12 store password was rotated but could not be recovered by `keytool`. Keep the replacement key and ignored properties backed up securely; do not share or commit them. Preview APKs built with the shared Gradle release config will now also use the replacement signing identity, so an existing preview installation may need to be uninstalled before installing a newly signed preview APK.

The signed arm64 release APK was built with `LOCALSPOT_BACKEND_URL=https://locentra-api-trial-20261117.digalcharty0.workers.dev` and installed/launched on the Infinix X6873. Firebase bootstrap confirmed the app selected `locentra-spark-trial-20261117`. The APK is `build/app/outputs/flutter-apk/app-trial-release.apk` (about 146.8 MB), package `app.locentra.mobile`, label `Locentra`. Signature verification passed and its SHA-256 matches the certificate registered with the Firebase Android app. Both API and upload gateway health endpoints return 200. On 2026-11-17, the installed signed client obtained App Check, authenticated to the Worker, and loaded its Firestore customer profile. The API and Play Integrity services are now enabled in the trial project. R2 is private and empty; upload reservations remain paused pending initial admin reconciliation and explicit account authorization.
