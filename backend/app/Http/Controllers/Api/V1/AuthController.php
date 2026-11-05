<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use Illuminate\Http\Request;

/**
 * Authentication controller for the Firebase-backed target architecture.
 *
 * Firebase Authentication is the sole identity provider. Flutter signs
 * users in with the Firebase Auth SDK and sends the Firebase ID token to
 * Laravel as Authorization: Bearer <token>. Laravel verifies the token
 * (via VerifyFirebaseToken middleware) and resolves the Firestore user
 * profile.
 *
 * There are no Sanctum tokens, no password hashes on the server, and no
 * competing login system. The register endpoint syncs a profile into
 * Firestore after Firebase account creation; login is handled entirely
 * by the Firebase client SDK.
 */
class AuthController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    /**
     * Sync/create a Firestore user profile after Firebase account creation.
     * Flutter creates the Firebase Auth account first, then calls this
     * endpoint with the Firebase ID token to ensure a Firestore profile exists.
     *
     * The onboarding role request (customer/owner/staff) is just an intent —
     * actual owner/staff privileges are granted only by trusted backend/admin
     * workflows after store registration/verification.
     */
    public function register(Request $request)
    {
        $data = $request->validate([
            'name' => ['sometimes', 'string', 'max:120'],
            'role' => ['sometimes', 'string', 'in:customer,owner,staff'],
        ]);

        $uid = $request->attributes->get('firebase_uid');
        $token = $request->attributes->get('firebase_token', []);

        // Check if profile already exists
        $existing = $this->firestore->get('users', $uid);

        if ($existing !== null) {
            // Profile already exists — return it
            $user = $this->userResolver->resolve($request);
            return response()->json(['data' => ['user' => $user]]);
        }

        // Create minimal profile with least-privileged default role (customer)
        $profile = [
            'numericId' => abs(crc32($uid)) & 0x7fffffff,
            'name' => $data['name'] ?? $token['email'] ?? '',
            'email' => $token['email'] ?? '',
            // Role stays 'customer' regardless of request — owner/staff
            // privileges are granted only by trusted backend workflows.
            'role' => 'customer',
            'ownedStoreIds' => [],
            'memberStoreIds' => [],
            'storeGrants' => [],
        ];

        $this->firestore->set('users', $uid, $profile);

        $user = $this->userResolver->resolve($request);

        return response()->json(['data' => ['user' => $user, 'stores' => []]], 201);
    }

    /**
     * With Firebase Auth, login is handled by the Firebase client SDK.
     * This endpoint verifies the token and returns the user profile and
     * managed stores, matching the /me endpoint format. It does NOT issue
     * a server-side token.
     */
    public function login(Request $request)
    {
        $user = $this->userResolver->resolve($request);

        // Fetch managed stores (same logic as me())
        $ownedIds = $user['ownedStoreIds'] ?? [];
        $memberIds = $user['memberStoreIds'] ?? [];
        $allStoreIds = array_unique(array_merge($ownedIds, $memberIds));

        $stores = [];
        if (! empty($allStoreIds) || UserResolver::isAdmin($user)) {
            $allStores = $this->firestore->all('stores');
            foreach ($allStores as $store) {
                $storeNumericId = $store['numericId'] ?? null;
                if ($storeNumericId === null) continue;
                if (UserResolver::isAdmin($user) || in_array($storeNumericId, $allStoreIds, true)) {
                    $stores[] = $this->storeToApi($store);
                }
            }
        }
        usort($stores, fn ($a, $b) => ($a['name'] ?? '') <=> ($b['name'] ?? ''));

        return response()->json([
            'data' => [
                'user' => $user,
                'stores' => $stores,
            ],
        ]);
    }

    /**
     * Return the authenticated user's profile and managed stores.
     * Protected by firebase.auth middleware.
     */
    public function me(Request $request)
    {
        $user = $this->userResolver->resolve($request);

        // Fetch stores owned or managed by this user
        $ownedIds = $user['ownedStoreIds'] ?? [];
        $memberIds = $user['memberStoreIds'] ?? [];
        $allStoreIds = array_unique(array_merge($ownedIds, $memberIds));

        $stores = [];
        if (! empty($allStoreIds) || UserResolver::isAdmin($user)) {
            $allStores = $this->firestore->all('stores');
            foreach ($allStores as $store) {
                $storeNumericId = $store['numericId'] ?? null;
                if ($storeNumericId === null) continue;
                if (UserResolver::isAdmin($user) || in_array($storeNumericId, $allStoreIds, true)) {
                    $stores[] = $this->storeToApi($store);
                }
            }
        }

        // Sort by name
        usort($stores, fn ($a, $b) => ($a['name'] ?? '') <=> ($b['name'] ?? ''));

        return response()->json([
            'data' => [
                'user' => $user,
                'stores' => $stores,
            ],
        ]);
    }

    /**
     * Logout is primarily a client-side Firebase Auth signOut. The server
     * can optionally record session state. No Sanctum token to delete.
     */
    public function logout(Request $request)
    {
        // Client signs out via Firebase Auth SDK. Server-side revocation
        // can be added here if required (e.g., Firebase Admin revokeRefreshTokens).
        return response()->json(['data' => true]);
    }

    /**
     * Convert a Firestore store document to the API response format.
     */
    private function storeToApi(array $data): array
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
