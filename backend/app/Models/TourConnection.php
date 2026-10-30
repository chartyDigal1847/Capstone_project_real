<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class TourConnection extends Model
{
    protected $fillable = ['from_node_id', 'to_node_id'];
}
