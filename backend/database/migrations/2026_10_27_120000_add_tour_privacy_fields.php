<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('tour_nodes', function (Blueprint $table) {
            $table->string('privacy_status', 32)->default('ready');
            $table->boolean('owner_reviewed')->default(false);
            $table->boolean('manual_blur')->default(false);
        });
    }

    public function down(): void
    {
        Schema::table('tour_nodes', function (Blueprint $table) {
            $table->dropColumn(['privacy_status', 'owner_reviewed', 'manual_blur']);
        });
    }
};
