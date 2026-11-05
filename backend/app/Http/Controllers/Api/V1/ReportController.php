<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use Illuminate\Http\Request;

/** Reports — Firestore-backed. */
class ReportController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    public function store(Request $request)
    {
        $user = $this->userResolver->resolve($request);

        $data = $request->validate([
            'target' => ['required', 'string', 'max:190'],
            'reason' => ['required', 'string'],
        ]);

        $id = abs(crc32(uniqid())) & 0x7fffffff;
        $this->firestore->create('reports', [
            'numericId' => $id,
            'userId' => $user['numericId'],
            'uid' => $request->attributes->get('firebase_uid'),
            'target' => $data['target'],
            'reason' => $data['reason'],
            'resolved' => false,
        ]);

        return response()->json(['data' => ['id' => $id]], 201);
    }

    public function index(Request $request)
    {
        $user = $this->userResolver->resolve($request);
        abort_unless(UserResolver::isAdmin($user), 403, 'Admin only.');

        $reports = $this->firestore->all('reports');

        return response()->json(['data' => array_map(fn ($r) => [
            'id' => $r['numericId'] ?? 0,
            'user_id' => $r['userId'] ?? 0,
            'target' => $r['target'] ?? '',
            'reason' => $r['reason'] ?? '',
            'resolved' => $r['resolved'] ?? false,
        ], $reports)]);
    }

    public function resolve(Request $request, int $reportId)
    {
        $user = $this->userResolver->resolve($request);
        abort_unless(UserResolver::isAdmin($user), 403, 'Admin only.');

        $this->firestore->updateByNumericId('reports', $reportId, ['resolved' => true]);

        return response()->json(['data' => true]);
    }
}
