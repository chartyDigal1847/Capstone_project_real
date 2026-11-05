<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use Illuminate\Http\Request;

/** Vendor location sessions — Firestore-backed. */
class VendorLocationSessionController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    public function start(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        $store = $this->firestore->findByNumericId('stores', $storeId);
        abort_if($store === null, 404, 'Store not found.');
        abort_unless($this->userResolver->hasStoreGrant($user, $storeId, 'location'), 403, 'Not authorized for location sharing.');
        abort_unless(($store['is_mobile'] ?? false), 422, 'Live location is only available for mobile vendors.');

        $data = $request->validate([
            'lat' => ['required', 'numeric', 'between:-90,90'],
            'lng' => ['required', 'numeric', 'between:-180,180'],
        ]);

        $now = now();
        $minutes = max(15, (int) config('localspot.vendor_session_minutes', 120));

        $payload = [
            'numericId' => abs(crc32(uniqid())) & 0x7fffffff,
            'storeId' => $storeId,
            'lat' => (float) $data['lat'],
            'lng' => (float) $data['lng'],
            'started_at' => $now->toIso8601String(),
            'last_update_at' => $now->toIso8601String(),
            'expires_at' => $now->addMinutes($minutes)->toIso8601String(),
            'ended_at' => null,
            'ownerUid' => $request->attributes->get('firebase_uid'),
        ];

        $this->firestore->set('vendorSessions', (string) $storeId, $payload);

        return response()->json(['data' => $payload], 201);
    }

    public function updateCurrent(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        abort_unless($this->userResolver->canManageStore($user, $storeId), 403, 'Not authorized.');

        $session = $this->firestore->get('vendorSessions', (string) $storeId);
        abort_if($session === null || ($session['ended_at'] ?? null) !== null, 404, 'No active location session.');

        $data = $request->validate([
            'lat' => ['required', 'numeric', 'between:-90,90'],
            'lng' => ['required', 'numeric', 'between:-180,180'],
        ]);

        $this->firestore->merge('vendorSessions', (string) $storeId, [
            'lat' => (float) $data['lat'],
            'lng' => (float) $data['lng'],
            'last_update_at' => now()->toIso8601String(),
        ]);

        return response()->json(['data' => true]);
    }

    public function current(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        abort_unless($this->userResolver->hasStoreGrant($user, $storeId, 'location'), 403, 'Not authorized to view this location session.');

        $session = $this->firestore->get('vendorSessions', (string) $storeId);
        abort_if($session === null || ($session['ended_at'] ?? null) !== null, 404, 'No active location session.');

        return response()->json(['data' => $session]);
    }

    public function stop(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        // Owners and staff must be able to stop a live session even after the
        // store is suspended or otherwise loses its approved status.
        abort_unless($this->userResolver->hasStoreGrant($user, $storeId, 'location', requireApproved: false), 403, 'Not authorized.');

        $session = $this->firestore->get('vendorSessions', (string) $storeId);
        abort_if($session === null || ($session['ended_at'] ?? null) !== null, 404, 'No active location session.');

        $this->firestore->merge('vendorSessions', (string) $storeId, [
            'ended_at' => now()->toIso8601String(),
        ]);

        return response()->json(['data' => true]);
    }
}
