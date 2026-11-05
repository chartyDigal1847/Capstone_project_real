<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
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
 * Actual person/face detection and Cloud Storage upload are pending
 * (plan Wave 3). The publication gate logic is implemented here.
 */
class TourController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
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

        $data = $request->validate(['title' => ['required', 'string', 'max:120']]);

        $nodes = $tour['nodes'] ?? [];
        $nodeId = count($nodes) + 1;
        $nodes[] = [
            'id' => $nodeId,
            'title' => $data['title'],
            'image' => '',
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
        }

        $this->firestore->updateByNumericId('tours', $tourId, ['status' => 'published']);
        $tour['status'] = 'published';

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
            'regions' => ['nullable', 'array'],
        ]);

        $regions = $data['regions'] ?? [['x' => 0.35, 'y' => 0.35, 'w' => 0.3, 'h' => 0.3]];

        $nodes = $tour['nodes'] ?? [];
        $found = false;
        foreach ($nodes as &$node) {
            if (($node['id'] ?? 0) === $nodeId) {
                $node['manual_blur'] = true;
                $node['privacy_status'] = 'ready';
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

        $fail = $request->boolean('fail');

        $nodes = $tour['nodes'] ?? [];
        foreach ($nodes as &$node) {
            if (($node['id'] ?? 0) === $nodeId) {
                $node['privacy_status'] = $fail ? 'failed' : 'ready';
                $node['image'] = $fail ? '' : "/tours/public/{$tour['storeId']}/$nodeId.jpg";
                $node['owner_reviewed'] = false;
                break;
            }
        }
        unset($node);

        $this->firestore->updateByNumericId('tours', $tourId, ['nodes' => $nodes]);
        $tour['nodes'] = $nodes;

        return response()->json(['data' => $this->tourJson($tour)]);
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
