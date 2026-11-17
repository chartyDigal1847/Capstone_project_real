# Locentra free preview APK

## Configuration

This is a signed, read-only preview build for the existing configured Firebase Android project. Firebase database metadata reports the default Firestore database as Standard with `freeTier: true`; billing-account status was not independently queried, and this report relies on the owner's confirmation that Blaze billing was canceled. The database has existing application records, so this APK intentionally does not write application data. It does not use emulators, localhost, Wrangler local mode, Firebase Functions, or the R2 gateway.

The preview Gradle mode is explicitly separate from the isolated-trial mode. It verifies the Firebase project ID and Android app ID against `google-services.json` and `firebase_options.dart`, uses the already registered side-by-side Android app identity `com.example.test1`, and requires a private local release keystore. The Flutter runtime also requires `LOCALSPOT_PREVIEW=true` and rejects emulator settings. The previously registered debug app `com.example.test_1` and its device data are left installed and untouched.

## Available in preview

- Sign in and sign out with an existing Firebase Authentication account. New account registration is blocked because the profile-creation trigger is a Cloud Function and is not deployed for this free preview.
- Read permitted public Firestore catalog data and the authenticated user's existing profile. The account must already have a profile document with its role assigned.
- On-device JPEG panorama detection, local derivative generation, manual blur editing, spherical viewer, 48-direction owner review, and local review/correction persistence where reachable from the owner tour editor. Local review is an owner attestation stored on the device; it is not submitted to Firebase and cannot authorize publication.
- Local catalog matching and app-side browsing/filtering. Remote Firebase AI calls are disabled in preview.

Automated person detection can miss people. The owner must inspect the complete panorama; a local review does not guarantee privacy and does not make any panorama public.

## Disabled in preview

- Every Cloud Functions callable, including registration/profile trigger-dependent operations, store/product/listing/promotion/tour mutations, moderation, feedback/report submission, quota/reconciliation administration, review submission and publication.
- All Firestore application writes, including favorites and profile edits. Firestore security rules have not been relaxed.
- R2 upload, deletion, private-media capability retrieval, quota finalization, and public panorama delivery. No Worker URL or R2 credential is included in Flutter.
- Store and product image upload; panorama original/derivative upload; panorama publication.
- New account registration. Use an already provisioned account; if none is available, the online owner-only preview cannot be entered without a backend change.

Disabled API operations return errors or remain unavailable; the client never replaces a trusted operation with a direct Firestore write. The Firebase Functions Flutter package remains in the dependency graph, but the preview guard rejects callable invocations, and the admin storage screen skips its direct callable paths.

## Build and install

The previously installed preview APK is at `build/app/outputs/flutter-apk/app-release.apk`. The flavored rebuild below outputs `build/app/outputs/flutter-apk/app-preview-release.apk`:

```powershell
flutter build apk --flavor preview --release `
  --dart-define=LOCALSPOT_PREVIEW=true `
  --dart-define=USE_FIREBASE_EMULATORS=false `
  --android-project-arg=localspotReleaseEnvironment=preview `
  --android-project-arg=localspotPreviewProjectId=capstone-project-561a2
```

The signing key is local at `android/app/localspot-preview-release.jks`; its password configuration is in ignored `android/key.properties`. Keep both private and make an encrypted backup. This preview key is not the future Play upload key.

The APK was installed alongside the existing debug package on the Infinix X6873 and launched successfully. Release logs confirmed the configured Firebase project; no account was signed in. Startup may perform permitted public catalog reads, but a successful Firestore response was not separately verified. Preview analytics and Crashlytics collection are disabled, and no Firestore/Auth account write or R2 request was made. Before signing in, confirm the operator intends the app to read the existing configured project's public catalog and profile documents.

## Current artifact validation

- Package ID: `com.example.test1` (registered in the existing Firebase Android config).
- Version: `1.0.0` (version code 1).
- Minimum Android API: 24; target API 36.
- Signature: APK Signature Scheme v2 verified; one RSA-3072 signer named LocalSpot Preview.
- Certificate SHA-256: `abf4a906ec1cb6cf8df32dc59c0455626a1a500e21b626cac446fc09fbcd2f3e`.
- APK size: 192,566,473 bytes.
- APK SHA-256: `53b0984588eb6191e4a4bb4bb24a00a591261c16727f8b82e28b989e9ed03ccf`.
- No app-specific emulator or local gateway host is configured. Generic SDK libraries may contain localhost strings; the app's compiled preview settings set emulator use false and an empty emulator host.

The artifact is for limited direct installation/testing only. It is not a Play Store release and does not provide online backend mutation or media storage workflows.
