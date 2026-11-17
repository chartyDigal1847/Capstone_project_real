// Firebase options for the Locentra isolated trial Android app.
// Client API keys identify a Firebase project; protect project data with Auth,
// App Check, IAM, and Firestore rules. Never place service-account keys here.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class TrialFirebaseOptions {
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAa7RrkdATLxwqbnU327CORZXkBOiZqBgg',
    appId: '1:295175740638:android:5c69d12e29c215ca51f64f',
    messagingSenderId: '295175740638',
    projectId: 'locentra-spark-trial-20261117',
  );
}
