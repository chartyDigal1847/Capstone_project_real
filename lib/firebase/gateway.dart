// LocalSpotGateway — trusted Laravel API gateway.
//
// Architecture: Flutter sends Firebase ID tokens to Laravel for ALL
// protected application operations. Laravel verifies the token, enforces
// authorization, and accesses Firestore through its server client (IAM/ADC).
//
// Flutter does NOT directly read or write Firestore business collections.
// Firebase Authentication and Firebase Storage SDK remain in Flutter (allowed
// exceptions per architecture rules).
//
// Offline behavior:
//   - GET /catalog and GET /search may be served from the in-memory cache
//     when previously loaded. The UI must clearly mark cached data as stale.
//   - All writes (POST, PATCH, DELETE for business data) require a successful
//     server response before the UI reports success. No silent write fallback.
//   - If Laravel is unreachable, an ApiException with status==0 is thrown.
//     The caller shows a clear error and a retry action.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../api.dart';
import 'laravel_client.dart';

/// Gateway exception indicating Laravel was unreachable (no server response).
class BackendUnreachableException extends ApiException {
  BackendUnreachableException([String? message])
      : super(
          message ??
              'Server is unreachable. Check your connection and try again.',
          status: 0,
        );
}

class LocalSpotGateway {
  LocalSpotGateway({LaravelApiClient? laravel, FirebaseAuth? auth})
      : _laravel = laravel ?? LaravelApiClient(),
        _authOverride = auth;

  final LaravelApiClient _laravel;
  final FirebaseAuth? _authOverride;

  // ── Read-only catalog cache for offline display ──────────────────────
  // Populated on a successful GET /catalog or GET /search.
  // Never used as a fallback for writes.
  Map<String, dynamic>? _catalogCache;
  Map<String, dynamic>? _searchCache;

  // Lazy getter — only accesses FirebaseAuth.instance after Firebase is initialized.
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  /// True when Firebase is initialised (Auth SDK is ready).
  bool get useFirebase => Firebase.apps.isNotEmpty;

  /// Current Firebase UID, or null when not signed in.
  String? get token => _auth.currentUser?.uid;

  // No-ops kept for API compatibility with AppState callers.
  Future<void> persistToken(String? value) async {}
  Future<void> restoreToken() async {}

  // ── Auth helpers ──────────────────────────────────────────────────────

  /// Sign in via Firebase Auth, then sync profile with Laravel.
  Future<Map<String, dynamic>> login(
      {required String email, required String password}) async {
    // Step 1: Firebase Auth (direct — allowed exception).
    final cred = await _auth.signInWithEmailAndPassword(
        email: email, password: password);
    if (cred.user == null) {
      throw ApiException('Sign-in failed. Please try again.');
    }
    // Step 2: Sync with Laravel to get role/permissions.
    // A fresh ID token is attached automatically by LaravelApiClient.
    try {
      return Map<String, dynamic>.from(
          await _laravel.post('/auth/login') as Map);
    } on ApiException catch (e) {
      if (_isUnreachable(e)) {
        // Firebase Auth succeeded but Laravel is unreachable.
        // Return minimal profile — user is signed in with Firebase but
        // backend permissions are unknown. The UI should show a warning.
        return _minimalProfile(cred.user!,
            note: 'Backend unreachable — permissions not loaded.');
      }
      // 4xx/5xx from server — re-throw so caller handles it.
      rethrow;
    }
  }

