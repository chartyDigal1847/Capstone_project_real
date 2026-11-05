<?php

namespace App\Support;

use App\Services\FirestoreService;

/**
 * Audit log helper — Firestore-backed.
 *
 * Note: Most controllers now write audit entries directly via FirestoreService.
 * This helper is retained for convenience and backward compatibility.
 */
class Audit
{
    public static function record(?array $user, string $action, ?string $subjectType = null, ?int $subjectId = null, array $meta = []): void
    {
        $firestore = app(FirestoreService::class);
        $firestore->create('auditLogs', [
            'numericId' => abs(crc32(uniqid())) & 0x7fffffff,
            'userId' => $user['numericId'] ?? 0,
            'action' => $action,
            'subject_type' => $subjectType,
            'subject_id' => $subjectId,
            'meta' => $meta === [] ? null : $meta,
            'created_at' => now()->toIso8601String(),
        ]);
    }
}
