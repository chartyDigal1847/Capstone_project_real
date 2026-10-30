<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class AuditController extends Controller
{
    public function index(Request $request)
    {
        abort_unless($request->user()?->isAdmin(), 403);

        $rows = DB::table('audit_logs')->orderByDesc('id')->limit(80)->get()->map(function ($row) {
            return [
                'id' => $row->id,
                'user_id' => $row->user_id,
                'action' => $row->action,
                'subject_type' => $row->subject_type,
                'subject_id' => $row->subject_id,
                'meta' => $row->meta ? json_decode($row->meta, true) : null,
                'created_at' => $row->created_at,
            ];
        });

        return response()->json(['data' => $rows]);
    }
}
