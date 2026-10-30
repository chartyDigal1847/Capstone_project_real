<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Store;
use App\Models\VendorLocationSession;
use App\Support\Audit;
use Illuminate\Http\Request;

class VendorLocationSessionController extends Controller
{
    public function start(Request $request, Store $store)
    {
        $this->authorize('shareLiveLocation', $store);
        abort_unless($store->is_mobile, 422, 'Live location is only available for mobile vendors.');

        $data = $request->validate([
            'lat' => ['required', 'numeric', 'between:-90,90'],
            'lng' => ['required', 'numeric', 'between:-180,180'],
        ]);

        $store->locationSessions()->active()->update(['ended_at' => now()]);

        $minutes = max(15, (int) config('localspot.vendor_session_minutes', 120));
        $session = VendorLocationSession::create([
            'store_id' => $store->id,
            'started_by' => $request->user()->id,
            'lat' => $data['lat'],
            'lng' => $data['lng'],
            'started_at' => now(),
            'last_update_at' => now(),
            'expires_at' => now()->addMinutes($minutes),
        ]);

        Audit::record($request->user(), 'store.location_session.start', Store::class, $store->id, [
            'session_id' => $session->id,
        ]);

        return response()->json(['data' => $session->toApi()], 201);
    }

    public function updateCurrent(Request $request, Store $store)
    {
        $this->authorize('update', $store);
        $session = $store->locationSessions()->active()->latest('id')->first();
        abort_if($session === null, 404, 'No active location session.');

        $data = $request->validate([
            'lat' => ['required', 'numeric', 'between:-90,90'],
            'lng' => ['required', 'numeric', 'between:-180,180'],
        ]);

        $session->update([
            'lat' => $data['lat'],
            'lng' => $data['lng'],
            'last_update_at' => now(),
        ]);

        return response()->json(['data' => $session->fresh()->toApi()]);
    }

    public function current(Store $store)
    {
        $this->authorize('update', $store);
        $session = $store->locationSessions()->active()->latest('id')->first();
        abort_if($session === null, 404, 'No active location session.');

        return response()->json(['data' => $session->toApi()]);
    }

    public function stop(Request $request, Store $store)
    {
        $this->authorize('shareLiveLocation', $store);
        $session = $store->locationSessions()->active()->latest('id')->first();
        abort_if($session === null, 404, 'No active location session.');

        $session->update(['ended_at' => now()]);
        Audit::record($request->user(), 'store.location_session.stop', Store::class, $store->id, [
            'session_id' => $session->id,
        ]);

        return response()->json(['data' => $session->fresh()->toApi()]);
    }
}
