<?php

namespace App\Policies;

use App\Models\Store;
use App\Models\StoreProduct;
use App\Models\User;

class StoreProductPolicy
{
    public function create(User $user, Store $store): bool
    {
        return $user->hasStoreGrant($store, 'inventory');
    }

    public function update(User $user, StoreProduct $storeProduct): bool
    {
        return $user->hasStoreGrant($storeProduct->store, 'inventory');
    }
}
