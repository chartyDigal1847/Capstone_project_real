<?php

namespace App\Services;

use Firebase\JWT\JWT;
use Firebase\JWT\Key;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use RuntimeException;

/**
 * Verifies Firebase Authentication ID tokens using the documented
 * third-party JWT procedure (RS256 against Google's published public keys).
 *
 * Google does not list PHP as a supported Firebase Admin SDK language, so
 * we use the firebase/php-jwt library and Firebase's public verification
 * steps instead of an Admin SDK.
 *
 * @see https://firebase.google.com/docs/auth/admin/verify-id-tokens
 */
class FirebaseAuthService
{
    private const KEY_CACHE_TAG = 'firebase_auth_public_keys';

    public function __construct(
        private readonly string $projectId,
        private readonly string $issuer,
        private readonly string $audience,
        private readonly string $publicKeyUrl,
        private readonly int $keyCacheTtl,
        private readonly bool $allowEmulator,
    ) {
    }

    /**
     * Verify a Firebase ID token and return the decoded payload.
     *
     * @throws RuntimeException If the project is not configured or verification fails
     */
    public function verifyIdToken(string $token): object
    {
        if ($this->projectId === null || $this->projectId === '') {
            throw new RuntimeException('FIREBASE_PROJECT_ID is not configured.');
        }

        $keys = $this->getPublicKeys();

        // Decode header to get kid
        $header = $this->decodeHeader($token);
        $kid = $header['kid'] ?? null;
        if ($kid === null || ! isset($keys[$kid])) {
            throw new RuntimeException('Unknown or missing key ID (kid).');
        }

        // Verify: RS256 signature, aud, iss, and required claims
        $decoded = JWT::decode($token, new Key($keys[$kid], 'RS256'));

        // Validate audience (must equal Firebase project ID)
        if (! isset($decoded->aud) || $decoded->aud !== $this->audience) {
            throw new RuntimeException('Token audience does not match project ID.');
        }

        // Validate issuer
        if (! isset($decoded->iss) || $decoded->iss !== $this->issuer) {
            throw new RuntimeException('Token issuer does not match expected value.');
        }

        // Validate subject (Firebase UID)
        if (! isset($decoded->sub) || $decoded->sub === '') {
            throw new RuntimeException('Token subject (uid) is empty.');
        }

        // Validate issued-at time
        if (! isset($decoded->iat) || ! is_int($decoded->iat)) {
            throw new RuntimeException('Token is missing iat claim.');
        }

        // Validate auth_time (when the user actually authenticated)
        if (! isset($decoded->auth_time) || ! is_int($decoded->auth_time)) {
            throw new RuntimeException('Token is missing auth_time claim.');
        }

        return $decoded;
    }

    public function shouldAllowEmulator(): bool
    {
        return $this->allowEmulator;
    }

    /**
     * Fetch and cache Google's public signing keys (x509 certs).
     *
     * @return array<string, string> Map of key ID → PEM-encoded public key
     */
    private function getPublicKeys(): array
    {
        return Cache::remember(self::KEY_CACHE_TAG, $this->keyCacheTtl, function () {
            $response = Http::timeout(10)->get($this->publicKeyUrl);
            if (! $response->ok()) {
                throw new RuntimeException('Failed to fetch Firebase public keys.');
            }

            $body = $response->json();
            if (! is_array($body) || empty($body)) {
                throw new RuntimeException('Firebase public keys response is empty.');
            }

            return $body;
        });
    }

    /**
     * Decode the JWT header without verification (to extract kid).
     */
    private function decodeHeader(string $token): array
    {
        $parts = explode('.', $token);
        if (count($parts) !== 3) {
            throw new RuntimeException('Malformed token: expected 3 segments.');
        }

        $headerJson = base64_decode(str_replace(['-', '_'], ['+', '/'], $parts[0]));
        if ($headerJson === false) {
            throw new RuntimeException('Malformed token: cannot decode header.');
        }

        $header = json_decode($headerJson, true);
        if (! is_array($header)) {
            throw new RuntimeException('Malformed token: header is not valid JSON.');
        }

        return $header;
    }
}
