<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\PilotFeedback;
use Illuminate\Http\Request;

class FeedbackController extends Controller
{
    public function store(Request $request)
    {
        $data = $request->validate([
            'topic' => ['required', 'string', 'max:80'],
            'body' => ['required', 'string', 'max:2000'],
            'area' => ['nullable', 'string', 'max:120'],
        ]);

        $row = PilotFeedback::create([
            'user_id' => $request->user()->id,
            'topic' => $data['topic'],
            'body' => $data['body'],
            'area' => $data['area'] ?? null,
        ]);

        return response()->json(['data' => $row->toApi()], 201);
    }

    public function index(Request $request)
    {
        abort_unless($request->user()?->isAdmin(), 403);

        return response()->json([
            'data' => PilotFeedback::orderByDesc('id')->get()->map->toApi(),
        ]);
    }
}
