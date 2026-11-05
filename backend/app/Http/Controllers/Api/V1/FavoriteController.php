<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

/** Favorites — Firestore-backed and scoped to the authenticated UID. */
class FavoriteController extends Controller
{
    public function __construct(private readonly FirestoreService $firestore)
    {
    }

    public function index(Request $request)
    {
        $uid = $request->attributes->get('firebase_uid');

        $favorites = $this->firestore->query('favorites', [
            ['field' => 'uid', 'op' => '==', 'value' => $uid],
        ]);

        return response()->json(['data' => array_values(array_filter(
            $favorites,
            fn (array $favorite) => ($favorite['_deleted'] ?? false) !== true
        ))]);
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

        $active = array_values(array_filter(
            $existing,
            fn (array $favorite) => ($favorite['_deleted'] ?? false) !== true
        ));
        if ($active !== []) {
            foreach ($active as $favorite) {
                $this->firestore->delete('favorites', $favorite['id']);
            }
            return response()->json(['data' => ['saved' => false]]);
        }

        // Reactivate a legacy soft-deleted record rather than creating a duplicate.
        if ($existing !== []) {
            $this->firestore->update('favorites', $existing[0]['id'], ['_deleted' => false]);
            return response()->json(['data' => ['saved' => true]]);
        }

        $this->firestore->create('favorites', [
            'uid' => $uid,
            'favoritable_type' => $data['favoritable_type'],
            'favoritable_id' => $data['favoritable_id'],
        ]);

        return response()->json(['data' => ['saved' => true]]);
    }
}
