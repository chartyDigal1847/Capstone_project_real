<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('tour_nodes', function (Blueprint $table) {
            $table->json('blur_regions')->nullable()->after('manual_blur');
            $table->timestamp('original_expires_at')->nullable()->after('original_image');
        });
    }

    public function down(): void
    {
        Schema::table('tour_nodes', function (Blueprint $table) {
            $table->dropColumn(['blur_regions', 'original_expires_at']);
        });
    }
};
