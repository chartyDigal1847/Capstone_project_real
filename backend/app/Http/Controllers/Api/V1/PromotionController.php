<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use App\Support\CatalogCache;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

/** Promotions — Firestore-backed. */
class PromotionController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    public function store(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        $store = $this->firestore->findByNumericId('stores', $storeId);
        abort_if($store === null, 404, 'Store not found.');
        abort_unless($this->userResolver->canManageStore($user, $storeId), 403, 'Not authorized.');

        $data = $request->validate([
            'title' => ['required', 'string', 'max:160'],
            'offer' => ['required', 'string'],
            'sponsored' => ['boolean'],
            'starts_at' => ['nullable', 'date'],
            'ends_at' => ['nullable', 'date'],
        ]);

        $id = abs(crc32(uniqid())) & 0x7fffffff;
        $this->firestore->create('promotions', [
            'numericId' => $id,
            'storeId' => $storeId,
            'title' => $data['title'],
            'offer' => $data['offer'],
            'starts_at' => $data['starts_at'] ?? now()->toIso8601String(),
            'ends_at' => $data['ends_at'] ?? now()->addDays(14)->toIso8601String(),
            'sponsored' => (bool) ($data['sponsored'] ?? false),
            'status' => 'pending',
            'ownerUid' => $request->attributes->get('firebase_uid'),
        ]);

        // Invalidate promotion-related caches.
        CatalogCache::invalidatePromotion($storeId);

        return response()->json(['data' => ['id' => $id]], 201);
    }

    public function setStatus(Request $request, int $promoId)
    {
        $user = $this->userResolver->resolve($request);
        abort_unless(UserResolver::isAdmin($user), 403, 'Admin only.');

        $data = $request->validate([
            'status' => ['required', Rule::in(['draft', 'pending', 'approved', 'rejected'])],
        ]);

        $this->firestore->updateByNumericId('promotions', $promoId, ['status' => $data['status']]);

        // Invalidate caches when a promotion status changes.
        $promo = $this->firestore->findByNumericId('promotions', $promoId);
        if ($promo !== null) {
            CatalogCache::invalidatePromotion($promo['storeId'] ?? 0);
        }

        return response()->json(['data' => true]);
    }
}
