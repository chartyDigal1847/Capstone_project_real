<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

class StoreTour extends Model
{
    protected $fillable = ['store_id', 'title', 'status'];

    public function store(): BelongsTo
    {
        return $this->belongsTo(Store::class);
    }

    public function nodes(): HasMany
    {
        return $this->hasMany(TourNode::class);
    }

    public function toApi(bool $forPublic = false): array
    {
        $this->loadMissing(['nodes.outgoing', 'nodes.hotspots.product']);
        $nodes = $this->nodes;
        if ($forPublic) {
            $nodes = $nodes->filter(fn (TourNode $node) => $node->privacy_status === 'ready' && filled($node->image));
        }

        return [
            'id' => $this->id,
            'store_id' => $this->store_id,
            'title' => $this->title,
            'status' => $this->status,
            'nodes' => $nodes->map(fn (TourNode $node) => $node->toApi($forPublic))->values()->all(),
        ];
    }
}
