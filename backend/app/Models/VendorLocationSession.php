<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class VendorLocationSession extends Model
{
    protected $fillable = [
        'store_id', 'started_by', 'lat', 'lng',
        'started_at', 'last_update_at', 'expires_at', 'ended_at',
    ];

    protected function casts(): array
    {
        return [
            'lat' => 'float',
            'lng' => 'float',
            'started_at' => 'datetime',
            'last_update_at' => 'datetime',
            'expires_at' => 'datetime',
            'ended_at' => 'datetime',
        ];
    }

    public function store(): BelongsTo
    {
        return $this->belongsTo(Store::class);
    }

    public function starter(): BelongsTo
    {
        return $this->belongsTo(User::class, 'started_by');
    }

    public function scopeActive(Builder $query): Builder
    {
        return $query->whereNull('ended_at')->where('expires_at', '>', now());
    }

    public function isActive(): bool
    {
        return $this->ended_at === null && $this->expires_at?->isFuture();
    }

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'store_id' => $this->store_id,
            'lat' => $this->lat,
            'lng' => $this->lng,
            'active' => $this->isActive(),
            'started_at' => $this->started_at?->toIso8601String(),
            'last_update_at' => $this->last_update_at?->toIso8601String(),
            'expires_at' => $this->expires_at?->toIso8601String(),
            'ended_at' => $this->ended_at?->toIso8601String(),
        ];
    }
}
