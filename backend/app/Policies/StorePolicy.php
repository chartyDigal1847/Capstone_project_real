<?php

namespace App\Policies;

use App\Models\Store;
use App\Models\User;

class StorePolicy
{
    public function create(User $user): bool
    {
        return in_array($user->role, ['owner', 'admin'], true);
    }

    public function update(User $user, Store $store): bool
    {
        return $user->canManage($store);
    }

    public function setStatus(User $user, Store $store): bool
    {
        return $user->isAdmin();
    }

    public function invite(User $user, Store $store): bool
    {
        return $user->isAdmin() || (int) $store->owner_id === (int) $user->id;
    }

    public function shareLiveLocation(User $user, Store $store): bool
    {
        return $user->hasStoreGrant($store, 'location');
    }
}
