<?php

namespace App\Services;

use Illuminate\Http\Request;
use RuntimeException;

/**
 * Resolves the authenticated user's Firestore profile from the Firebase UID
 * set on the request by VerifyFirebaseToken middleware.
 *
 * The user's Firestore document path is users/{uid} where {uid} is the
 * Firebase Auth UID (the canonical identity key). If the profile does not
 * exist, it is created with the least-privileged default role (customer).
 */
class UserResolver
{
    public function __construct(private readonly FirestoreService $firestore)
    {
    }

    /**
     * Resolve the current user from the request, creating a minimal profile
     * if one does not yet exist.
     *
     * @return array{name: string, email: string, role: string, numericId: int, ownedStoreIds: array, memberStoreIds: array, storeGrants: array}
     */
    public function resolve(Request $request): array
    {
        $uid = $request->attributes->get('firebase_uid');
        if ($uid === null) {
            throw new RuntimeException('No Firebase UID on request.');
        }

        $token = $request->attributes->get('firebase_token', []);

        // Try to load existing profile
        $profile = $this->firestore->get('users', $uid);

        if ($profile === null) {
            // Create minimal profile with least-privileged default role
            $profile = [
                'numericId' => abs(crc32($uid)) & 0x7fffffff,
                'name' => $token['name'] ?? $token['email'] ?? '',
                'email' => $token['email'] ?? '',
                'role' => 'customer',
                'ownedStoreIds' => [],
                'memberStoreIds' => [],
                'storeGrants' => [],
            ];
            $this->firestore->set('users', $uid, $profile);
        }

        // Load store memberships for grants
        $members = $this->firestore->query('storeMembers', [
            ['field' => 'userUid', 'op' => '==', 'value' => $uid],
        ]);

        $memberStoreIds = [];
        $storeGrants = [];
        foreach ($members as $member) {
            $storeId = $member['storeId'] ?? null;
            if ($storeId !== null) {
                $memberStoreIds[] = $storeId;
                $storeGrants[] = [
                    'store_id' => $storeId,
                    'inventory' => $member['inventory'] ?? false,
                    'promotions' => $member['promotions'] ?? false,
                    'location' => $member['location'] ?? false,
                ];
            }
        }

        $profile['memberStoreIds'] = $memberStoreIds;
        $profile['storeGrants'] = $storeGrants;

        return $profile;
    }

    /**
     * Check if the resolved user has a specific role.
     */
    public static function hasRole(array $user, string $role): bool
    {
        return ($user['role'] ?? 'customer') === $role;
    }

    /**
     * Check if the resolved user is an admin.
     */
    public static function isAdmin(array $user): bool
    {
        return self::hasRole($user, 'admin');
    }

    /**
     * Check if the user owns or manages a store by numericId.
     */
    public function canManageStore(array $user, int $storeNumericId): bool
    {
        if (self::isAdmin($user)) {
            return true;
        }

        if (! $this->isStoreApproved($storeNumericId)) {
            return false;
        }

        if (! in_array($user['role'] ?? '', ['owner', 'staff'], true)) {
            return false;
        }

        if (in_array($storeNumericId, $user['ownedStoreIds'] ?? [], true)) {
            return true;
        }

        return in_array($storeNumericId, $user['memberStoreIds'] ?? [], true);
    }

    /**
     * Check if the user has a specific store grant.
     */
    public function hasStoreGrant(array $user, int $storeNumericId, string $grant, bool $requireApproved = true): bool
    {
        if (self::isAdmin($user)) {
            return true;
        }

        if ($requireApproved && ! $this->isStoreApproved($storeNumericId)) {
            return false;
        }

        if (in_array($storeNumericId, $user['ownedStoreIds'] ?? [], true)) {
            return true;
        }

        foreach ($user['storeGrants'] ?? [] as $g) {
            if (($g['store_id'] ?? null) === $storeNumericId) {
                return (bool) ($g[$grant] ?? false);
            }
        }

        return false;
    }

    private function isStoreApproved(int $storeNumericId): bool
    {
        $store = $this->firestore->findByNumericId('stores', $storeNumericId);

        return ($store['status'] ?? null) === 'approved';
    }
}
