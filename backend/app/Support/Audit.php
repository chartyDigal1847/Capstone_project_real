<?php

namespace App\Support;

use App\Models\User;
use Illuminate\Support\Facades\DB;

class Audit
{
    public static function record(?User $user, string $action, ?string $subjectType = null, ?int $subjectId = null, array $meta = []): void
    {
        DB::table('audit_logs')->insert([
            'user_id' => $user?->id,
            'action' => $action,
            'subject_type' => $subjectType,
            'subject_id' => $subjectId,
            'meta' => $meta === [] ? null : json_encode($meta),
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }
}
