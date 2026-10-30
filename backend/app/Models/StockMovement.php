<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class StockMovement extends Model
{
    protected $fillable = ['store_product_id', 'user_id', 'kind', 'quantity_delta', 'note'];

    public function listing(): BelongsTo
    {
        return $this->belongsTo(StoreProduct::class, 'store_product_id');
    }

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'store_product_id' => $this->store_product_id,
            'kind' => $this->kind,
            'quantity_delta' => $this->quantity_delta,
            'note' => $this->note,
            'created_at' => optional($this->created_at)?->toIso8601String(),
        ];
    }
}
