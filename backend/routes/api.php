<?php

use App\Http\Controllers\Api\V1\AuditController;
use App\Http\Controllers\Api\V1\AuthController;
use App\Http\Controllers\Api\V1\CatalogController;
use App\Http\Controllers\Api\V1\FavoriteController;
use App\Http\Controllers\Api\V1\FeedbackController;
use App\Http\Controllers\Api\V1\HealthController;
use App\Http\Controllers\Api\V1\MediaController;
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
    Route::post('auth/register', [AuthController::class, 'register'])->middleware(['throttle:login', 'firebase.auth']);
    Route::post('auth/login', [AuthController::class, 'login'])->middleware(['throttle:login', 'firebase.auth']);

    Route::get('catalog', [CatalogController::class, 'bootstrap']);
    Route::get('stores/nearby', [CatalogController::class, 'nearbyStores'])->middleware('throttle:search');
    Route::get('stores/{storeId}', [CatalogController::class, 'showStore']);
    Route::get('products/search', [CatalogController::class, 'searchProducts'])->middleware('throttle:search');
    Route::get('store-products/search', [CatalogController::class, 'searchListings'])->middleware('throttle:search');
    Route::get('search', [CatalogController::class, 'searchListings'])->middleware('throttle:search');
    Route::get('categories', [CatalogController::class, 'categories']);
    Route::post('product-recognition/suggest', [RecognitionController::class, 'suggest'])->middleware('throttle:recognition');
    Route::get('product-recognition/jobs/{job}', [RecognitionController::class, 'show'])->middleware('throttle:recognition');
    Route::post('search/by-image', [CatalogController::class, 'searchByImage'])->middleware('throttle:search');
    Route::post('routes/preview', [RoutePreviewController::class, 'preview'])->middleware('throttle:routing');

    Route::middleware('firebase.auth')->group(function () {
        Route::get('me', [AuthController::class, 'me']);
        Route::get('auth/me', [AuthController::class, 'me']);
        Route::delete('auth/logout', [AuthController::class, 'logout']);
        Route::post('auth/logout', [AuthController::class, 'logout']);

        Route::post('stores', [StoreController::class, 'store']);
        Route::patch('stores/{storeId}', [StoreController::class, 'update']);
        Route::post('stores/{storeId}/location-sessions', [VendorLocationSessionController::class, 'start'])->middleware('throttle:location');
        Route::get('stores/{storeId}/location-sessions/current', [VendorLocationSessionController::class, 'current']);
        Route::patch('stores/{storeId}/location-sessions/current', [VendorLocationSessionController::class, 'updateCurrent'])->middleware('throttle:location');
        Route::delete('stores/{storeId}/location-sessions/current', [VendorLocationSessionController::class, 'stop']);
        Route::post('stores/{storeId}/staff', [StoreController::class, 'inviteStaff']);
        Route::patch('stores/{storeId}/staff/{userId}', [StoreController::class, 'updateStaff']);
        Route::post('stores/{storeId}/products', [StoreProductController::class, 'store']);
        Route::patch('store-products/{listingId}', [StoreProductController::class, 'update']);
        Route::get('store-products/{listingId}/movements', [StoreProductController::class, 'movements']);
        Route::post('stores/{storeId}/promotions', [PromotionController::class, 'store']);
        Route::post('stores/{storeId}/tours', [TourController::class, 'store']);
        Route::post('tours/{tourId}/nodes', [TourController::class, 'addNode']);
        Route::post('tours/{tourId}/connections', [TourController::class, 'connect']);
        Route::post('tours/{tourId}/publish', [TourController::class, 'publish']);
        Route::post('tours/{tourId}/nodes/{nodeId}/review', [TourController::class, 'reviewNode']);
        Route::post('tours/{tourId}/nodes/{nodeId}/manual-blurs', [TourController::class, 'addManualBlur']);
        Route::post('tours/{tourId}/nodes/{nodeId}/process', [TourController::class, 'processNode']);
        Route::post('tours/{tourId}/nodes/{nodeId}/hotspots', [TourController::class, 'addHotspot']);
        Route::delete('tours/{tourId}/nodes/{nodeId}/hotspots/{hotspotId}', [TourController::class, 'deleteHotspot']);
        Route::post('tours/{tourId}/media', [TourController::class, 'addNode']);
        Route::get('tour-media/{nodeId}/status', [TourController::class, 'mediaStatus']);
        Route::post('tour-media/{nodeId}/manual-blurs', [TourController::class, 'addManualBlurForMedia']);
        Route::post('product-recognition/{jobId}/confirm', [RecognitionController::class, 'confirm']);
        Route::post('reports', [ReportController::class, 'store']);
        Route::post('feedback', [FeedbackController::class, 'store']);
        Route::get('favorites', [FavoriteController::class, 'index']);
        Route::post('favorites/toggle', [FavoriteController::class, 'toggle']);

        // Media upload intents — Cloud Storage quarantine flow (plan Wave 1)
        Route::post('media/upload-intent', [MediaController::class, 'uploadIntent']);
        Route::post('media/{assetId}/finalize', [MediaController::class, 'finalize']);
        Route::get('media/{assetId}/status', [MediaController::class, 'status']);

        Route::get('admin/reports', [ReportController::class, 'index']);
        Route::get('admin/audit', [AuditController::class, 'index']);
        Route::get('admin/feedback', [FeedbackController::class, 'index']);
        Route::patch('admin/reports/{reportId}', [ReportController::class, 'resolve']);
        Route::patch('admin/stores/{storeId}', [StoreController::class, 'setStatus']);
        Route::patch('admin/promotions/{promoId}', [PromotionController::class, 'setStatus']);
    });
});
