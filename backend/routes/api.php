<?php

use App\Http\Controllers\Api\V1\AuditController;
use App\Http\Controllers\Api\V1\AuthController;
use App\Http\Controllers\Api\V1\CatalogController;
use App\Http\Controllers\Api\V1\FavoriteController;
use App\Http\Controllers\Api\V1\FeedbackController;
use App\Http\Controllers\Api\V1\HealthController;
use App\Http\Controllers\Api\V1\PromotionController;
use App\Http\Controllers\Api\V1\RecognitionController;
use App\Http\Controllers\Api\V1\ReportController;
use App\Http\Controllers\Api\V1\RoutePreviewController;
use App\Http\Controllers\Api\V1\StoreController;
use App\Http\Controllers\Api\V1\StoreProductController;
use App\Http\Controllers\Api\V1\TourController;
use App\Http\Controllers\Api\V1\VendorLocationSessionController;
use Illuminate\Support\Facades\Route;

Route::prefix('v1')->group(function () {
    Route::get('health', [HealthController::class, 'show']);
    Route::post('auth/register', [AuthController::class, 'register'])->middleware('throttle:login');
    Route::post('auth/login', [AuthController::class, 'login'])->middleware('throttle:login');

    Route::get('catalog', [CatalogController::class, 'bootstrap']);
    Route::get('stores/nearby', [CatalogController::class, 'nearbyStores'])->middleware('throttle:search');
    Route::get('stores/{store}', [CatalogController::class, 'showStore']);
    Route::get('products/search', [CatalogController::class, 'searchProducts'])->middleware('throttle:search');
    Route::get('store-products/search', [CatalogController::class, 'searchListings'])->middleware('throttle:search');
    Route::get('search', [CatalogController::class, 'searchListings'])->middleware('throttle:search');
    Route::get('categories', [CatalogController::class, 'categories']);
    Route::post('product-recognition/suggest', [RecognitionController::class, 'suggest'])->middleware('throttle:recognition');
    Route::get('product-recognition/jobs/{job}', [RecognitionController::class, 'show'])->middleware('throttle:recognition');
    Route::post('search/by-image', [CatalogController::class, 'searchByImage'])->middleware('throttle:search');
    Route::post('routes/preview', [RoutePreviewController::class, 'preview'])->middleware('throttle:routing');

    Route::middleware('auth:sanctum')->group(function () {
        Route::get('me', [AuthController::class, 'me']);
        Route::get('auth/me', [AuthController::class, 'me']);
        Route::delete('auth/logout', [AuthController::class, 'logout']);
        Route::post('auth/logout', [AuthController::class, 'logout']);

        Route::post('stores', [StoreController::class, 'store']);
        Route::patch('stores/{store}', [StoreController::class, 'update']);
        Route::post('stores/{store}/location-sessions', [VendorLocationSessionController::class, 'start'])->middleware('throttle:location');
        Route::get('stores/{store}/location-sessions/current', [VendorLocationSessionController::class, 'current']);
        Route::patch('stores/{store}/location-sessions/current', [VendorLocationSessionController::class, 'updateCurrent'])->middleware('throttle:location');
        Route::delete('stores/{store}/location-sessions/current', [VendorLocationSessionController::class, 'stop']);
        Route::post('stores/{store}/staff', [StoreController::class, 'inviteStaff']);
        Route::patch('stores/{store}/staff/{user}', [StoreController::class, 'updateStaff']);
        Route::post('stores/{store}/products', [StoreProductController::class, 'store']);
        Route::patch('store-products/{storeProduct}', [StoreProductController::class, 'update']);
        Route::get('store-products/{storeProduct}/movements', [StoreProductController::class, 'movements']);
        Route::post('stores/{store}/promotions', [PromotionController::class, 'store']);
        Route::post('stores/{store}/tours', [TourController::class, 'store']);
        Route::post('tours/{storeTour}/nodes', [TourController::class, 'addNode']);
        Route::post('tours/{storeTour}/connections', [TourController::class, 'connect']);
        Route::post('tours/{storeTour}/publish', [TourController::class, 'publish']);
        Route::post('tours/{storeTour}/nodes/{tourNode}/review', [TourController::class, 'reviewNode']);
        Route::post('tours/{storeTour}/nodes/{tourNode}/manual-blurs', [TourController::class, 'addManualBlur']);
        Route::post('tours/{storeTour}/nodes/{tourNode}/process', [TourController::class, 'processNode']);
        Route::post('tours/{storeTour}/nodes/{tourNode}/hotspots', [TourController::class, 'addHotspot']);
        Route::delete('tours/{storeTour}/nodes/{tourNode}/hotspots/{tourHotspot}', [TourController::class, 'deleteHotspot']);
        Route::post('tours/{storeTour}/media', [TourController::class, 'addNode']);
        Route::get('tour-media/{tourNode}/status', [TourController::class, 'mediaStatus']);
        Route::post('tour-media/{tourNode}/manual-blurs', [TourController::class, 'addManualBlurForMedia']);
        Route::post('product-recognition/{job}/confirm', [RecognitionController::class, 'confirm']);
        Route::post('reports', [ReportController::class, 'store']);
        Route::post('feedback', [FeedbackController::class, 'store']);
        Route::get('favorites', [FavoriteController::class, 'index']);
        Route::post('favorites/toggle', [FavoriteController::class, 'toggle']);

        Route::get('admin/reports', [ReportController::class, 'index']);
        Route::get('admin/audit', [AuditController::class, 'index']);
        Route::get('admin/feedback', [FeedbackController::class, 'index']);
        Route::patch('admin/reports/{report}', [ReportController::class, 'resolve']);
        Route::patch('admin/stores/{store}', [StoreController::class, 'setStatus']);
        Route::patch('admin/promotions/{promotion}', [PromotionController::class, 'setStatus']);
    });
});
