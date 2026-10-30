<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\BelongsToMany;
use Illuminate\Database\Eloquent\Relations\HasMany;

class Store extends Model
{
    protected $fillable = [
        'owner_id', 'name', 'type', 'status', 'lat', 'lng', 'barangay', 'city',
        'address', 'landmark', 'schedule', 'is_mobile', 'image', 'verification_note',
    ];

    protected function casts(): array
    {
        return [
            'lat' => 'float',
            'lng' => 'float',
            'is_mobile' => 'boolean',
        ];
    }

    public function owner(): BelongsTo
    {
        return $this->belongsTo(User::class, 'owner_id');
    }

    public function members(): BelongsToMany
    {
        return $this->belongsToMany(User::class, 'store_members')
            ->withPivot('membership_role', 'can_inventory', 'can_promotions', 'can_location')
            ->withTimestamps();
    }

    public function listings(): HasMany
    {
        return $this->hasMany(StoreProduct::class);
    }

    public function promotions(): HasMany
    {
        return $this->hasMany(Promotion::class);
    }

    public function tours(): HasMany
    {
        return $this->hasMany(StoreTour::class);
    }

    public function locations(): HasMany
    {
        return $this->hasMany(StoreLocation::class);
    }

    public function locationSessions(): HasMany
    {
        return $this->hasMany(VendorLocationSession::class);
    }

    public function publicLocation(): array
    {
        $sessions = $this->relationLoaded('locationSessions')
            ? $this->locationSessions
            : $this->locationSessions()->orderByDesc('id')->get();
        $active = $sessions->first(fn (VendorLocationSession $session) => $session->isActive());
        if ($active) {
            return [
                'lat' => $active->lat,
                'lng' => $active->lng,
                'location_mode' => 'live',
                'location_updated_at' => $active->last_update_at?->toIso8601String(),
                'live_session' => $active->toApi(),
            ];
        }

        $latest = $sessions->sortByDesc('id')->first();
        $mode = $this->is_mobile ? 'regular' : 'fixed';
        if ($this->is_mobile && $latest && ! $latest->isActive()) {
            $expired = $latest->expires_at?->isPast() ?? false;
            $stoppedEarly = $latest->ended_at !== null && $latest->expires_at !== null && $latest->ended_at->lt($latest->expires_at);
            if ($expired && ! $stoppedEarly) {
                $mode = 'stale';
            }
        }

        return [
            'lat' => $this->lat,
            'lng' => $this->lng,
            'location_mode' => $mode,
            'location_updated_at' => $latest?->last_update_at?->toIso8601String(),
            'live_session' => null,
        ];
    }

    public function toApi(): array
    {
        $point = $this->publicLocation();

        return [
            'id' => $this->id,
            'owner_id' => $this->owner_id,
            'name' => $this->name,
            'type' => $this->type,
            'status' => $this->status,
            'lat' => $point['lat'],
            'lng' => $point['lng'],
            'registered_lat' => $this->lat,
            'registered_lng' => $this->lng,
            'location_mode' => $point['location_mode'],
            'location_updated_at' => $point['location_updated_at'],
            'live_session' => $point['live_session'],
            'barangay' => $this->barangay,
            'city' => $this->city,
            'address' => $this->address,
            'landmark' => $this->landmark,
            'schedule' => $this->schedule,
            'is_mobile' => $this->is_mobile,
            'image' => $this->image,
            'verification_note' => $this->verification_note,
        ];
    }
}
