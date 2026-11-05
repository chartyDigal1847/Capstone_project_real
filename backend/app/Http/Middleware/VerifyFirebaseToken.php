<?php

namespace App\Http\Middleware;

use App\Services\FirebaseAuthService;
use App\Services\FirebasePublicKeysUnavailable;
use Closure;
use Illuminate\Http\Request;
use Firebase\JWT\SignatureInvalidException;
use Firebase\JWT\BeforeValidException;
use Firebase\JWT\ExpiredException;
use RuntimeException;

/**
 * Verifies Firebase Authentication ID tokens (RS256 JWT) presented as
 * `Authorization: Bearer <token>`.
 *
 * Implements Firebase's documented third-party JWT verification procedure:
 *  - Validate alg=RS256, key ID (kid), signature against Google's public keys
 *  - Verify aud == Firebase project ID, iss == securetoken.google.com/<projectId>
 *  - Check sub (non-empty), exp, iat, auth_time claims
 *  - Cache signing keys according to cache headers
 *
 * On success, the Firebase UID is available via $request->attributes->get('firebase_uid')
 * and the decoded token payload is available via $request->attributes->get('firebase_token').
 *
 * @see https://firebase.google.com/docs/auth/admin/verify-id-tokens
 */
class VerifyFirebaseToken
{
    public function __construct(private readonly FirebaseAuthService $firebaseAuth)
    {
    }

    public function handle(Request $request, Closure $next): mixed
    {
        $bearer = $request->bearerToken();
        if ($bearer === null || $bearer === '') {
            return response()->json(['message' => 'Firebase ID token required.'], 401);
        }

        // Allow emulator bypass in local/test environments only.
        if ($this->firebaseAuth->shouldAllowEmulator() && str_starts_with($bearer, 'test-token-')) {
            $uid = substr($bearer, strlen('test-token-'));
            $request->attributes->set('firebase_uid', $uid);
            $request->attributes->set('firebase_token', ['sub' => $uid]);
            return $next($request);
        }

        try {
            $decoded = $this->firebaseAuth->verifyIdToken($bearer);
        } catch (ExpiredException $e) {
            return response()->json(['message' => 'Firebase ID token has expired.'], 401);
        } catch (SignatureInvalidException $e) {
            return response()->json(['message' => 'Invalid Firebase ID token signature.'], 401);
        } catch (BeforeValidException $e) {
            return response()->json(['message' => 'Firebase ID token not yet valid.'], 401);
        } catch (FirebasePublicKeysUnavailable $e) {
            report($e);
            return response()->json(['message' => 'Authentication verification is temporarily unavailable. Please retry.'], 503);
        } catch (RuntimeException $e) {
            return response()->json(['message' => 'Firebase ID token verification failed: ' . $e->getMessage()], 401);
        }

        // JWT::decode() returns stdClass — use object property access.
        $uid = $decoded->sub ?? null;
        if ($uid === null || $uid === '') {
            return response()->json(['message' => 'Firebase ID token missing subject (uid).'], 401);
        }

        $request->attributes->set('firebase_uid', $uid);
        // Convert to array for downstream consumers (UserResolver etc.).
        $request->attributes->set('firebase_token', (array) $decoded);

        return $next($request);
    }
}
