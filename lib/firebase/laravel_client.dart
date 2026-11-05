// laravel_client.dart — HTTP client for the Laravel REST API.
//
// In the target architecture, Flutter does NOT directly read or write
// Firestore business collections. Instead it calls Laravel API endpoints
// with a Firebase ID token as `Authorization: Bearer <token>`. Laravel
// verifies the token, enforces authorization, and accesses Firestore
// through its server client (IAM/ADC).
//
// This client wraps `dio` and handles:
//   - Attaching a refreshed Firebase ID token to every request
//   - Unwrapping Laravel's `{data: ...}` response envelope
//   - Converting HTTP errors to ApiException
//   - Environment-specific base URL configuration

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../api.dart';

// ── API base URL configuration ────────────────────────────────────────
//
// Configure the correct URL at build time using --dart-define:
//
//   flutter run --dart-define=LARAVEL_API_URL=http://192.168.1.X:8000/api/v1
//
// OR set it in your IDE launch configuration / .vscode/launch.json:
//   "args": ["--dart-define=LARAVEL_API_URL=http://10.0.2.2:8000/api/v1"]
//
// Default values by environment:
//   Android emulator → host machine: http://10.0.2.2:8000/api/v1
//   Physical device on LAN:          use --dart-define to pass your LAN IP
//   Production:                       https://api.localspot.ph/api/v1 (HTTPS)
//
// NEVER hard-code a developer's LAN IP as the production API URL.

/// Base URL resolved from --dart-define at build time.
/// Falls back to the Android emulator host address (10.0.2.2).
const kLaravelApiUrl = String.fromEnvironment(
  'LARAVEL_API_URL',
  defaultValue: 'http://10.0.2.2:8000/api/v1',
);

// ── Timeout configuration ─────────────────────────────────────────────
//
// Development: shorter timeouts acceptable (server on the same machine).
// Production:  longer timeouts to handle real network latency.
//
// connectTimeout: max time to establish the TCP connection.
// receiveTimeout: max time to receive a complete HTTP response after connecting.
//
// Note: 2-second connect timeout is too aggressive for production (mobile
// networks, cold-start servers). Use the defaults below unless overridden.

const _kConnectTimeoutDev = Duration(seconds: 5);
const _kReceiveTimeoutDev = Duration(seconds: 20);
const _kConnectTimeoutProd = Duration(seconds: 15);
const _kReceiveTimeoutProd = Duration(seconds: 30);

Duration get _connectTimeout => const bool.fromEnvironment('dart.vm.product')
    ? _kConnectTimeoutProd
    : _kConnectTimeoutDev;

Duration get _receiveTimeout => const bool.fromEnvironment('dart.vm.product')
    ? _kReceiveTimeoutProd
    : _kReceiveTimeoutDev;

