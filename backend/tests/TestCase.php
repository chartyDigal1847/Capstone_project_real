<?php

namespace Tests;

use App\Services\FirestoreTestService;
use Illuminate\Foundation\Testing\TestCase as BaseTestCase;

abstract class TestCase extends BaseTestCase
{
    protected FirestoreTestService $firestore;

    protected function setUp(): void
    {
        parent::setUp();

        // Register the in-memory Firestore mock for testing.
        $this->firestore = new FirestoreTestService();
        $this->app->instance(\App\Services\FirestoreService::class, $this->firestore);
    }

    /**
     * Seed a user profile into the in-memory Firestore.
     * Returns the Firebase UID used as the document ID.
     */
    protected function seedUser(string $email, string $name, string $role, int $numericId, array $extra = []): string
    {
        $uid = 'uid-' . explode('@', $email)[0];
        $this->firestore->seed('users', $uid, array_merge([
            'numericId' => $numericId,
            'name' => $name,
            'email' => $email,
            'role' => $role,
            'ownedStoreIds' => [],
            'memberStoreIds' => [],
            'storeGrants' => [],
        ], $extra));

        return $uid;
    }

    /**
     * Get a test Bearer token for the given Firebase UID.
     * The VerifyFirebaseToken middleware accepts test-token-* when
     * FIREBASE_AUTH_EMULATOR_HOST is set.
     */
    protected function firebaseToken(string $uid): string
    {
        return "test-token-$uid";
    }

    /**
     * Make an authenticated JSON request with a test Firebase token.
     */
    protected function withFirebaseAuth(string $uid, ?string $method = null, ?string $uri = null, array $data = [])
    {
        $token = $this->firebaseToken($uid);
        return $this->withToken($token);
    }
}
