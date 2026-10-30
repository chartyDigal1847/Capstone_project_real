<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Jobs\ProcessTourNodeJob;
use App\Models\Product;
use App\Models\Store;
use App\Models\StoreTour;
use App\Models\TourConnection;
use App\Models\TourHotspot;
use App\Models\TourNode;
use App\Support\Audit;
use App\Support\TourPrivacy;
use Illuminate\Http\Request;

class TourController extends Controller
{
    public function store(Request $request, Store $store)
    {
        $this->authorize('create', [StoreTour::class, $store]);
        $data = $request->validate(['title' => ['required', 'string', 'max:160']]);
        $tour = StoreTour::create([
            'store_id' => $store->id,
            'title' => $data['title'],
            'status' => 'draft',
        ]);

        return response()->json(['data' => $tour->toApi()], 201);
    }

    public function addNode(Request $request, StoreTour $storeTour)
    {
        $this->authorize('update', $storeTour);
        $data = $request->validate([
            'title' => ['required', 'string', 'max:120'],
            'image' => ['required', 'string'],
        ]);
        $node = TourNode::create([
            'store_tour_id' => $storeTour->id,
            'title' => $data['title'],
            'image' => '',
            'original_image' => null,
            'sort_order' => $storeTour->nodes()->count() + 1,
            'privacy_status' => 'processing',
            'owner_reviewed' => false,
            'original_expires_at' => now()->addDays(TourPrivacy::retentionDays()),
        ]);
        $node->update(['original_image' => TourPrivacy::stage($data['image'], $node->id)]);
        $previous = TourNode::query()
            ->where('store_tour_id', $storeTour->id)
            ->where('id', '<', $node->id)
            ->orderByDesc('id')
            ->first();
        if ($previous) {
            TourConnection::create(['from_node_id' => $previous->id, 'to_node_id' => $node->id]);
            TourConnection::create(['from_node_id' => $node->id, 'to_node_id' => $previous->id]);
        }
        ProcessTourNodeJob::dispatch($node->id);

        return response()->json(['data' => $storeTour->fresh('nodes.outgoing')->toApi()]);
    }

    public function connect(Request $request, StoreTour $storeTour)
    {
        $this->authorize('update', $storeTour);
        $data = $request->validate([
            'from_node_id' => ['required', 'integer'],
            'to_node_id' => ['required', 'integer', 'different:from_node_id'],
        ]);
        $from = TourNode::where('store_tour_id', $storeTour->id)->findOrFail($data['from_node_id']);
        $to = TourNode::where('store_tour_id', $storeTour->id)->findOrFail($data['to_node_id']);
        TourConnection::firstOrCreate(['from_node_id' => $from->id, 'to_node_id' => $to->id]);
        TourConnection::firstOrCreate(['from_node_id' => $to->id, 'to_node_id' => $from->id]);

        return response()->json(['data' => $storeTour->fresh('nodes.outgoing')->toApi()]);
    }

    public function publish(Request $request, StoreTour $storeTour)
    {
        $this->authorize('update', $storeTour);
        abort_if($storeTour->nodes()->count() < 2, 422, 'Connect at least two viewpoints before publishing.');
        abort_if(
            $storeTour->nodes()->where(function ($query) {
                $query->where('privacy_status', '!=', 'ready')
                    ->orWhere('owner_reviewed', false)
                    ->orWhere('image', '');
            })->exists(),
            422,
            'Every viewpoint needs privacy processing and owner review before publishing.'
        );
        abort_if(
            $storeTour->nodes()->get()->contains(function (TourNode $node) {
                return $node->image === $node->original_image
                    || str_contains((string) $node->image, 'tours/originals')
                    || str_contains((string) $node->image, '#');
            }),
            422,
            'Public viewpoints may only use sanitized derivatives, never originals.'
        );
        $storeTour->update(['status' => 'published']);
        Audit::record($request->user(), 'tour.publish', StoreTour::class, $storeTour->id);

        return response()->json(['data' => $storeTour->fresh('nodes.outgoing')->toApi()]);
    }

