<?php

namespace App\Policies;

use App\Models\Store;
use App\Models\StoreTour;
use App\Models\User;

class StoreTourPolicy
{
    public function create(User $user, Store $store): bool
    {
        return $user->canManage($store);
    }

    public function update(User $user, StoreTour $storeTour): bool
    {
        return $user->canManage($storeTour->store);
    }
}
