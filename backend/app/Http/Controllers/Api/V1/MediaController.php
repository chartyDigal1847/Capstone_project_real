<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

/**
 * Media upload intent controller — Cloud Storage quarantine flow.
 *
 * Target architecture (plan Wave 1):
 *   1. Flutter requests an upload intent from Laravel (this controller).
 *   2. Laravel verifies the user and store permissions, creates a mediaAssets
 *      record with status 'pending_upload', and returns the scoped quarantine path.
 *   3. Flutter uploads the file to the private quarantine path via Firebase Storage SDK.
 *   4. Flutter calls the finalize endpoint.
 *   5. Laravel verifies the uploaded object metadata and queues processing.
 *
 * Storage Rules enforce UID-scoped quarantine paths; Laravel separately verifies
 * store ownership before processing. Never accept a client-supplied path or
 * published flag as proof of authorization.
 */
class MediaController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    /**
     * Create an upload intent for a private quarantine path.
     * POST /api/v1/media/upload-intent
     */
    public function uploadIntent(Request $request)
    {
        $user = $this->userResolver->resolve($request);
        $uid = $request->attributes->get('firebase_uid');

        $data = $request->validate([
            'media_type' => ['required', Rule::in(['product_photo', 'store_image', 'tour_panorama'])],
            'store_id' => ['nullable', 'integer'],
            'content_type' => ['required', 'string', 'in:image/jpeg,image/png,image/webp'],
        ]);

        // For store-specific media, verify ownership
        if (! empty($data['store_id'])) {
            abort_unless(
                $this->userResolver->canManageStore($user, (int) $data['store_id']),
                403,
                'Not authorized to upload media for this store.'
            );
        }

        // Build the quarantine path: quarantine/{uid}/{type}/{uploadId}/original.{ext}
        $ext = match ($data['content_type']) {
            'image/png' => 'png',
            'image/webp' => 'webp',
            default => 'jpg',
        };

        $uploadId = uniqid('upload_', true);
        $typeDir = match ($data['media_type']) {
            'product_photo' => 'products',
            'store_image' => 'stores',
            'tour_panorama' => 'tours',
        };

        $quarantinePath = "quarantine/{$uid}/{$typeDir}/{$uploadId}/original.{$ext}";

        // Size limits by type
        $maxSize = match ($data['media_type']) {
            'tour_panorama' => 50 * 1024 * 1024,  // 50 MB
            default => 10 * 1024 * 1024,           // 10 MB
        };

        // Create a mediaAssets record in Firestore
        $assetId = abs(crc32($uploadId)) & 0x7fffffff;
        $this->firestore->create('mediaAssets', [
            'numericId' => $assetId,
            'uploadId' => $uploadId,
            'uid' => $uid,
            'storeId' => $data['store_id'] ?? null,
            'mediaType' => $data['media_type'],
            'quarantinePath' => $quarantinePath,
            'contentType' => $data['content_type'],
            'maxSizeBytes' => $maxSize,
            'status' => 'pending_upload',
            'createdAt' => now()->toIso8601String(),
        ]);

        return response()->json([
            'data' => [
                'asset_id' => $assetId,
                'upload_id' => $uploadId,
                'quarantine_path' => $quarantinePath,
                'content_type' => $data['content_type'],
                'max_size_bytes' => $maxSize,
            ],
        ], 201);
    }

    /**
     * Verify an uploaded object and queue processing.
     * POST /api/v1/media/{id}/finalize
     */
    public function finalize(Request $request, int $assetId)
    {
        $user = $this->userResolver->resolve($request);
        $uid = $request->attributes->get('firebase_uid');

        $asset = $this->firestore->findByNumericId('mediaAssets', $assetId);
        abort_if($asset === null, 404, 'Upload intent not found.');
        abort_unless(($asset['uid'] ?? '') === $uid, 403, 'Not authorized for this upload.');

        $data = $request->validate([
            'object_path' => ['required', 'string'],
            'content_type' => ['required', 'string'],
            'size_bytes' => ['required', 'integer', 'min:1'],
        ]);

        // Verify the object path matches the authorized quarantine path
        $expectedPath = $asset['quarantinePath'] ?? '';
        abort_unless(
            $data['object_path'] === $expectedPath,
            422,
            'Object path does not match the authorized upload intent.'
        );

        // Verify size is within limits
        $maxSize = $asset['maxSizeBytes'] ?? (10 * 1024 * 1024);
        abort_unless(
            $data['size_bytes'] <= $maxSize,
            422,
            'File exceeds the authorized size limit.'
        );

        // Update the mediaAssets record to 'uploaded' / 'processing'
        $this->firestore->updateByNumericId('mediaAssets', $assetId, [
            'status' => 'uploaded',
            'objectPath' => $data['object_path'],
            'actualSizeBytes' => $data['size_bytes'],
            'uploadedAt' => now()->toIso8601String(),
        ]);

        // Queue processing based on media type
        $mediaType = $asset['mediaType'] ?? '';
        $processingStatus = match ($mediaType) {
            'tour_panorama' => 'pending_privacy_processing',
            'product_photo' => 'pending_review',
            'store_image' => 'pending_review',
            default => 'pending_review',
        };

        $this->firestore->updateByNumericId('mediaAssets', $assetId, [
            'status' => $processingStatus,
        ]);

        return response()->json([
            'data' => [
                'asset_id' => $assetId,
                'status' => $processingStatus,
            ],
        ]);
    }

    /**
     * Get the status of a media asset.
     * GET /api/v1/media/{id}/status
     */
    public function status(Request $request, int $assetId)
    {
        $user = $this->userResolver->resolve($request);
        $uid = $request->attributes->get('firebase_uid');

        $asset = $this->firestore->findByNumericId('mediaAssets', $assetId);
        abort_if($asset === null, 404, 'Media asset not found.');
        abort_unless(
            ($asset['uid'] ?? '') === $uid || UserResolver::isAdmin($user),
            403,
            'Not authorized.'
        );

        return response()->json([
            'data' => [
                'asset_id' => $assetId,
                'status' => $asset['status'] ?? 'unknown',
                'media_type' => $asset['mediaType'] ?? '',
                'quarantine_path' => $asset['quarantinePath'] ?? '',
                'created_at' => $asset['createdAt'] ?? null,
                'uploaded_at' => $asset['uploadedAt'] ?? null,
            ],
        ]);
    }
}
