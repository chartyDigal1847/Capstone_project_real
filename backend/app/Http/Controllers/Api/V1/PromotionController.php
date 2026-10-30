<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Promotion;
use App\Models\Store;
use App\Support\Audit;
use Carbon\Carbon;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

class PromotionController extends Controller
{
    public function store(Request $request, Store $store)
    {
        $this->authorize('create', [Promotion::class, $store]);

        $data = $request->validate([
            'title' => ['required', 'string', 'max:160'],
            'offer' => ['required', 'string'],
            'sponsored' => ['boolean'],
            'starts_at' => ['nullable', 'date'],
            'ends_at' => ['nullable', 'date', 'after:starts_at'],
        ]);

        $starts = isset($data['starts_at']) ? Carbon::parse($data['starts_at']) : now();
        $ends = isset($data['ends_at']) ? Carbon::parse($data['ends_at']) : $starts->copy()->addDays(14);

        $promo = Promotion::create([
            'store_id' => $store->id,
            'title' => $data['title'],
            'offer' => $data['offer'],
            'sponsored' => (bool) ($data['sponsored'] ?? false),
            'starts_at' => $starts,
            'ends_at' => $ends,
            'status' => 'pending',
        ]);

        Audit::record($request->user(), 'promotion.create', Promotion::class, $promo->id, [
            'store_id' => $store->id,
            'sponsored' => $promo->sponsored,
        ]);

        return response()->json(['data' => $promo->toApi()], 201);
    }

    public function setStatus(Request $request, Promotion $promotion)
    {
        $this->authorize('setStatus', $promotion);
        $data = $request->validate([
            'status' => ['required', Rule::in(['draft', 'pending', 'approved', 'rejected'])],
        ]);
        $promotion->update($data);
        Audit::record($request->user(), 'promotion.status', Promotion::class, $promotion->id, $data);

        return response()->json(['data' => $promotion->fresh()->toApi()]);
    }
}
