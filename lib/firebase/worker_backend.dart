import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api.dart';

const _backendUrl = String.fromEnvironment('LOCALSPOT_BACKEND_URL');
const _useFirebaseEmulators = bool.fromEnvironment('USE_FIREBASE_EMULATORS');

bool workerBaseUrlAllowed(
  String value, {
  required bool debugBuild,
  required bool useFirebaseEmulators,
}) {
  final base = Uri.tryParse(value.trim());
  if (base == null ||
      !base.hasAuthority ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty ||
      base.query.isNotEmpty ||
      base.fragment.isNotEmpty ||
      (base.path.isNotEmpty && base.path != '/')) {
    return false;
  }
  if (debugBuild && useFirebaseEmulators && base.scheme == 'http') return true;
  if (base.scheme != 'https') return false;
  final host = base.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (!host.contains('.') ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host.endsWith('.localdomain') ||
      host.endsWith('.internal') ||
      host.endsWith('.intranet') ||
      host.endsWith('.home') ||
      host.endsWith('.home.arpa') ||
      host.endsWith('.corp') ||
      host.endsWith('.private') ||
      host.endsWith('.test') ||
      host.contains(':') ||
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
    return false;
  }
  return true;
}

class LocalSpotWorker {
  LocalSpotWorker._();

  // Profile hydration can be triggered by both startup and the auth screen.
  // Share one Play Integrity request and back off after provider throttling.
  static Future<String>? _appCheckTokenRequest;
  static DateTime? _appCheckRetryAfter;

  static bool get configured => _backendUrl.trim().isNotEmpty;

  static Future<Map<String, dynamic>> request(
    String path, [
    Map<String, dynamic> data = const {},
    String method = 'POST',
  ]) async {
    final base = Uri.tryParse(_backendUrl.trim());
    if (base == null ||
        !workerBaseUrlAllowed(
          _backendUrl,
          debugBuild: kDebugMode,
          useFirebaseEmulators: _useFirebaseEmulators,
        )) {
      throw ApiException('The Locentra backend URL is invalid.', status: 500);
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw ApiException('Sign in to continue.', status: 401);
    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw ApiException(
        'Firebase could not refresh the sign-in token.',
        status: 401,
      );
    }
    final String appCheckToken;
    if (kDebugMode && _useFirebaseEmulators) {
      // The local Worker checks for this header and accepts emulator Auth only
      // when its config is locked to the demo-localspot project.
      appCheckToken = 'local-emulator-test';
    } else {
      try {
        appCheckToken = await _getAppCheckToken();
      } catch (error) {
        final details =
            error is FirebaseException
                ? 'code=${error.code} message=${error.message ?? ''}'
                : 'type=${error.runtimeType}';
        debugPrint('[worker-auth] App Check token request failed $details');
        if (error is FirebaseException) {
          throw ApiException(
            'Device verification is temporarily unavailable or rate limited. Wait a few minutes, then retry registration.',
            status: 429,
          );
        }
        rethrow;
      }
    }
    final request = http.Request(method, base.resolve(path))
      ..headers.addAll({
        'Authorization': 'Bearer $idToken',
        'X-Firebase-AppCheck': 'Bearer $appCheckToken',
        'Content-Type': 'application/json',
      });
    if (method != 'GET') request.body = jsonEncode(data);
    final streamed = await request.send().timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamed);
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      debugPrint(
        '[worker-request] rejected method=$method path=$path '
        'status=${response.statusCode}',
      );
      final message =
          decoded is Map && decoded['error'] is String
              ? decoded['error'] as String
              : 'Request failed (${response.statusCode}).';
      throw ApiException(message, status: response.statusCode);
    }
    if (decoded is! Map) {
      throw ApiException(
        'The Worker returned an invalid response.',
        status: 502,
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  static Future<String> _getAppCheckToken() async {
    final retryAfter = _appCheckRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      throw ApiException(
        'Firebase App Check is temporarily rate limited. Wait a little, then retry.',
        status: 429,
      );
    }
    final active = _appCheckTokenRequest;
    if (active != null) return active;

    final request = _requestAppCheckToken();
    _appCheckTokenRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_appCheckTokenRequest, request)) {
        _appCheckTokenRequest = null;
      }
    }
  }

  static Future<String> _requestAppCheckToken() async {
    try {
      final token = await FirebaseAppCheck.instance.getToken(false);
      if (token == null || token.isEmpty) {
        throw ApiException(
          'Firebase App Check could not issue a token.',
          status: 401,
        );
      }
      _appCheckRetryAfter = null;
      return token;
    } catch (_) {
      _appCheckRetryAfter = DateTime.now().add(const Duration(seconds: 30));
      rethrow;
    }
  }
}
