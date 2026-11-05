<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use App\Support\CatalogCache;
use App\Support\Geohash;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

/**
 * Store controller — Firestore-backed.
 * Authorization enforced server-side via UserResolver (not client-supplied roles).
 */
class StoreController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    public function store(Request $request)
    {
        $user = $this->userResolver->resolve($request);

        // Any authenticated user may submit a store registration request.
        // The store is created with 'pending' status; admin approval
        // grants owner privileges. Per the plan: "Selecting an owner option
        // in Flutter is only an onboarding request; it does not grant owner
        // privileges." Store-owner privileges are granted only after the
        // store registration/verification workflow.

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

        $numericId = abs(crc32(uniqid('store', true))) & 0x7fffffff;
        $uid = $request->attributes->get('firebase_uid');

        $storeData = [
            'numericId' => $numericId,
            'ownerId' => $user['numericId'],
            'ownerUid' => $uid,
            'name' => $data['name'],
            'type' => $data['type'],
            'status' => 'pending',
            'lat' => (float) $data['lat'],
            'lng' => (float) $data['lng'],
            'barangay' => $data['barangay'] ?? '',
            'city' => $data['city'],
            'address' => $data['address'] ?? '',
            'landmark' => $data['landmark'],
            'schedule' => $data['schedule'] ?? '',
            'is_mobile' => (bool) ($data['is_mobile'] ?? false),
            'image' => null,
            'verification_note' => $data['verification_note'] ?? '',
            'location_mode' => ($data['is_mobile'] ?? false) ? 'regular' : 'fixed',
            'location_updated_at' => now()->toIso8601String(),
            'geohash' => Geohash::encode((float) $data['lat'], (float) $data['lng']),
        ];

        $this->firestore->create('stores', $storeData);

        // Invalidate catalog cache so the new store appears on next bootstrap.
        CatalogCache::invalidateAll();

        // Note: the user's role is NOT upgraded here. Per the plan, store-owner
        // privileges are granted only after admin approval. The admin
        // approval workflow in setStatus() upgrades the role when the store
        // is approved.

        return response()->json(['data' => $this->storeJson($storeData)], 201);
    }

    public function update(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        $store = $this->firestore->findByNumericId('stores', $storeId);
        abort_if($store === null, 404, 'Store not found.');
        abort_unless($this->userResolver->canManageStore($user, $storeId), 403, 'Not authorized to manage this store.');

        $data = $request->validate([
            'name' => ['sometimes', 'string', 'max:160'],
            'lat' => ['sometimes', 'numeric'],
            'lng' => ['sometimes', 'numeric'],
            'landmark' => ['sometimes', 'string'],
            'schedule' => ['sometimes', 'string'],
            'is_mobile' => ['sometimes', 'boolean'],
        ]);

        $updateData = array_merge(
            array_filter($data, fn ($v, $k) => in_array($k, ['name', 'lat', 'lng', 'landmark', 'schedule', 'is_mobile'], true), ARRAY_FILTER_USE_BOTH),
            ['location_updated_at' => now()->toIso8601String()]
        );

        // Recompute geohash if coordinates changed
        if (isset($data['lat']) && isset($data['lng'])) {
            $updateData['geohash'] = Geohash::encode((float) $data['lat'], (float) $data['lng']);
        }

        $this->firestore->updateByNumericId('stores', $storeId, $updateData);

        // Invalidate store detail, nearby, and catalog caches.
        CatalogCache::invalidateStore($storeId);

        $updated = $this->firestore->findByNumericId('stores', $storeId);
        return response()->json(['data' => $this->storeJson($updated)]);
    }

    public function inviteStaff(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        $store = $this->firestore->findByNumericId('stores', $storeId);
        abort_if($store === null, 404, 'Store not found.');
        abort_unless(UserResolver::isAdmin($user) || ($store['ownerUid'] ?? '') === $request->attributes->get('firebase_uid'), 403, 'Not authorized to invite staff.');

        $data = $request->validate([
            'email' => ['required', 'email'],
            'can_inventory' => ['nullable', 'boolean'],
            'can_promotions' => ['nullable', 'boolean'],
            'can_location' => ['nullable', 'boolean'],
        ]);

        $email = strtolower(trim($data['email']));

        // Find invitee by email in Firestore users
        $invitee = null;
        $users = $this->firestore->all('users');
        foreach ($users as $u) {
            if (($u['email'] ?? '') === $email) {
                $invitee = $u;
                break;
            }
        }
        abort_if($invitee === null, 422, 'No LocalSpot account uses that email.');

        // Upsert storeMember
        $existing = $this->firestore->query('storeMembers', [
            ['field' => 'storeId', 'op' => '==', 'value' => $storeId],
            ['field' => 'userUid', 'op' => '==', 'value' => $invitee['id'] ?? ''],
        ]);

        $memberData = [
            'storeId' => $storeId,
            'email' => $email,
            'userUid' => $invitee['id'] ?? '',
            'userNumericId' => $invitee['numericId'] ?? 0,
            'inventory' => $data['can_inventory'] ?? true,
            'promotions' => $data['can_promotions'] ?? false,
            'location' => $data['can_location'] ?? false,
        ];

        if (! empty($existing)) {
            $this->firestore->update('storeMembers', $existing[0]['id'], $memberData);
        } else {
            $this->firestore->create('storeMembers', $memberData);
        }

        // Upgrade invitee role to staff if currently customer
        if (($invitee['role'] ?? 'customer') === 'customer') {
            $this->firestore->merge('users', $invitee['id'], ['role' => 'staff']);
        }

        // Audit log
        $this->firestore->create('auditLogs', [
            'numericId' => abs(crc32(uniqid())) & 0x7fffffff,
            'action' => 'store.invite_staff',
            'userId' => $user['numericId'],
            'created_at' => now()->toIso8601String(),
        ]);

        return response()->json(['data' => ['store_id' => $storeId, 'email' => $email]], 201);
    }

    public function updateStaff(Request $request, int $storeId, int $userId)
    {
        $user = $this->userResolver->resolve($request);
        $store = $this->firestore->findByNumericId('stores', $storeId);
        abort_if($store === null, 404, 'Store not found.');
        abort_unless($this->userResolver->canManageStore($user, $storeId), 403, 'Not authorized.');

        $data = $request->validate([
            'can_inventory' => ['nullable', 'boolean'],
            'can_promotions' => ['nullable', 'boolean'],
            'can_location' => ['nullable', 'boolean'],
        ]);

        $members = $this->firestore->query('storeMembers', [
            ['field' => 'storeId', 'op' => '==', 'value' => $storeId],
            ['field' => 'userNumericId', 'op' => '==', 'value' => $userId],
        ]);

        if (! empty($members)) {
            $updateData = array_filter([
                'inventory' => $data['can_inventory'] ?? null,
                'promotions' => $data['can_promotions'] ?? null,
                'location' => $data['can_location'] ?? null,
            ], fn ($v) => $v !== null);

            if (! empty($updateData)) {
                $this->firestore->update('storeMembers', $members[0]['id'], $updateData);
            }
        }

        return response()->json(['data' => true]);
    }

    public function setStatus(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        abort_unless(UserResolver::isAdmin($user), 403, 'Admin only.');

        $data = $request->validate([
            'status' => ['required', Rule::in(['pending', 'approved', 'suspended'])],
        ]);

        $this->firestore->updateByNumericId('stores', $storeId, ['status' => $data['status']]);

        // Invalidate all catalog caches when a store status changes (e.g., approval).
        CatalogCache::invalidateStore($storeId);

        // When approving a store, grant owner privileges to the store owner.
        // Per the plan: "Laravel/admin approval grants the appropriate
        // store-owner membership. Only then can the owner publish the
        // approved store profile and add products."
        if ($data['status'] === 'approved') {
            $store = $this->firestore->findByNumericId('stores', $storeId);
            if ($store !== null) {
                $ownerUid = $store['ownerUid'] ?? null;
                if ($ownerUid !== null && $ownerUid !== '') {
                    $owner = $this->firestore->get('users', $ownerUid);
                    if ($owner !== null) {
                        $ownedIds = $owner['ownedStoreIds'] ?? [];
                        if (! in_array($storeId, $ownedIds, true)) {
                            $ownedIds[] = $storeId;
                        }
                        $this->firestore->merge('users', $ownerUid, [
                            'ownedStoreIds' => $ownedIds,
                            'role' => 'owner',
                        ]);
                    }
                }
            }
        }

        $this->firestore->create('auditLogs', [
            'numericId' => abs(crc32(uniqid())) & 0x7fffffff,
            'action' => "store.status={$data['status']}",
            'userId' => $user['numericId'],
            'created_at' => now()->toIso8601String(),
        ]);

        return response()->json(['data' => true]);
    }

    private function storeJson(array $data): array
    {
        return [
            'id' => $data['numericId'] ?? 0,
            'owner_id' => $data['ownerId'] ?? 0,
            'name' => $data['name'] ?? '',
            'type' => $data['type'] ?? 'other',
            'status' => $data['status'] ?? 'pending',
            'lat' => $data['lat'] ?? 0.0,
            'lng' => $data['lng'] ?? 0.0,
            'barangay' => $data['barangay'] ?? '',
            'city' => $data['city'] ?? '',
            'address' => $data['address'] ?? '',
            'landmark' => $data['landmark'] ?? '',
            'schedule' => $data['schedule'] ?? '',
            'is_mobile' => $data['is_mobile'] ?? false,
            'image' => $data['image'] ?? null,
            'verification_note' => $data['verification_note'] ?? '',
            'location_mode' => $data['location_mode'] ?? 'fixed',
            'location_updated_at' => $data['location_updated_at'] ?? null,
        ];
    }
}
