// media_upload_service.dart — Firebase Storage quarantine upload flow.
//
// Target architecture (plan Wave 1): Flutter uploads media files ONLY to
// private, UID-scoped quarantine paths after Laravel authorizes an upload
// intent. Laravel verifies the upload, processes/controls publication, and
// only approved sanitized derivatives are delivered to customers.
//
// Flow:
//   1. Call Laravel uploadIntent() → get quarantine path + asset ID
//   2. Upload file to Firebase Storage at the quarantine path
//   3. Call Laravel finalizeUpload() → verify and queue processing
//   4. Return the asset ID for use in product/tour/store creation

import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'laravel_client.dart';

/// Result of a media upload through the quarantine flow.
class MediaUploadResult {
  final int assetId;
  final String quarantinePath;
  final String status;

  MediaUploadResult({
    required this.assetId,
    required this.quarantinePath,
    required this.status,
  });
}

/// Service that orchestrates the full media upload flow:
/// Laravel intent → Firebase Storage upload → Laravel finalize.
class MediaUploadService {
  MediaUploadService({LaravelApiClient? laravel, FirebaseStorage? storage})
      : _laravel = laravel ?? LaravelApiClient(),
        _storageOverride = storage;

  final LaravelApiClient _laravel;
  final FirebaseStorage? _storageOverride;

  // Lazy getter — only accesses FirebaseStorage.instance after Firebase is initialized.
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;

  /// Upload a product photo through the quarantine flow.
  ///
  /// [filePath] is the local file path from ImagePicker.
  /// [storeId] is the store the product belongs to (for ownership verification).
  /// Returns the asset ID and quarantine path.
  Future<MediaUploadResult> uploadProductPhoto({
    required String filePath,
    int? storeId,
  }) async {
    return _uploadFile(
      filePath: filePath,
      mediaType: 'product_photo',
      storeId: storeId,
    );
  }

  /// Upload a store image through the quarantine flow.
  Future<MediaUploadResult> uploadStoreImage({
    required String filePath,
    int? storeId,
  }) async {
    return _uploadFile(
      filePath: filePath,
      mediaType: 'store_image',
      storeId: storeId,
    );
  }

  /// Upload a 360° tour panorama through the quarantine flow.
  ///
  /// Panoramas are uploaded to quarantine and must go through server-side
  /// privacy processing before publication. The publication gate in the
  /// TourController blocks publication until processing succeeds.
  Future<MediaUploadResult> uploadTourPanorama({
    required String filePath,
    int? storeId,
  }) async {
    return _uploadFile(
      filePath: filePath,
      mediaType: 'tour_panorama',
      storeId: storeId,
    );
  }

  /// Get the processing status of a media asset.
  Future<Map<String, dynamic>> getStatus(int assetId) async {
    return _laravel.mediaStatus(assetId);
  }

  // ── Internal ──────────────────────────────────────────────────────────

  Future<MediaUploadResult> _uploadFile({
    required String filePath,
    required String mediaType,
    int? storeId,
  }) async {
    // Determine content type from file extension
    final ext = filePath.toLowerCase().split('.').last;
    final contentType = switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };

    // Step 1: Request upload intent from Laravel
    final intent = await _laravel.uploadIntent(
      mediaType: mediaType,
      contentType: contentType,
      storeId: storeId,
    );

    final assetId = intent['asset_id'] as int;
    final quarantinePath = intent['quarantine_path'] as String;

    // Step 2: Upload to Firebase Storage at the quarantine path
    final file = File(filePath);
    final uploadTask = _storage.ref(quarantinePath).putFile(
      file,
      SettableMetadata(contentType: contentType),
    );

    // Wait for upload to complete
    final snapshot = await uploadTask;
    final sizeBytes = snapshot.metadata?.size ?? 0;

    // Step 3: Call Laravel finalize to verify and queue processing
    final result = await _laravel.finalizeUpload(
      assetId: assetId,
      objectPath: quarantinePath,
      contentType: contentType,
      sizeBytes: sizeBytes,
    );

    debugPrint('Media uploaded: asset=$assetId, path=$quarantinePath, status=${result['status']}');

    return MediaUploadResult(
      assetId: assetId,
      quarantinePath: quarantinePath,
      status: result['status'] as String? ?? 'pending_review',
    );
  }
}
