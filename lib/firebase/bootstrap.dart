import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'build_mode.dart';
import 'worker_backend.dart';

bool _appCheckActivated = false;
bool _emulatorsConfigured = false;

const _useFirebaseEmulators = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
const _workerBackendUrl = String.fromEnvironment('LOCALSPOT_BACKEND_URL');
const _enableLocalPanoramaE2E = bool.fromEnvironment(
  'ENABLE_LOCAL_PANORAMA_E2E',
);
const _firebaseEmulatorProjectId = String.fromEnvironment(
  'FIREBASE_EMULATOR_PROJECT_ID',
  defaultValue: 'demo-localspot',
);
const _firebaseEmulatorHost = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: '',
);
const _firebaseAuthEmulatorPort = int.fromEnvironment(
  'FIREBASE_AUTH_EMULATOR_PORT',
  defaultValue: 9099,
);
const _firestoreEmulatorPort = int.fromEnvironment(
  'FIRESTORE_EMULATOR_PORT',
  defaultValue: 8080,
);

@visibleForTesting
void validateFirebaseBootstrapConfiguration({
  required bool debugBuild,
  required bool useEmulators,
  required bool previewBuild,
  required String emulatorProjectId,
  required String emulatorHost,
  bool trialBuild = false,
  String workerBackendUrl = '',
  int authEmulatorPort = 9099,
  int firestoreEmulatorPort = 8080,
}) {
  if (debugBuild && !useEmulators) {
    throw StateError(
      'Debug builds must explicitly enable Firebase emulators. Refusing to '
      'connect a debug app to a production Firebase project.',
    );
  }
  if (useEmulators && !debugBuild) {
    throw StateError('Firebase emulators cannot be enabled in release builds.');
  }
  if (previewBuild && trialBuild) {
    throw StateError('Choose either the read-only preview or online trial mode.');
  }
  if (!debugBuild && !previewBuild && !trialBuild) {
    throw StateError(
      'This APK requires explicit LOCALSPOT_PREVIEW or LOCALSPOT_TRIAL_RELEASE configuration.',
    );
  }
  if (trialBuild &&
      !workerBaseUrlAllowed(
        workerBackendUrl,
        debugBuild: false,
        useFirebaseEmulators: false,
      )) {
    throw StateError(
      'Trial releases require an HTTPS Worker hostname; emulator, LAN, and IP URLs are not allowed.',
    );
  }
  if (useEmulators && emulatorProjectId != 'demo-localspot') {
    throw StateError(
      'Debug Firebase project must be demo-localspot, got $emulatorProjectId.',
    );
  }
  if (useEmulators && emulatorHost.trim().isEmpty) {
    throw StateError('FIREBASE_EMULATOR_HOST is required for emulator builds.');
  }
  if (useEmulators &&
      (authEmulatorPort < 1 ||
          authEmulatorPort > 65535 ||
          firestoreEmulatorPort < 1 ||
          firestoreEmulatorPort > 65535)) {
    throw StateError('Firebase emulator ports must be between 1 and 65535.');
  }
}

/// Local R2 simulation access is available only in an explicitly opted-in
/// debug build connected to Firebase emulators. This can never enable release builds.
bool get localPanoramaE2EEnabled =>
    kDebugMode &&
    _useFirebaseEmulators &&
    _enableLocalPanoramaE2E &&
    _firebaseEmulatorProjectId == 'demo-localspot';

