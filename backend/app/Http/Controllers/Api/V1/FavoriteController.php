<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Favorite;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

class FavoriteController extends Controller
{
    public function index(Request $request)
    {
        $items = Favorite::where('user_id', $request->user()->id)->get();

        return response()->json(['data' => $items]);
    }

    public function toggle(Request $request)
    {
        $data = $request->validate([
            'favoritable_type' => ['required', Rule::in(['store', 'product'])],
            'favoritable_id' => ['required', 'integer'],
        ]);
        $existing = Favorite::where('user_id', $request->user()->id)
            ->where('favoritable_type', $data['favoritable_type'])
            ->where('favoritable_id', $data['favoritable_id'])
            ->first();
        if ($existing) {
            $existing->delete();

            return response()->json(['data' => ['saved' => false]]);
        }
        Favorite::create([
            'user_id' => $request->user()->id,
            ...$data,
        ]);

        return response()->json(['data' => ['saved' => true]]);
    }
}
