<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\BelongsToMany;
use Illuminate\Database\Eloquent\Relations\HasMany;

class TourNode extends Model
{
    protected $fillable = [
        'store_tour_id', 'title', 'image', 'original_image', 'original_expires_at',
        'sort_order', 'privacy_status', 'owner_reviewed', 'manual_blur', 'blur_regions',
    ];

    protected $casts = [
        'owner_reviewed' => 'boolean',
        'manual_blur' => 'boolean',
        'blur_regions' => 'array',
        'original_expires_at' => 'datetime',
    ];

    public function tour(): BelongsTo
    {
        return $this->belongsTo(StoreTour::class, 'store_tour_id');
    }

    public function outgoing(): HasMany
    {
        return $this->hasMany(TourConnection::class, 'from_node_id');
    }

    public function connectedNodes(): BelongsToMany
    {
        return $this->belongsToMany(self::class, 'tour_connections', 'from_node_id', 'to_node_id');
    }

    public function hotspots(): HasMany
    {
        return $this->hasMany(TourHotspot::class);
    }

    public function toApi(bool $forPublic = false): array
    {
        $this->loadMissing(['outgoing', 'hotspots.product']);
        $payload = [
            'id' => $this->id,
            'title' => $this->title,
            'image' => $this->image,
            'connections' => $this->outgoing->pluck('to_node_id')->values()->all(),
            'privacy_status' => $this->privacy_status ?? 'ready',
            'owner_reviewed' => (bool) $this->owner_reviewed,
            'manual_blur' => (bool) $this->manual_blur,
            'blur_regions' => $this->blur_regions ?? [],
            'hotspots' => $this->hotspots->map->toApi()->values()->all(),
        ];
        if (! $forPublic) {
            $payload['original_retained'] = filled($this->original_image);
            $payload['original_expires_at'] = optional($this->original_expires_at)?->toIso8601String();
        }

        return $payload;
    }
}
