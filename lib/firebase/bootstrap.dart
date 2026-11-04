import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

Future<bool> initLocalSpotFirebase() async {
  if (Firebase.apps.isNotEmpty) return true;
  if (!DefaultFirebaseOptions.configured) return false;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    return true;
  } catch (error, stack) {
    debugPrint('Firebase init skipped: $error\n$stack');
    return false;
  }
}
