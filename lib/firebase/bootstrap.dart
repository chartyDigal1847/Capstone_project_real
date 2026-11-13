import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

bool _appCheckActivated = false;
bool _emulatorsConfigured = false;

const _useFirebaseEmulators = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
const _firebaseEmulatorHost = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: '127.0.0.1',
);

Future<bool> initLocalSpotFirebase() async {
  if (_useFirebaseEmulators && !kDebugMode) {
    throw StateError('Firebase emulators cannot be enabled in release builds.');
  }
  if (Firebase.apps.isEmpty && !DefaultFirebaseOptions.configured) return false;
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    _configureFirebaseEmulators();
    await _configureObservability();
    if (!_appCheckActivated) {
      await FirebaseAppCheck.instance.activate(
        androidProvider:
            kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      );
      _appCheckActivated = true;
    }
    return true;
  } catch (error, stack) {
    debugPrint('Firebase/App Check initialization issue: $error\n$stack');
    if (_useFirebaseEmulators) rethrow;
    return Firebase.apps.isNotEmpty;
  }
}

void _configureFirebaseEmulators() {
  if (!_useFirebaseEmulators || _emulatorsConfigured) return;
  if (_firebaseEmulatorHost.trim().isEmpty) {
    throw StateError('FIREBASE_EMULATOR_HOST cannot be empty.');
  }

  FirebaseAuth.instance.useAuthEmulator(_firebaseEmulatorHost, 9099);
  FirebaseFirestore.instance.useFirestoreEmulator(_firebaseEmulatorHost, 8080);
  FirebaseFunctions.instanceFor(
    region: 'asia-southeast1',
  ).useFunctionsEmulator(_firebaseEmulatorHost, 5001);
  FirebaseStorage.instance.useStorageEmulator(_firebaseEmulatorHost, 9199);
  _emulatorsConfigured = true;
  debugPrint('Firebase emulators enabled at $_firebaseEmulatorHost');
}

bool _observabilityConfigured = false;

Future<void> _configureObservability() async {
  if (_observabilityConfigured) return;
  _observabilityConfigured = true;
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
