<?php

namespace App\Policies;

use App\Models\Report;
use App\Models\User;

class ReportPolicy
{
    public function create(User $user): bool
    {
        return $user->status === 'active';
    }

    public function viewAny(User $user): bool
    {
        return $user->isAdmin();
    }

    public function update(User $user, Report $report): bool
    {
        return $user->isAdmin();
    }
}
