<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

class StoreProduct extends Model
{
    protected $fillable = [
        'store_id', 'product_id', 'price', 'unit', 'quantity',
        'availability', 'status', 'last_confirmed_at',
    ];

    protected function casts(): array
    {
        return [
            'price' => 'float',
            'last_confirmed_at' => 'datetime',
        ];
    }

    public function store(): BelongsTo
    {
        return $this->belongsTo(Store::class);
    }

    public function product(): BelongsTo
    {
        return $this->belongsTo(Product::class);
    }

    public function movements(): HasMany
    {
        return $this->hasMany(StockMovement::class);
    }

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'store_id' => $this->store_id,
            'product_id' => $this->product_id,
            'price' => $this->price,
            'unit' => $this->unit,
            'quantity' => $this->quantity,
            'availability' => $this->availability,
            'status' => $this->status,
            'last_confirmed_at' => optional($this->last_confirmed_at)?->toIso8601String(),
        ];
    }
}
