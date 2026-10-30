<?php

namespace App\Policies;

use App\Models\Promotion;
use App\Models\Store;
use App\Models\User;

class PromotionPolicy
{
    public function create(User $user, Store $store): bool
    {
        return $user->hasStoreGrant($store, 'promotions');
    }

    public function setStatus(User $user, Promotion $promotion): bool
    {
        return $user->isAdmin();
    }
}
