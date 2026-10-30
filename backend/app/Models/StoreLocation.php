<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class StoreLocation extends Model
{
    protected $fillable = ['store_id', 'kind', 'lat', 'lng', 'note', 'updated_public_at'];

    protected function casts(): array
    {
        return [
            'lat' => 'float',
            'lng' => 'float',
            'updated_public_at' => 'datetime',
        ];
    }

    public function store(): BelongsTo
    {
        return $this->belongsTo(Store::class);
    }
}
