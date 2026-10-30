<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('recognition_jobs', function (Blueprint $table) {
            $table->id();
            $table->string('hint')->nullable();
            $table->string('barcode')->nullable();
            $table->string('status', 32)->default('ready');
            $table->json('suggestions')->nullable();
            $table->timestamp('confirmed_at')->nullable();
            $table->timestamps();
        });

        Schema::table('tour_nodes', function (Blueprint $table) {
            $table->string('original_image')->nullable()->after('image');
        });
    }

    public function down(): void
    {
        Schema::table('tour_nodes', function (Blueprint $table) {
            $table->dropColumn('original_image');
        });
        Schema::dropIfExists('recognition_jobs');
    }
};
