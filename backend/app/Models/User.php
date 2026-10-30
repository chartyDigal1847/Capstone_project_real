<?php

namespace App\Models;

use Database\Factories\UserFactory;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Relations\BelongsToMany;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Laravel\Sanctum\HasApiTokens;

class User extends Authenticatable
{
    /** @use HasFactory<UserFactory> */
    use HasApiTokens, HasFactory, Notifiable;

    protected $fillable = [
        'name',
        'email',
        'password',
        'role',
        'status',
    ];

    protected $hidden = [
        'password',
        'remember_token',
    ];

    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'password' => 'hashed',
        ];
    }

    public function ownedStores(): HasMany
    {
        return $this->hasMany(Store::class, 'owner_id');
    }

    public function memberStores(): BelongsToMany
    {
        return $this->belongsToMany(Store::class, 'store_members')
            ->withPivot('membership_role', 'can_inventory', 'can_promotions', 'can_location');
    }

    public function isAdmin(): bool
    {
        return $this->role === 'admin';
    }

    public function canManage(Store $store): bool
    {
        if ($this->isAdmin()) {
            return true;
        }
        if (! in_array($this->role, ['owner', 'staff'], true)) {
            return false;
        }
        if ((int) $store->owner_id === (int) $this->id) {
            return true;
        }

        return $this->memberStores()->where('stores.id', $store->id)->exists();
    }

    public function hasStoreGrant(Store $store, string $grant): bool
    {
        if ($this->isAdmin() || (int) $store->owner_id === (int) $this->id) {
            return true;
        }
        $member = $this->memberStores()->where('stores.id', $store->id)->first();
        if ($member === null) {
            return false;
        }
        $column = match ($grant) {
            'inventory' => 'can_inventory',
            'promotions' => 'can_promotions',
            'location' => 'can_location',
            default => null,
        };

        return $column !== null && (bool) $member->pivot->{$column};
    }

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'email' => $this->email,
            'role' => $this->role,
            'status' => $this->status,
            'owned_store_ids' => $this->ownedStores()->pluck('id')->values()->all(),
            'member_store_ids' => $this->memberStores()->pluck('stores.id')->values()->all(),
            'store_grants' => $this->memberStores->map(fn (Store $store) => [
                'store_id' => $store->id,
                'inventory' => (bool) $store->pivot->can_inventory,
                'promotions' => (bool) $store->pivot->can_promotions,
                'location' => (bool) $store->pivot->can_location,
            ])->values()->all(),
        ];
    }
}
