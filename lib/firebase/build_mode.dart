/// Explicit read-only online preview mode. This mode must be set only for a
/// signed preview APK. It disables backend writes, Cloud Functions and media
/// gateway operations while allowing Firebase Auth sign-in and public reads.
const localSpotPreviewRelease = bool.fromEnvironment(
  'LOCALSPOT_PREVIEW',
  defaultValue: false,
);
