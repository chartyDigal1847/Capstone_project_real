<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class Report extends Model
{
    protected $fillable = ['user_id', 'target', 'reason', 'resolved'];

    protected function casts(): array
    {
        return ['resolved' => 'boolean'];
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'user_id' => $this->user_id,
            'target' => $this->target,
            'reason' => $this->reason,
            'resolved' => $this->resolved,
        ];
    }
}
