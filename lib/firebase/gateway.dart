// LocalSpotGateway — Firebase-first data gateway.
//
// Reads and writes go through [LocalSpotFirebaseApi]. Firebase Auth
// manages the user session; the gateway exposes the current UID so the
// app can distinguish signed-in users from guests.

import 'firebase_api.dart';

class LocalSpotGateway {
  LocalSpotGateway({LocalSpotFirebaseApi? firebase})
    : firebase = firebase ?? LocalSpotFirebaseApi();

  final LocalSpotFirebaseApi firebase;

  /// Current Firebase UID, or null when not signed in.
  String? get token => firebase.token;

  Future<void> sendPasswordResetEmail(String email) =>
      firebase.sendPasswordResetEmail(email);

  Future<Map<String, dynamic>> updateProfile({
    required String name,
    String? photoUrl,
  }) => firebase.updateProfile(name: name, photoUrl: photoUrl);

  Future<dynamic> get(String path, [Map<String, String>? query]) =>
      firebase.get(path, query);

  Future<Map<String, dynamic>> getEnvelope(
    String path, [
    Map<String, String>? query,
  ]) => firebase.getEnvelope(path, query);

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) =>
      firebase.post(path, body);

  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) =>
      firebase.patch(path, body);

  Future<dynamic> delete(String path) => firebase.delete(path);
}
