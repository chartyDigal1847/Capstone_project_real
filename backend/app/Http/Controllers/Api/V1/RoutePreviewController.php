<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Support\RoutingService;
use Illuminate\Http\Request;

class RoutePreviewController extends Controller
{
    public function preview(Request $request, RoutingService $routing)
    {
        $data = $request->validate([
            'origin_lat' => ['required', 'numeric', 'between:-90,90'],
            'origin_lng' => ['required', 'numeric', 'between:-180,180'],
            'destination_lat' => ['required', 'numeric', 'between:-90,90'],
            'destination_lng' => ['required', 'numeric', 'between:-180,180'],
        ]);

        return response()->json([
            'data' => $routing->preview(
                (float) $data['origin_lat'],
                (float) $data['origin_lng'],
                (float) $data['destination_lat'],
                (float) $data['destination_lng'],
            ),
        ]);
    }
}
