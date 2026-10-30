<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Report;
use Illuminate\Http\Request;

class ReportController extends Controller
{
    public function store(Request $request)
    {
        $this->authorize('create', Report::class);
        $data = $request->validate([
            'target' => ['required', 'string', 'max:190'],
            'reason' => ['required', 'string'],
        ]);
        $report = Report::create([
            'user_id' => $request->user()->id,
            'target' => $data['target'],
            'reason' => $data['reason'],
        ]);

        return response()->json(['data' => $report->toApi()], 201);
    }

    public function index(Request $request)
    {
        $this->authorize('viewAny', Report::class);

        return response()->json([
            'data' => Report::orderByDesc('id')->get()->map->toApi(),
        ]);
    }

    public function resolve(Request $request, Report $report)
    {
        $this->authorize('update', $report);
        $report->update(['resolved' => true]);

        return response()->json(['data' => $report->toApi()]);
    }
}
