<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

class Product extends Model
{
    protected $fillable = [
        'name', 'category', 'brand', 'package_size', 'barcode', 'image', 'status', 'specs',
    ];

    protected $casts = [
        'specs' => 'array',
    ];

    public function aliases(): HasMany
    {
        return $this->hasMany(ProductAlias::class);
    }

    public function listings(): HasMany
    {
        return $this->hasMany(StoreProduct::class);
    }

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'category' => $this->category,
            'brand' => $this->brand ?? '',
            'package_size' => $this->package_size ?? '',
            'barcode' => $this->barcode,
            'image' => $this->image,
            'aliases' => $this->aliases->pluck('alias')->values()->all(),
            'attributes' => $this->specs ?? [],
        ];
    }
}
