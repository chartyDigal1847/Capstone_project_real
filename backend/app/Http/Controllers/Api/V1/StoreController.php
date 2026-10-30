<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Store;
use App\Models\User;
use App\Support\Audit;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

class StoreController extends Controller
{
    public function store(Request $request)
    {
        $this->authorize('create', Store::class);
        $user = $request->user();

        $data = $request->validate([
            'name' => ['required', 'string', 'max:160'],
            'type' => ['required', 'string', 'max:64'],
            'lat' => ['required', 'numeric', 'between:-90,90'],
            'lng' => ['required', 'numeric', 'between:-180,180'],
            'barangay' => ['nullable', 'string', 'max:120'],
            'city' => ['required', 'string', 'max:120'],
            'address' => ['nullable', 'string', 'max:190'],
            'landmark' => ['required', 'string', 'max:190'],
            'schedule' => ['nullable', 'string', 'max:190'],
            'is_mobile' => ['boolean'],
            'verification_note' => ['nullable', 'string'],
        ]);

        $store = Store::create([
            ...$data,
            'owner_id' => $user->id,
            'status' => 'pending',
            'is_mobile' => (bool) ($data['is_mobile'] ?? false),
        ]);

        return response()->json(['data' => $store->toApi()], 201);
    }

    public function update(Request $request, Store $store)
    {
        $this->authorize('update', $store);

        $data = $request->validate([
            'name' => ['sometimes', 'string', 'max:160'],
            'lat' => ['sometimes', 'numeric'],
            'lng' => ['sometimes', 'numeric'],
            'landmark' => ['sometimes', 'string'],
            'schedule' => ['sometimes', 'string'],
            'is_mobile' => ['sometimes', 'boolean'],
        ]);
        $store->update($data);

        if (isset($data['lat'], $data['lng'])) {
            $store->locations()->create([
                'kind' => $store->is_mobile ? 'current' : 'regular',
                'lat' => $data['lat'],
                'lng' => $data['lng'],
                'note' => 'Owner-updated public pin',
                'updated_public_at' => now(),
            ]);
        }

        return response()->json(['data' => $store->fresh()->toApi()]);
    }

    public function inviteStaff(Request $request, Store $store)
    {
        $this->authorize('invite', $store);
        $data = $request->validate([
            'email' => ['required', 'email'],
            'membership_role' => ['nullable', Rule::in(['staff'])],
            'can_inventory' => ['nullable', 'boolean'],
            'can_promotions' => ['nullable', 'boolean'],
            'can_location' => ['nullable', 'boolean'],
        ]);

        $member = User::where('email', $data['email'])->first();
        abort_if($member === null, 422, 'No LocalSpot account uses that email.');
        abort_if($member->isAdmin(), 422, 'Administrators cannot be added as store staff.');
        abort_if((int) $store->owner_id === (int) $member->id, 422, 'The owner already manages this store.');

        $store->members()->syncWithoutDetaching([
            $member->id => [
                'membership_role' => $data['membership_role'] ?? 'staff',
                'can_inventory' => $data['can_inventory'] ?? true,
                'can_promotions' => $data['can_promotions'] ?? false,
                'can_location' => $data['can_location'] ?? false,
            ],
        ]);
        if ($member->role === 'customer') {
            $member->update(['role' => 'staff']);
        }

        Audit::record($request->user(), 'store.invite_staff', Store::class, $store->id, [
            'email' => $member->email,
        ]);

        return response()->json([
            'data' => [
                'store_id' => $store->id,
                'user' => $member->fresh()->toApi(),
            ],
        ], 201);
    }

    public function setStatus(Request $request, Store $store)
    {
        $this->authorize('setStatus', $store);
        $data = $request->validate([
            'status' => ['required', Rule::in(['pending', 'approved', 'suspended'])],
        ]);
        $store->update($data);
        Audit::record($request->user(), 'store.status', Store::class, $store->id, $data);

        return response()->json(['data' => $store->fresh()->toApi()]);
    }

    public function updateStaff(Request $request, Store $store, User $user)
    {
        $this->authorize('invite', $store);
        abort_unless($store->members()->where('users.id', $user->id)->exists(), 404);
        $data = $request->validate([
            'can_inventory' => ['sometimes', 'boolean'],
            'can_promotions' => ['sometimes', 'boolean'],
            'can_location' => ['sometimes', 'boolean'],
        ]);
        $store->members()->updateExistingPivot($user->id, $data);
        Audit::record($request->user(), 'store.staff_grants', Store::class, $store->id, [
            'user_id' => $user->id,
            ...$data,
        ]);

        return response()->json(['data' => $user->fresh()->toApi()]);
    }
}
