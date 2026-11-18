import 'dart:io';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import 'build_mode.dart';
import 'worker_backend.dart';

class UploadedMedia {
  const UploadedMedia({required this.assetId, this.downloadUrl});

  final String assetId;
  final String? downloadUrl;
}

class MediaUpload {
  MediaUpload._();

  static final _functions = FirebaseFunctions.instanceFor(
    region: 'asia-southeast1',
  );

  static Future<Map<String, dynamic>> _backendCall(
    String functionName,
    String workerRoute,
    Map<String, dynamic> data,
  ) async {
    if (LocalSpotWorker.configured) {
      return LocalSpotWorker.request(workerRoute, data);
    }
    final result = await _functions.httpsCallable(functionName).call(data);
    return Map<String, dynamic>.from(result.data as Map);
  }

  static String createAssetId() {
    final suffix = Random.secure()
        .nextInt(1 << 32)
        .toRadixString(16)
        .padLeft(8, '0');
    return '${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }

  static Future<UploadedMedia> uploadAndWait(
    XFile image, {
    required String kind,
    void Function(double value)? onProgress,
  }) async {
    if (localSpotPreviewRelease) {
      throw StateError('Media uploads are disabled in the free preview.');
    }
    if (kind != 'product' && kind != 'store') {
      throw ArgumentError.value(kind, 'kind');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in before uploading a photo.');
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw StateError('Choose an image smaller than 8 MiB.');
    }
    final format = _format(bytes);
    if (format == null) throw StateError('Use a JPEG, PNG, or WebP image.');

    final assetId = createAssetId();
    final reservation = await _reserve({
      'mediaType': kind,
      'assetId': assetId,
      'contentType': format.$1,
      'expectedBytes': bytes.length,
    });
    await _upload(reservation, bytes, format.$1, onProgress);
    final result = await _backendCall(
      'finalizeMediaUpload',
      '/api/v1/media/finalize',
      {'reservationId': reservation['reservationId']},
    );
    if (result['status'] != 'ready' ||
        result['assetId'] != assetId ||
        (kind == 'product' && result['downloadUrl'] is! String)) {
      throw StateError(
        'The photo could not be processed. Choose another image or try again.',
      );
    }
    return UploadedMedia(
      assetId: assetId,
      downloadUrl: result['downloadUrl'] as String?,
    );
  }

  static Future<String> uploadPanorama(
    XFile image, {
    required int tourId,
    required String assetId,
    void Function(double value)? onProgress,
  }) async {
    if (localSpotPreviewRelease) {
      throw StateError('Panorama uploads are disabled in the free preview.');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in before uploading a panorama.');
    final fileBytes = await image.length();
    if (fileBytes <= 0 || fileBytes > 50 * 1024 * 1024) {
      throw StateError('Choose a panorama smaller than 50 MiB.');
    }
    final signature = await image
        .openRead(0, 3)
        .fold<List<int>>(<int>[], (out, chunk) => out..addAll(chunk));
    if (signature.length < 3 ||
        signature[0] != 0xff ||
        signature[1] != 0xd8 ||
        signature[2] != 0xff) {
      throw StateError('Panorama uploads currently support JPEG images only.');
    }

    final reservation = await _reserve({
      'mediaType': 'panorama',
      'assetId': assetId,
      'tourId': tourId,
      'contentType': 'image/jpeg',
      'expectedBytes': fileBytes,
    });
    await _uploadStream(
      reservation,
      image.openRead(),
      fileBytes,
      'image/jpeg',
      onProgress,
    );
    final result = await _backendCall(
      'finalizeMediaUpload',
      '/api/v1/media/finalize',
      {'reservationId': reservation['reservationId']},
    );
    if (result['status'] != 'awaiting-privacy-processing' ||
        result['assetId'] != assetId ||
        result['originalPath'] is! String) {
      throw StateError(
        'The panorama could not be verified. Try uploading it again.',
      );
    }
    return result['originalPath'] as String;
  }

  static Future<Map<String, dynamic>> uploadPanoramaDerivative(
    File derivative, {
    required int tourId,
    required int nodeId,
    required String assetId,
    required String derivativeSha256,
    required String processingVersion,
    void Function(double value)? onProgress,
  }) async {
    if (localSpotPreviewRelease) {
      throw StateError('Panorama uploads are disabled in the free preview.');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Sign in before uploading a panorama derivative.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(derivativeSha256)) {
      throw StateError('The processed derivative digest is invalid.');
    }
    final fileBytes = await derivative.length();
    if (fileBytes <= 0 || fileBytes > 50 * 1024 * 1024) {
      throw StateError(
        'The processed derivative must be no larger than 50 MiB.',
      );
    }
    final head = await derivative
        .openRead(0, 3)
        .fold<List<int>>(<int>[], (out, chunk) => out..addAll(chunk));
    if (head.length < 3 ||
        head[0] != 0xff ||
        head[1] != 0xd8 ||
        head[2] != 0xff) {
      throw StateError('The processed derivative is not a JPEG image.');
    }
    final reservation = await _backendCall(
      'reservePanoramaDerivativeUpload',
      '/api/v1/media/panorama-derivative/reservations',
      {
        'tourId': tourId,
        'nodeId': nodeId,
        'assetId': assetId,
        'contentType': 'image/jpeg',
        'expectedBytes': fileBytes,
        'derivativeSha256': derivativeSha256,
        'processingVersion': processingVersion,
      },
    );
    for (final key in [
      'reservationId',
      'uploadUrl',
      'uploadToken',
      'objectKey',
    ]) {
      if (reservation[key] is! String) {
        throw StateError('The derivative reservation response is invalid.');
      }
    }
    await _uploadStream(
      reservation,
      derivative.openRead(),
      fileBytes,
      'image/jpeg',
      onProgress,
    );
    final result = await _backendCall(
      'finalizePanoramaDerivativeUpload',
      '/api/v1/media/panorama-derivative/finalize',
      {'reservationId': reservation['reservationId']},
    );
    if (result['status'] != 'verified' ||
        result['objectKey'] != reservation['objectKey'] ||
        result['sha256'] != derivativeSha256 ||
        result['contentType'] != 'image/jpeg' ||
        result['accountingState'] != 'counted') {
      throw StateError(
        'The backend did not verify and account for the derivative.',
      );
    }
    return result;
  }

  static Future<Map<String, dynamic>> _reserve(Map<String, Object> data) async {
    try {
      final result = await _backendCall(
        'reserveMediaUpload',
        '/api/v1/media/reservations',
        Map<String, dynamic>.from(data),
      );
      for (final key in ['reservationId', 'uploadUrl', 'uploadToken']) {
        if (result[key] is! String) {
          throw StateError('The upload reservation response is invalid.');
        }
      }
      return result;
    } on FirebaseFunctionsException catch (error) {
      if (error.message?.contains('STORAGE_LIMIT_REACHED') == true ||
          error.code == 'resource-exhausted') {
        throw StateError(
          'Storage is full or temporarily unavailable. Delete unused media or contact an administrator.',
        );
      }
      rethrow;
    } on ApiException catch (error) {
      if (error.message.contains('STORAGE_LIMIT_REACHED') ||
          error.status == 429) {
        throw StateError(
          'Storage is full or temporarily unavailable. Delete unused media or contact an administrator.',
        );
      }
      rethrow;
    }
  }

  static Future<void> _upload(
    Map<String, dynamic> reservation,
    List<int> bytes,
    String contentType,
    void Function(double value)? onProgress,
  ) async {
    await _uploadStream(
      reservation,
      Stream<List<int>>.fromIterable(_chunks(bytes)),
      bytes.length,
      contentType,
      onProgress,
    );
  }

  static Iterable<List<int>> _chunks(List<int> bytes) sync* {
    const chunkSize = 256 * 1024;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = min(offset + chunkSize, bytes.length);
      yield bytes.sublist(offset, end);
    }
  }

  static Future<void> _uploadStream(
    Map<String, dynamic> reservation,
    Stream<List<int>> source,
    int contentLength,
    String contentType,
    void Function(double value)? onProgress,
  ) async {
    final uri = Uri.parse(reservation['uploadUrl'] as String);
    final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Your sign-in expired. Sign in again before uploading.');
    }
    final request =
        http.StreamedRequest('PUT', uri)
          ..contentLength = contentLength
          ..headers['Content-Type'] = contentType
          ..headers['Authorization'] = 'Bearer $idToken'
          ..headers['X-Upload-Authorization'] =
              'Bearer ${reservation['uploadToken']}';
    final client = http.Client();
    try {
      final responseFuture = client.send(request);
      var sent = 0;
      await for (final chunk in source) {
        sent += chunk.length;
        if (sent > contentLength) {
          throw StateError('The file changed while it was being uploaded.');
        }
        request.sink.add(chunk);
        onProgress?.call(sent / contentLength);
      }
      if (sent != contentLength) {
        throw StateError('The file changed while it was being uploaded.');
      }
      await request.sink.close();
      final response = await responseFuture.timeout(const Duration(minutes: 3));
      final responseBody = await response.stream.bytesToString();
      if (response.statusCode != 201) {
        if (response.statusCode == 413) {
          throw StateError('The upload exceeded its reserved size.');
        }
        throw StateError(
          'The image upload failed (${response.statusCode}). $responseBody',
        );
      }
    } finally {
      client.close();
    }
  }

  static (String, String)? _format(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return ('image/jpeg', 'jpg');
    }
    const png = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length >= png.length &&
        List.generate(png.length, (i) => bytes[i]).toString() ==
            png.toString()) {
      return ('image/png', 'png');
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return ('image/webp', 'webp');
    }
    return null;
  }
}