  /// Create a Firebase Auth account, syncing with Laravel.
  Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    required String role,
  }) async {
    // Step 1: Create Firebase Auth account.
    final cred = await _auth.createUserWithEmailAndPassword(
        email: email, password: password);
    await cred.user?.updateDisplayName(name);
    if (cred.user == null) {
      throw ApiException('Registration failed. Please try again.');
    }
    // Step 2: Sync with Laravel — required to create the Firestore profile.
    // Without this the user has no role/permissions.
    try {
      return Map<String, dynamic>.from(
          await _laravel.post('/auth/register', {'name': name, 'role': role})
              as Map);
    } on ApiException catch (e) {
      if (_isUnreachable(e)) {
        // Firebase account was created but the Firestore profile doesn't exist.
        // The user must try again when the server is reachable.
        await cred.user?.delete(); // Roll back Firebase account creation.
        throw BackendUnreachableException(
          'Account created in Firebase but the server was unreachable. '
          'Please check your connection and register again.',
        );
      }
      // 4xx/5xx from Laravel (validation etc.) — roll back Firebase account.
      try {
        await cred.user?.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Sign out via Firebase Auth.
  Future<void> logout() async {
    try {
      await _laravel.post('/auth/logout');
    } catch (_) {
      // Notify Laravel if possible, but always clear local session.
    }
    await _auth.signOut();
  }

  // ── Business reads — Laravel required, cache for offline display ──────

  Future<dynamic> get(String path, [Map<String, String>? query]) async {
    try {
      final result = await _laravel.get(path, query);
      // Cache successful catalog result.
      if (path == '/catalog' && result is Map) {
        _catalogCache = Map<String, dynamic>.from(result);
      }
      return result;
    } on ApiException catch (e) {
      if (_isUnreachable(e)) {
        // Serve stale catalog read-only if available.
        if (path == '/catalog' && _catalogCache != null) {
          return _staleMarker(_catalogCache!);
        }
        // For all other GET paths when unreachable, throw clearly.
        throw BackendUnreachableException();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getEnvelope(
      String path, [Map<String, String>? query]) async {
    try {
      final result = await _laravel.getEnvelope(path, query);
      // Cache last search result for offline stale display.
      if (path == '/search') {
        _searchCache = result;
      }
      return result;
    } on ApiException catch (e) {
      if (_isUnreachable(e)) {
        if (path == '/search' && _searchCache != null) {
          return _staleEnvelopeMarker(_searchCache!);
        }
        throw BackendUnreachableException();
      }
      rethrow;
    }
  }

  // ── Business writes — Laravel required, no silent fallback ───────────

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    if (path == '/auth/login' && body != null) {
      return login(
          email: body['email'] as String, password: body['password'] as String);
    }
    if (path == '/auth/register' && body != null) {
      return register(
        name: body['name'] as String,
        email: body['email'] as String,
        password: body['password'] as String,
        role: (body['role'] as String?) ?? 'customer',
      );
    }
    // All other writes MUST go through Laravel.
    // Do NOT fall back to direct Firestore.
    try {
      return await _laravel.post(path, body);
    } on ApiException catch (e) {
      if (_isUnreachable(e)) {
        throw BackendUnreachableException(
          'Could not reach the server. The action was not completed. '
          'Please check your connection and try again.',
        );
      }
      rethrow;
    }
  }

  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) async {
    try {
      return await _laravel.patch(path, body);
    } on ApiException catch (e) {
      if (_isUnreachable(e)) {
        throw BackendUnreachableException(
          'Could not reach the server. Changes were not saved. '
          'Please check your connection and try again.',
        );
      }
      rethrow;
    }
  }

  Future<dynamic> delete(String path) async {
    if (path == '/auth/logout') {
      await logout();
      return {'ok': true};
    }
    try {
      return await _laravel.delete(path);
    } on ApiException catch (e) {
      if (_isUnreachable(e)) {
        throw BackendUnreachableException(
          'Could not reach the server. The item was not deleted. '
          'Please check your connection and try again.',
        );
      }
      rethrow;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// True when the error means the server was unreachable (no HTTP response).
  static bool _isUnreachable(ApiException e) =>
      e.status == 0 || e.status == null;

  /// Add a stale marker to a map so the UI can display a cached banner.
  static Map<String, dynamic> _staleMarker(Map<String, dynamic> data) =>
      {...data, '_stale': true};

  static Map<String, dynamic> _staleEnvelopeMarker(
          Map<String, dynamic> envelope) =>
      {
        ...envelope,
        'meta': {
          ...((envelope['meta'] as Map<String, dynamic>?) ?? {}),
          '_stale': true,
        },
      };

  /// Build a minimal profile for when Laravel is reachable for auth but not
  /// for profile sync. Clearly marks permissions as unknown.
  static Map<String, dynamic> _minimalProfile(User user,
      {String note = ''}) {
    return {
      'user': {
        'id': user.uid.hashCode & 0x7fffffff,
        'name': user.displayName ?? '',
        'email': user.email ?? '',
        'role': 'customer', // Safest default — no elevated privileges
        'owned_store_ids': <int>[],
        'member_store_ids': <int>[],
        'store_grants': <Map<String, dynamic>>[],
        '_backend_unreachable': true,
        '_note': note,
      },
      'stores': <Map<String, dynamic>>[],
    };
  }
}