class LaravelApiClient {
  LaravelApiClient({String? baseUrl, FirebaseAuth? auth})
      : _authOverride = auth,
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? kLaravelApiUrl,
          connectTimeout: _connectTimeout,
          receiveTimeout: _receiveTimeout,
          headers: {'Accept': 'application/json'},
        ));

  final Dio _dio;
  final FirebaseAuth? _authOverride;

  // Lazy getter — only accesses FirebaseAuth.instance after Firebase is initialized.
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  /// Returns true when a Firebase user is signed in (ID token available).
  bool get isAuthenticated => _auth.currentUser != null;

  /// Current Firebase UID, or null when not signed in.
  String? get uid => _auth.currentUser?.uid;

  /// Get a fresh Firebase ID token for the Bearer header. Returns an
  /// empty map (no auth header) when the user is not signed in, so
  /// public endpoints like /catalog work without authentication.
  Future<Map<String, dynamic>> _headers() async {
    final user = _auth.currentUser;
    if (user == null) {
      return {};  // No auth header — public endpoints still work.
    }
    // forceRefresh: false — Firebase SDK refreshes automatically before expiry.
    final token = await user.getIdToken();
    return {'Authorization': 'Bearer $token'};
  }

  /// GET request — unwraps `{data: ...}` envelope.
  Future<dynamic> get(String path, [Map<String, String>? query]) async {
    try {
      final response = await _dio.get(
        path,
        queryParameters: query,
        options: Options(headers: await _headers()),
      );
      return _unwrap(response.data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  /// GET request — returns the full envelope including `data` and `meta`.
  Future<Map<String, dynamic>> getEnvelope(
      String path, [Map<String, String>? query]) async {
    try {
      final response = await _dio.get(
        path,
        queryParameters: query,
        options: Options(headers: await _headers()),
      );
      final body = response.data;
      if (body is Map<String, dynamic>) return body;
      return {'data': body, 'meta': {}};
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  /// POST request — unwraps `{data: ...}` envelope.
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    try {
      final response = await _dio.post(
        path,
        data: body,
        options: Options(headers: await _headers()),
      );
      return _unwrap(response.data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  /// PATCH request — unwraps `{data: ...}` envelope.
  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) async {
    try {
      final response = await _dio.patch(
        path,
        data: body,
        options: Options(headers: await _headers()),
      );
      return _unwrap(response.data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  /// DELETE request — unwraps `{data: ...}` envelope.
  Future<dynamic> delete(String path) async {
    try {
      final response = await _dio.delete(
        path,
        options: Options(headers: await _headers()),
      );
      return _unwrap(response.data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  // ── Media upload intent methods ──────────────────────────────────────
  //
  // Flow: Flutter requests an upload intent → Laravel returns a scoped
  // quarantine path → Flutter uploads via Firebase Storage SDK → Flutter
  // calls finalize → Laravel verifies and queues processing.

  /// Request a media upload intent from Laravel.
  /// Returns: {asset_id, upload_id, quarantine_path, content_type, max_size_bytes}
  Future<Map<String, dynamic>> uploadIntent({
    required String mediaType,
    required String contentType,
    int? storeId,
  }) async {
    final body = <String, dynamic>{
      'media_type': mediaType,
      'content_type': contentType,
    };
    if (storeId != null) body['store_id'] = storeId;
    final result = await post('/media/upload-intent', body);
    return Map<String, dynamic>.from(result as Map);
  }

  /// Finalize an upload after the file has been uploaded to the quarantine path.
  /// Returns: {asset_id, status}
  Future<Map<String, dynamic>> finalizeUpload({
    required int assetId,
    required String objectPath,
    required String contentType,
    required int sizeBytes,
  }) async {
    final result = await post('/media/$assetId/finalize', {
      'object_path': objectPath,
      'content_type': contentType,
      'size_bytes': sizeBytes,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Get the processing status of a media asset.
  /// Returns: {asset_id, status, media_type, quarantine_path, created_at, uploaded_at}
  Future<Map<String, dynamic>> mediaStatus(int assetId) async {
    final result = await get('/media/$assetId/status');
    return Map<String, dynamic>.from(result as Map);
  }

  // ── Private helpers ──────────────────────────────────────────────────

  /// Unwrap Laravel's `{data: ...}` response envelope.
  dynamic _unwrap(dynamic body) {
    if (body is Map<String, dynamic> && body.containsKey('data')) {
      return body['data'];
    }
    return body;
  }

  /// Convert a DioException to an ApiException with a useful message.
  ApiException _toApiException(DioException e) {
    final status = e.response?.statusCode ?? 0;
    final body = e.response?.data;

    // Map Dio error types to human-readable messages.
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.connectionError) {
      return ApiException(
        'Cannot connect to the server. Check that the app is using the '
        'correct API address and that the server is running.',
        status: 0,
      );
    }
    if (e.type == DioExceptionType.receiveTimeout) {
      return ApiException(
        'The server took too long to respond. Please try again.',
        status: 0,
      );
    }
    if (e.type == DioExceptionType.sendTimeout) {
      return ApiException(
        'The request timed out while sending data. Check your connection.',
        status: 0,
      );
    }

    // Server responded with an error status.
    if (status == 401) {
      return ApiException.fromResponse(status, body).copyWith(
        fallbackMessage: 'Your session has expired. Please sign in again.',
      );
    }
    if (status == 403) {
      return ApiException.fromResponse(status, body).copyWith(
        fallbackMessage: 'You do not have permission to perform this action.',
      );
    }
    if (status == 404) {
      return ApiException.fromResponse(status, body).copyWith(
        fallbackMessage: 'The requested item was not found.',
      );
    }
    if (status == 422) {
      return ApiException.fromResponse(status, body);
    }
    if (status == 429) {
      return ApiException.fromResponse(status, body).copyWith(
        fallbackMessage: 'Too many requests. Please wait a moment and try again.',
      );
    }
    if (status >= 500) {
      return ApiException.fromResponse(status, body).copyWith(
        fallbackMessage: 'The server encountered an error. Please try again later.',
      );
    }

    return ApiException.fromResponse(status, body);
  }
}
