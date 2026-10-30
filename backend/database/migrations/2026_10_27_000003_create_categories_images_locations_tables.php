<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('categories', function (Blueprint $table) {
            $table->id();
            $table->string('kind', 32);
            $table->string('name');
            $table->string('slug')->unique();
            $table->timestamps();
        });

        Schema::create('product_images', function (Blueprint $table) {
            $table->id();
            $table->foreignId('product_id')->nullable()->constrained()->nullOnDelete();
            $table->foreignId('store_product_id')->nullable()->constrained('store_products')->nullOnDelete();
            $table->string('path');
            $table->string('kind', 32)->default('photo');
            $table->string('processing_status', 32)->default('ready');
            $table->string('moderation_status', 32)->default('approved');
            $table->timestamps();
        });

        Schema::create('store_locations', function (Blueprint $table) {
            $table->id();
            $table->foreignId('store_id')->constrained()->cascadeOnDelete();
            $table->string('kind', 32)->default('current');
            $table->decimal('lat', 10, 7);
            $table->decimal('lng', 10, 7);
            $table->string('note')->nullable();
            $table->timestamp('updated_public_at')->nullable();
            $table->timestamps();
            $table->index(['store_id', 'kind']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('store_locations');
        Schema::dropIfExists('product_images');
        Schema::dropIfExists('categories');
    }
};