    public function reviewNode(StoreTour $storeTour, TourNode $tourNode)
    {
        $this->authorize('update', $storeTour);
        abort_unless($tourNode->store_tour_id === $storeTour->id, 404);
        abort_if($tourNode->privacy_status !== 'ready', 422, 'Privacy processing must finish before review.');
        abort_if($tourNode->image === '', 422, 'A sanitized public image is required before review.');
        $tourNode->update(['owner_reviewed' => true]);

        return response()->json(['data' => $storeTour->fresh('nodes.outgoing')->toApi()]);
    }

    public function addManualBlur(Request $request, StoreTour $storeTour, TourNode $tourNode)
    {
        $this->authorize('update', $storeTour);
        abort_unless($tourNode->store_tour_id === $storeTour->id, 404);
        abort_if(! filled($tourNode->original_image) && $tourNode->image === '', 422, 'No staged panorama to blur.');
        $data = $request->validate([
            'regions' => ['nullable', 'array'],
            'regions.*.x' => ['required_with:regions', 'numeric', 'between:0,1'],
            'regions.*.y' => ['required_with:regions', 'numeric', 'between:0,1'],
            'regions.*.w' => ['required_with:regions', 'numeric', 'between:0.01,1'],
            'regions.*.h' => ['required_with:regions', 'numeric', 'between:0.01,1'],
        ]);
        $regions = $data['regions'] ?? [['x' => 0.35, 'y' => 0.35, 'w' => 0.3, 'h' => 0.3]];
        $existing = $tourNode->blur_regions ?? [];
        $tourNode->update([
            'manual_blur' => true,
            'privacy_status' => 'ready',
            'image' => $tourNode->image !== '' ? $tourNode->image : TourPrivacy::writeDerivative($tourNode),
            'blur_regions' => [...$existing, ...$regions],
        ]);

        return response()->json(['data' => $storeTour->fresh('nodes.outgoing')->toApi()]);
    }

    public function processNode(Request $request, StoreTour $storeTour, TourNode $tourNode)
    {
        $this->authorize('update', $storeTour);
        abort_unless($tourNode->store_tour_id === $storeTour->id, 404);
        ProcessTourNodeJob::dispatch($tourNode->id, $request->boolean('fail'));

        return response()->json(['data' => $storeTour->fresh('nodes.outgoing')->toApi()]);
    }

    public function addManualBlurForMedia(Request $request, TourNode $tourNode)
    {
        return $this->addManualBlur($request, $tourNode->tour, $tourNode);
    }

    public function addHotspot(Request $request, StoreTour $storeTour, TourNode $tourNode)
    {
        $this->authorize('update', $storeTour);
        abort_unless($tourNode->store_tour_id === $storeTour->id, 404);
        $data = $request->validate([
            'product_id' => ['required', 'integer', 'exists:products,id'],
            'x' => ['required', 'numeric', 'between:0,1'],
            'y' => ['required', 'numeric', 'between:0,1'],
            'label' => ['nullable', 'string', 'max:120'],
        ]);
        $product = Product::findOrFail($data['product_id']);
        $hotspot = TourHotspot::create([
            'tour_node_id' => $tourNode->id,
            'product_id' => $product->id,
            'x' => $data['x'],
            'y' => $data['y'],
            'label' => $data['label'] ?? $product->name,
        ]);
        Audit::record($request->user(), 'tour.hotspot.add', TourHotspot::class, $hotspot->id, [
            'node_id' => $tourNode->id,
            'product_id' => $product->id,
        ]);

        return response()->json(['data' => $storeTour->fresh()->toApi()], 201);
    }

    public function deleteHotspot(StoreTour $storeTour, TourNode $tourNode, TourHotspot $tourHotspot)
    {
        $this->authorize('update', $storeTour);
        abort_unless($tourNode->store_tour_id === $storeTour->id, 404);
        abort_unless($tourHotspot->tour_node_id === $tourNode->id, 404);
        $tourHotspot->delete();

        return response()->json(['data' => $storeTour->fresh()->toApi()]);
    }

    public function mediaStatus(TourNode $tourNode)
    {
        $this->authorize('update', $tourNode->tour);

        return response()->json([
            'data' => [
                ...$tourNode->toApi(),
                'has_public_derivative' => filled($tourNode->image),
                'original_retained' => filled($tourNode->original_image),
            ],
        ]);
    }
}
