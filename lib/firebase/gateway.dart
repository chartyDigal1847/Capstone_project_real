// LocalSpotGateway — Firebase-first data gateway.
//
// After the full Firebase migration all reads and writes go through
// [LocalSpotFirebaseApi]. The old Laravel REST client is no longer
// used at runtime; it has been removed from the dependency tree.
//
// Token handling: Firebase Auth manages the user session. The numeric
// token stored in the gateway is the Firebase UID so that the rest of
// the app (AppState) can keep its `api.token != null` pattern to
// distinguish signed-in vs guest state.

import 'firebase_api.dart';

class LocalSpotGateway {
  LocalSpotGateway({LocalSpotFirebaseApi? firebase})
      : firebase = firebase ?? LocalSpotFirebaseApi();

  final LocalSpotFirebaseApi firebase;

  // Always true once Firebase is initialised — no Laravel fallback.
  bool get useFirebase => LocalSpotFirebaseApi.isReady;

  /// Current Firebase UID, or null when not signed in.
  String? get token => firebase.token;

  // No-ops kept for API compatibility with AppState callers that
  // previously stored/restored a Sanctum bearer token via secure storage.
  // Firebase Auth persists the session automatically.
  Future<void> persistToken(String? value) async {}
  Future<void> restoreToken() async {}

  Future<dynamic> get(String path, [Map<String, String>? query]) =>
      firebase.get(path, query);

  Future<Map<String, dynamic>> getEnvelope(
          String path, [Map<String, String>? query]) =>
      firebase.getEnvelope(path, query);

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) =>
      firebase.post(path, body);

  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) =>
      firebase.patch(path, body);

  Future<dynamic> delete(String path) => firebase.delete(path);
}
