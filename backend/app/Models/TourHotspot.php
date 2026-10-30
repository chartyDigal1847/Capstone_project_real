<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class TourHotspot extends Model
{
    protected $fillable = ['tour_node_id', 'product_id', 'x', 'y', 'label'];

    protected $casts = [
        'x' => 'float',
        'y' => 'float',
    ];

    public function node(): BelongsTo
    {
        return $this->belongsTo(TourNode::class, 'tour_node_id');
    }

    public function product(): BelongsTo
    {
        return $this->belongsTo(Product::class);
    }

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'product_id' => $this->product_id,
            'x' => $this->x,
            'y' => $this->y,
            'label' => $this->label ?: $this->product?->name,
        ];
    }
}
