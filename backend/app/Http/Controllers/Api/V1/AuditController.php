<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use Illuminate\Http\Request;

/** Audit logs — Firestore-backed. Admin-only access. */
class AuditController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    public function index(Request $request)
    {
        $user = $this->userResolver->resolve($request);
        abort_unless(UserResolver::isAdmin($user), 403, 'Admin only.');

        $logs = $this->firestore->all('auditLogs');
        usort($logs, fn ($a, $b) => ($b['created_at'] ?? '') <=> ($a['created_at'] ?? ''));
        $logs = array_slice($logs, 0, 100);

        return response()->json(['data' => array_map(fn ($l) => [
            'id' => $l['numericId'] ?? 0,
            'action' => $l['action'] ?? '',
            'user_id' => $l['userId'] ?? 0,
            'created_at' => $l['created_at'] ?? '',
        ], $logs)]);
    }
}
