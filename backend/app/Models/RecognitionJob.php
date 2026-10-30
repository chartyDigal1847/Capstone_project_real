<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class RecognitionJob extends Model
{
    protected $fillable = ['hint', 'barcode', 'ocr_text', 'status', 'suggestions', 'objects', 'confirmed_at'];

    protected $casts = [
        'suggestions' => 'array',
        'objects' => 'array',
        'confirmed_at' => 'datetime',
    ];

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'status' => $this->status,
            'suggestions' => $this->suggestions ?? [],
            'objects' => $this->objects ?? [],
            'ocr' => $this->ocr_text,
            'confirmed_at' => optional($this->confirmed_at)?->toIso8601String(),
        ];
    }
}
