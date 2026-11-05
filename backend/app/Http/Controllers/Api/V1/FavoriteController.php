<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

/** Favorites — Firestore-backed. Owner-only access enforced in Laravel. */
class FavoriteController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    public function index(Request $request)
    {
        $user = $this->userResolver->resolve($request);
        $uid = $request->attributes->get('firebase_uid');

        $favorites = $this->firestore->query('favorites', [
            ['field' => 'uid', 'op' => '==', 'value' => $uid],
        ]);

        return response()->json(['data' => $favorites]);
    }

    public function toggle(Request $request)
    {
        $uid = $request->attributes->get('firebase_uid');

        $data = $request->validate([
            'favoritable_type' => ['required', Rule::in(['store', 'product'])],
            'favoritable_id' => ['required', 'integer'],
        ]);

        $existing = $this->firestore->query('favorites', [
            ['field' => 'uid', 'op' => '==', 'value' => $uid],
            ['field' => 'favoritable_type', 'op' => '==', 'value' => $data['favoritable_type']],
            ['field' => 'favoritable_id', 'op' => '==', 'value' => $data['favoritable_id']],
        ]);

        if (! empty($existing)) {
            $this->firestore->update('favorites', $existing[0]['id'], ['_deleted' => true]);
            // Firestore doesn't have a direct delete in our service wrapper —
            // use a batch delete or mark as deleted. For now, update a flag.
            return response()->json(['data' => ['saved' => false]]);
        }

        $this->firestore->create('favorites', [
            'uid' => $uid,
            'favoritable_type' => $data['favoritable_type'],
            'favoritable_id' => $data['favoritable_id'],
        ]);

        return response()->json(['data' => ['saved' => true]]);
    }
}
