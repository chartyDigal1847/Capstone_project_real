<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('store_members', function (Blueprint $table) {
            $table->boolean('can_inventory')->default(true);
            $table->boolean('can_promotions')->default(false);
            $table->boolean('can_location')->default(false);
        });
    }

    public function down(): void
    {
        Schema::table('store_members', function (Blueprint $table) {
            $table->dropColumn(['can_inventory', 'can_promotions', 'can_location']);
        });
    }
};
