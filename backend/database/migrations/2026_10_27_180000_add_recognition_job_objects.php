<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('recognition_jobs', function (Blueprint $table) {
            $table->string('ocr_text')->nullable()->after('barcode');
            $table->json('objects')->nullable()->after('suggestions');
        });
    }

    public function down(): void
    {
        Schema::table('recognition_jobs', function (Blueprint $table) {
            $table->dropColumn(['ocr_text', 'objects']);
        });
    }
};
