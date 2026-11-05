<?php

namespace App\Providers;

use App\Services\FirebaseAuthService;
use App\Services\CloudStorageService;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        // FirestoreService currently uses the Firestore REST API adapter.
        $this->app->singleton(FirestoreService::class, function ($app) {
            return new FirestoreService(
                projectId: config('firebase.firestore.project_id'),
                emulatorHost: config('firebase.firestore.emulator_host'),
                credentialsPath: config('firebase.firestore.credentials'),
            );
        });

        $this->app->singleton(CloudStorageService::class, function ($app) {
            return new CloudStorageService(
                projectId: config('firebase.storage.project_id'),
                bucketName: config('firebase.storage.bucket'),
                credentialsPath: config('firebase.storage.credentials'),
            );
        });

        // FirebaseAuthService singleton — verifies Firebase ID tokens (RS256 JWT).
        $this->app->singleton(FirebaseAuthService::class, function ($app) {
            return new FirebaseAuthService(
                projectId: config('firebase.auth.project_id'),
                issuer: config('firebase.auth.issuer'),
                audience: config('firebase.auth.audience'),
                publicKeyUrl: config('firebase.auth.public_key_url'),
                keyCacheTtl: (int) config('firebase.auth.key_cache_ttl'),
                allowEmulator: (bool) config('firebase.auth.allow_emulator'),
            );
        });

        // UserResolver — resolves Firestore user profile from Firebase UID on request.
        $this->app->singleton(UserResolver::class, function ($app) {
            return new UserResolver($app->make(FirestoreService::class));
        });
    }

    public function boot(): void
    {
        RateLimiter::for('login', fn (Request $request) => Limit::perMinute(5)->by($request->ip()));
        RateLimiter::for('search', fn (Request $request) => Limit::perMinute(60)->by($request->ip()));
        RateLimiter::for('recognition', fn (Request $request) => Limit::perMinute(10)->by($request->attributes->get('firebase_uid') ?: $request->ip()));
        RateLimiter::for('routing', fn (Request $request) => Limit::perMinute(30)->by($request->ip()));
        RateLimiter::for('location', fn (Request $request) => Limit::perMinute(30)->by($request->attributes->get('firebase_uid') ?: $request->ip()));
    }
}
