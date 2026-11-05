<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\CloudStorageObjectNotFound;
use App\Services\CloudStorageService;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use App\Support\CatalogCache;
use Illuminate\Http\Request;

/**
 * Tour controller — Firestore-backed.
 *
 * Tours are stored as Firestore documents with an embedded `nodes` array.
 * Privacy processing status is tracked per node. Publication is blocked
 * until every node has a sanitized derivative and owner review.
 *
 * Private uploads can be verified, but actual person/face detection and
 * sanitized derivative generation are pending (plan Wave 3).
 */
class TourController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
        private readonly CloudStorageService $storage,
    ) {
    }

    public function store(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        $store = $this->firestore->findByNumericId('stores', $storeId);
        abort_if($store === null, 404, 'Store not found.');
        abort_unless($this->userResolver->canManageStore($user, $storeId), 403, 'Not authorized.');

        $data = $request->validate(['title' => ['required', 'string', 'max:160']]);

        $id = abs(crc32(uniqid('tour', true))) & 0x7fffffff;
        $this->firestore->create('tours', [
            'numericId' => $id,
            'storeId' => $storeId,
            'title' => $data['title'],
            'status' => 'draft',
            'nodes' => [],
            'ownerUid' => $request->attributes->get('firebase_uid'),
        ]);

        return response()->json(['data' => ['id' => $id, 'store_id' => $storeId, 'title' => $data['title'], 'status' => 'draft', 'nodes' => []]], 201);
    }

    public function addNode(Request $request, int $tourId)
    {
        $user = $this->userResolver->resolve($request);
        $tour = $this->firestore->findByNumericId('tours', $tourId);
        abort_if($tour === null, 404, 'Tour not found.');
        abort_unless($this->userResolver->canManageStore($user, $tour['storeId'] ?? 0), 403, 'Not authorized.');

        $data = $request->validate([
            'title' => ['required', 'string', 'max:120'],
            'media_asset_id' => ['required', 'integer'],
        ]);

        $asset = $this->firestore->findByNumericId('mediaAssets', (int) $data['media_asset_id']);
        abort_if($asset === null, 404, 'Panorama upload was not found.');
        abort_unless(
            ($asset['uid'] ?? '') === $request->attributes->get('firebase_uid') &&
            (int) ($asset['storeId'] ?? 0) === (int) ($tour['storeId'] ?? 0) &&
            ($asset['mediaType'] ?? '') === 'tour_panorama' &&
            ($asset['status'] ?? '') === 'pending_privacy_processing',
            422,
            'Panorama upload is not authorized or has not completed successfully.'
        );

        $nodes = $tour['nodes'] ?? [];
        $nodeId = count($nodes) + 1;
        $nodes[] = [
            'id' => $nodeId,
            'title' => $data['title'],
            'image' => '',
            'media_asset_id' => (int) $data['media_asset_id'],
            'connections' => empty($nodes) ? [] : [count($nodes)],
            'privacy_status' => 'processing',
            'owner_reviewed' => false,
            'manual_blur' => false,
            'original_retained' => true,
            'blur_regions' => [],
        ];

        // Link previous node back to this one
        if (count($nodes) >= 2) {
            $prev = $nodes[count($nodes) - 2];
            $prev['connections'] = array_unique([...($prev['connections'] ?? []), $nodeId]);
            $nodes[count($nodes) - 2] = $prev;
        }

        $this->firestore->updateByNumericId('tours', $tourId, ['nodes' => $nodes]);
        $tour['nodes'] = $nodes;

        return response()->json(['data' => $this->tourJson($tour)]);
    }

    public function connect(Request $request, int $tourId)
    {
        $user = $this->userResolver->resolve($request);
        $tour = $this->firestore->findByNumericId('tours', $tourId);
        abort_if($tour === null, 404, 'Tour not found.');
        abort_unless($this->userResolver->canManageStore($user, $tour['storeId'] ?? 0), 403, 'Not authorized.');

        $data = $request->validate([
            'from_node_id' => ['required', 'integer'],
            'to_node_id' => ['required', 'integer', 'different:from_node_id'],
        ]);

        $nodes = $tour['nodes'] ?? [];
        foreach ($nodes as &$node) {
            if (($node['id'] ?? 0) === (int) $data['from_node_id']) {
                $node['connections'] = array_unique([...($node['connections'] ?? []), (int) $data['to_node_id']]);
            }
            if (($node['id'] ?? 0) === (int) $data['to_node_id']) {
                $node['connections'] = array_unique([...($node['connections'] ?? []), (int) $data['from_node_id']]);
            }
        }
        unset($node);

        $this->firestore->updateByNumericId('tours', $tourId, ['nodes' => $nodes]);
        $tour['nodes'] = $nodes;

        return response()->json(['data' => $this->tourJson($tour)]);
    }

    public function publish(Request $request, int $tourId)
    {
        $user = $this->userResolver->resolve($request);
        $tour = $this->firestore->findByNumericId('tours', $tourId);
        abort_if($tour === null, 404, 'Tour not found.');
        abort_unless($this->userResolver->canManageStore($user, $tour['storeId'] ?? 0), 403, 'Not authorized.');

        $nodes = $tour['nodes'] ?? [];
        abort_if(count($nodes) < 2, 422, 'Connect at least two viewpoints before publishing.');

        foreach ($nodes as $node) {
            $status = $node['privacy_status'] ?? 'processing';
            $reviewed = $node['owner_reviewed'] ?? false;
            $image = $node['image'] ?? '';
            abort_if($status !== 'ready', 422, 'Every viewpoint needs privacy processing before publishing.');
            abort_if(!$reviewed, 422, 'Every viewpoint needs owner review before publishing.');
            abort_if($image === '', 422, 'Every viewpoint needs a sanitized derivative before publishing.');

            $publicPath = ltrim($image, '/');
            abort_unless(
                str_starts_with($publicPath, 'tours/public/' . ($tour['storeId'] ?? 0) . '/'),
                422,
                'Every viewpoint must use an approved sanitized Storage derivative.'
            );

            try {
                $object = $this->storage->inspectObject($publicPath);
            } catch (CloudStorageObjectNotFound $e) {
                abort(422, 'A sanitized panorama derivative is missing from Cloud Storage.');
            } catch (\Throwable $e) {
                report($e);
                return response()->json(['message' => 'Cloud Storage could not verify the panorama derivative. Please try again.'], 503);
            }

            abort_unless(str_starts_with($object['content_type'], 'image/'), 422, 'Panorama derivative is not a supported image.');
        }

        $this->firestore->updateByNumericId('tours', $tourId, [
            'status' => 'published',
            'privacy_verified' => true,
        ]);
        $tour['status'] = 'published';
        $tour['privacy_verified'] = true;

        // Invalidate catalog and store caches since published tours appear in catalog.
        CatalogCache::invalidateTour($tour['storeId'] ?? 0);

        return response()->json(['data' => $this->tourJson($tour)]);
    }

    public function reviewNode(Request $request, int $tourId, int $nodeId)
    {
        $user = $this->userResolver->resolve($request);
        $tour = $this->firestore->findByNumericId('tours', $tourId);
        abort_if($tour === null, 404, 'Tour not found.');
        abort_unless($this->userResolver->canManageStore($user, $tour['storeId'] ?? 0), 403, 'Not authorized.');

        $nodes = $tour['nodes'] ?? [];
        $found = false;
        foreach ($nodes as &$node) {
            if (($node['id'] ?? 0) === $nodeId) {
                abort_if(($node['privacy_status'] ?? '') !== 'ready', 422, 'Privacy processing must finish before review.');
                abort_if(($node['image'] ?? '') === '', 422, 'A sanitized image is required before review.');
                $node['owner_reviewed'] = true;
                $found = true;
                break;
            }
        }
        unset($node);
        abort_if(!$found, 404, 'Node not found.');

        $this->firestore->updateByNumericId('tours', $tourId, ['nodes' => $nodes]);
        $tour['nodes'] = $nodes;

        return response()->json(['data' => $this->tourJson($tour)]);
    }

    public function addManualBlur(Request $request, int $tourId, int $nodeId)
    {
        $user = $this->userResolver->resolve($request);
        $tour = $this->firestore->findByNumericId('tours', $tourId);
        abort_if($tour === null, 404, 'Tour not found.');
        abort_unless($this->userResolver->canManageStore($user, $tour['storeId'] ?? 0), 403, 'Not authorized.');

        $data = $request->validate([
            'regions' => ['nullable', 'array', 'max:32'],
            'regions.*.x' => ['required_with:regions', 'numeric', 'between:0,1'],
            'regions.*.y' => ['required_with:regions', 'numeric', 'between:0,1'],
            'regions.*.w' => ['required_with:regions', 'numeric', 'gt:0', 'max:1'],
            'regions.*.h' => ['required_with:regions', 'numeric', 'gt:0', 'max:1'],
        ]);

        $regions = $data['regions'] ?? [['x' => 0.35, 'y' => 0.35, 'w' => 0.3, 'h' => 0.3]];

        $nodes = $tour['nodes'] ?? [];
        $found = false;
        foreach ($nodes as &$node) {
            if (($node['id'] ?? 0) === $nodeId) {
                $node['manual_blur'] = true;
                $node['blur_regions'] = array_merge($node['blur_regions'] ?? [], $regions);
                $found = true;
                break;
            }
        }
        unset($node);
        abort_if(!$found, 404, 'Node not found.');

        $this->firestore->updateByNumericId('tours', $tourId, ['nodes' => $nodes]);
        $tour['nodes'] = $nodes;

        return response()->json(['data' => $this->tourJson($tour)]);
    }

    public function processNode(Request $request, int $tourId, int $nodeId)
    {
        $user = $this->userResolver->resolve($request);
        $tour = $this->firestore->findByNumericId('tours', $tourId);
        abort_if($tour === null, 404, 'Tour not found.');
        abort_unless($this->userResolver->canManageStore($user, $tour['storeId'] ?? 0), 403, 'Not authorized.');
        abort(503, 'Panorama privacy processing is not configured yet. The viewpoint remains private.');
    }

    public function addHotspot(Request $request, int $tourId, int $nodeId)
    {
        $user = $this->userResolver->resolve($request);
        $tour = $this->firestore->findByNumericId('tours', $tourId);
        abort_if($tour === null, 404, 'Tour not found.');
        abort_unless($this->userResolver->canManageStore($user, $tour['storeId'] ?? 0), 403, 'Not authorized.');

        $data = $request->validate([
            'product_id' => ['required', 'integer'],
            'x' => ['required', 'numeric', 'between:0,1'],
            'y' => ['required', 'numeric', 'between:0,1'],
            'label' => ['nullable', 'string', 'max:120'],
        ]);

        // Store hotspot in the node
        $nodes = $tour['nodes'] ?? [];
        foreach ($nodes as &$node) {
            if (($node['id'] ?? 0) === $nodeId) {
                $hotspots = $node['hotspots'] ?? [];
                $hotspots[] = [
                    'product_id' => (int) $data['product_id'],
                    'x' => (float) $data['x'],
                    'y' => (float) $data['y'],
                    'label' => $data['label'] ?? '',
                ];
                $node['hotspots'] = $hotspots;
                break;
            }
        }
        unset($node);

        $this->firestore->updateByNumericId('tours', $tourId, ['nodes' => $nodes]);
        $tour['nodes'] = $nodes;

        return response()->json(['data' => $this->tourJson($tour)], 201);
    }

    public function deleteHotspot(Request $request, int $tourId, int $nodeId, int $hotspotId)
    {
        $user = $this->userResolver->resolve($request);
        $tour = $this->firestore->findByNumericId('tours', $tourId);
        abort_if($tour === null, 404, 'Tour not found.');
        abort_unless($this->userResolver->canManageStore($user, $tour['storeId'] ?? 0), 403, 'Not authorized.');

        $nodes = $tour['nodes'] ?? [];
        foreach ($nodes as &$node) {
            if (($node['id'] ?? 0) === $nodeId) {
                $hotspots = $node['hotspots'] ?? [];
                if (isset($hotspots[$hotspotId])) {
                    unset($hotspots[$hotspotId]);
                    $node['hotspots'] = array_values($hotspots);
                }
                break;
            }
        }
        unset($node);

        $this->firestore->updateByNumericId('tours', $tourId, ['nodes' => $nodes]);
        $tour['nodes'] = $nodes;

        return response()->json(['data' => $this->tourJson($tour)]);
    }

    public function mediaStatus(int $nodeId)
    {
        // Look up the tour that contains this node
        $tours = $this->firestore->all('tours');
        foreach ($tours as $tour) {
            foreach ($tour['nodes'] ?? [] as $node) {
                if (($node['id'] ?? 0) === $nodeId) {
                    return response()->json(['data' => [
                        'id' => $node['id'],
                        'privacy_status' => $node['privacy_status'] ?? 'processing',
                        'owner_reviewed' => $node['owner_reviewed'] ?? false,
                        'has_public_derivative' => filled($node['image'] ?? ''),
                        'original_retained' => $node['original_retained'] ?? false,
                    ]]);
                }
            }
        }
        abort(404, 'Node not found.');
    }

    public function addManualBlurForMedia(Request $request, int $nodeId)
    {
        // Find the tour containing this node, then delegate
        $tours = $this->firestore->all('tours');
        foreach ($tours as $tour) {
            foreach ($tour['nodes'] ?? [] as $node) {
                if (($node['id'] ?? 0) === $nodeId) {
                    return $this->addManualBlur($request, $tour['numericId'], $nodeId);
                }
            }
        }
        abort(404, 'Node not found.');
    }

    private function tourJson(array $data): array
    {
        return [
            'id' => $data['numericId'] ?? 0,
            'store_id' => $data['storeId'] ?? 0,
            'title' => $data['title'] ?? '',
            'status' => $data['status'] ?? 'draft',
            'nodes' => $data['nodes'] ?? [],
        ];
    }
}
