<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use Illuminate\Http\Request;

/** Feedback — Firestore-backed. */
class FeedbackController extends Controller
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
            'topic' => ['required', 'string', 'max:80'],
            'body' => ['required', 'string', 'max:2000'],
            'area' => ['nullable', 'string', 'max:120'],
        ]);

        $id = abs(crc32(uniqid())) & 0x7fffffff;
        $this->firestore->create('feedback', [
            'numericId' => $id,
            'userId' => $user['numericId'],
            'uid' => $request->attributes->get('firebase_uid'),
            'topic' => $data['topic'],
            'body' => $data['body'],
            'area' => $data['area'] ?? '',
        ]);

        return response()->json(['data' => ['id' => $id]], 201);
    }

    public function index(Request $request)
    {
        $user = $this->userResolver->resolve($request);
        abort_unless(UserResolver::isAdmin($user), 403, 'Admin only.');

        $feedback = $this->firestore->all('feedback');

        usort($feedback, fn ($a, $b) => ($a['topic'] ?? '') <=> ($b['topic'] ?? ''));

        return response()->json(['data' => array_map(fn ($f) => [
            'id' => $f['numericId'] ?? 0,
            'user_id' => $f['userId'] ?? 0,
            'topic' => $f['topic'] ?? '',
            'body' => $f['body'] ?? '',
            'area' => $f['area'] ?? '',
        ], $feedback)]);
    }
}
