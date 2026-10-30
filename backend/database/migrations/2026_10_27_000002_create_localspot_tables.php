<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('stores', function (Blueprint $table) {
            $table->id();
            $table->foreignId('owner_id')->constrained('users')->cascadeOnDelete();
            $table->string('name');
            $table->string('type', 64);
            $table->string('status', 32)->default('pending')->index();
            $table->decimal('lat', 10, 7);
            $table->decimal('lng', 10, 7);
            $table->string('barangay')->nullable();
            $table->string('city');
            $table->string('address')->nullable();
            $table->string('landmark')->nullable();
            $table->string('schedule')->nullable();
            $table->boolean('is_mobile')->default(false);
            $table->string('image')->nullable();
            $table->text('verification_note')->nullable();
            $table->timestamps();
            $table->index(['lat', 'lng']);
        });

        Schema::create('store_members', function (Blueprint $table) {
            $table->id();
            $table->foreignId('store_id')->constrained()->cascadeOnDelete();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->string('membership_role', 32)->default('staff');
            $table->json('permissions')->nullable();
            $table->timestamps();
            $table->unique(['store_id', 'user_id']);
        });

        Schema::create('products', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->string('category')->index();
            $table->string('brand')->nullable();
            $table->string('package_size')->nullable();
            $table->string('barcode')->nullable()->index();
            $table->string('image')->nullable();
            $table->string('status', 32)->default('active');
            $table->timestamps();
        });

        Schema::create('product_aliases', function (Blueprint $table) {
            $table->id();
            $table->foreignId('product_id')->constrained()->cascadeOnDelete();
            $table->string('alias');
            $table->timestamps();
            $table->index('alias');
        });

        Schema::create('store_products', function (Blueprint $table) {
            $table->id();
            $table->foreignId('store_id')->constrained()->cascadeOnDelete();
            $table->foreignId('product_id')->constrained()->cascadeOnDelete();
            $table->decimal('price', 10, 2);
            $table->string('unit', 32);
            $table->unsignedInteger('quantity')->default(0);
            $table->string('availability', 32)->default('in_stock');
            $table->string('status', 32)->default('active')->index();
            $table->timestamp('last_confirmed_at')->nullable();
            $table->timestamps();
            $table->index(['product_id', 'store_id']);
        });

        Schema::create('stock_movements', function (Blueprint $table) {
            $table->id();
            $table->foreignId('store_product_id')->constrained('store_products')->cascadeOnDelete();
            $table->foreignId('user_id')->nullable()->constrained('users')->nullOnDelete();
            $table->string('kind', 32);
            $table->integer('quantity_delta')->default(0);
            $table->string('note')->nullable();
            $table->timestamps();
        });

        Schema::create('promotions', function (Blueprint $table) {
            $table->id();
            $table->foreignId('store_id')->constrained()->cascadeOnDelete();
            $table->string('title');
            $table->text('offer');
            $table->timestamp('starts_at')->nullable();
            $table->timestamp('ends_at')->nullable();
            $table->boolean('sponsored')->default(false);
            $table->string('status', 32)->default('pending')->index();
            $table->timestamps();
        });

        Schema::create('store_tours', function (Blueprint $table) {
            $table->id();
            $table->foreignId('store_id')->constrained()->cascadeOnDelete();
            $table->string('title');
            $table->string('status', 32)->default('draft');
            $table->timestamps();
        });

        Schema::create('tour_nodes', function (Blueprint $table) {
            $table->id();
            $table->foreignId('store_tour_id')->constrained('store_tours')->cascadeOnDelete();
            $table->string('title');
            $table->string('image');
            $table->unsignedInteger('sort_order')->default(0);
            $table->timestamps();
        });

        Schema::create('tour_connections', function (Blueprint $table) {
            $table->id();
            $table->foreignId('from_node_id')->constrained('tour_nodes')->cascadeOnDelete();
            $table->foreignId('to_node_id')->constrained('tour_nodes')->cascadeOnDelete();
            $table->timestamps();
        });

        Schema::create('favorites', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->string('favoritable_type', 32);
            $table->unsignedBigInteger('favoritable_id');
            $table->timestamps();
            $table->unique(['user_id', 'favoritable_type', 'favoritable_id']);
        });

        Schema::create('reports', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->string('target');
            $table->text('reason');
            $table->boolean('resolved')->default(false);
            $table->timestamps();
        });

        Schema::create('audit_logs', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->nullable()->constrained('users')->nullOnDelete();
            $table->string('action');
            $table->string('subject_type')->nullable();
            $table->unsignedBigInteger('subject_id')->nullable();
            $table->text('meta')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('audit_logs');
        Schema::dropIfExists('reports');
        Schema::dropIfExists('favorites');
        Schema::dropIfExists('tour_connections');
        Schema::dropIfExists('tour_nodes');
        Schema::dropIfExists('store_tours');
        Schema::dropIfExists('promotions');
        Schema::dropIfExists('stock_movements');
        Schema::dropIfExists('store_products');
        Schema::dropIfExists('product_aliases');
        Schema::dropIfExists('products');
        Schema::dropIfExists('store_members');
        Schema::dropIfExists('stores');
    }
};
