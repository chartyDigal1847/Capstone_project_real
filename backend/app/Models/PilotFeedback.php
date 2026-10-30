<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class PilotFeedback extends Model
{
    protected $table = 'pilot_feedback';

    protected $fillable = ['user_id', 'topic', 'body', 'area'];

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function toApi(): array
    {
        return [
            'id' => $this->id,
            'user_id' => $this->user_id,
            'topic' => $this->topic,
            'body' => $this->body,
            'area' => $this->area,
            'created_at' => optional($this->created_at)?->toIso8601String(),
        ];
    }
}