Future<bool> initLocalSpotFirebase() async {
  validateFirebaseBootstrapConfiguration(
    debugBuild: kDebugMode,
    useEmulators: _useFirebaseEmulators,
    previewBuild: localSpotPreviewRelease,
    emulatorProjectId: _firebaseEmulatorProjectId,
    emulatorHost: _firebaseEmulatorHost,
    trialBuild: localSpotTrialRelease,
    workerBackendUrl: _workerBackendUrl,
  );
  if (!_useFirebaseEmulators &&
      Firebase.apps.isEmpty &&
      !DefaultFirebaseOptions.configured) {
    return false;
  }
  try {
    if (_useFirebaseEmulators) {
      if (Firebase.apps.isEmpty) {
        // Use emulator-only credentials; never carry the production API key or
        // app ID into the local emulator build.
        await Firebase.initializeApp(
          options: FirebaseOptions(
            // Firebase Android validates the key's shape even when the SDK is
            // redirected to an emulator. This is deliberately a nonfunctional
            // local-only key, never a production credential.
            apiKey: 'AIzaSyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
            appId: '1:1:android:localspotdemo',
            messagingSenderId: '1',
            projectId: _firebaseEmulatorProjectId,
          ),
        );
      }
      final actualProject = Firebase.app().options.projectId;
      if (actualProject != _firebaseEmulatorProjectId) {
        throw StateError(
          'Firebase emulator project mismatch: expected '
          '$_firebaseEmulatorProjectId, got $actualProject.',
        );
      }
      debugPrint(
        '[firebase-bootstrap] verified emulator Firebase app project='
        '$actualProject',
      );
    } else if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    if (!_useFirebaseEmulators) {
      final expectedProject = DefaultFirebaseOptions.currentPlatform.projectId;
      final actualProject = Firebase.app().options.projectId;
      if (actualProject != expectedProject) {
        throw StateError(
          'Firebase project mismatch: expected $expectedProject, got '
          '$actualProject.',
        );
      }
      debugPrint(
        '[firebase-bootstrap] verified configured project=$actualProject',
      );
    }
    _configureFirebaseEmulators();
    if (!_useFirebaseEmulators) {
      await _configureObservability();
      if (!_appCheckActivated) {
        await FirebaseAppCheck.instance.activate(
          androidProvider:
              kDebugMode
                  ? AndroidProvider.debug
                  : AndroidProvider.playIntegrity,
        );
        _appCheckActivated = true;
      }
    } else {
      debugPrint(
        '[firebase-bootstrap] telemetry and App Check disabled for local emulators',
      );
    }
    return true;
  } catch (error, stack) {
    debugPrint('Firebase/App Check initialization issue: $error\n$stack');
    if (_useFirebaseEmulators || error is StateError) rethrow;
    return Firebase.apps.isNotEmpty;
  }
}

void _configureFirebaseEmulators() {
  if (!_useFirebaseEmulators || _emulatorsConfigured) return;
  if (_firebaseEmulatorHost.trim().isEmpty) {
    throw StateError('FIREBASE_EMULATOR_HOST cannot be empty.');
  }

  FirebaseAuth.instance.useAuthEmulator(
    _firebaseEmulatorHost,
    _firebaseAuthEmulatorPort,
  );
  FirebaseFirestore.instance.useFirestoreEmulator(
    _firebaseEmulatorHost,
    _firestoreEmulatorPort,
  );
  FirebaseFunctions.instanceFor(
    region: 'asia-southeast1',
  ).useFunctionsEmulator(_firebaseEmulatorHost, 5001);
  _emulatorsConfigured = true;
  debugPrint(
    '[firebase-bootstrap] emulators project=$_firebaseEmulatorProjectId '
    'auth=$_firebaseEmulatorHost:$_firebaseAuthEmulatorPort '
    'firestore=$_firebaseEmulatorHost:$_firestoreEmulatorPort '
    'functions=$_firebaseEmulatorHost:5001',
  );
}

bool _observabilityConfigured = false;

Future<void> _configureObservability() async {
  if (_observabilityConfigured) return;
  _observabilityConfigured = true;
  if (localSpotPreviewRelease) {
    try {
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(false);
    } catch (_) {}
    try {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    } catch (_) {}
    return;
  }
  final enabled = !kDebugMode;
  try {
    await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(enabled);
    if (enabled) {
      await FirebaseAnalytics.instance.logEvent(name: 'app_started');
    }
  } catch (error) {
    debugPrint('Firebase Analytics initialization issue: $error');
  }
  try {
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(enabled);
    if (!enabled) return;
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } catch (error) {
    debugPrint('Firebase Crashlytics initialization issue: $error');
  }
}
