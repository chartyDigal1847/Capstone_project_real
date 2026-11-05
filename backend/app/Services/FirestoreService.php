<?php

namespace App\Services;

use Google\Auth\ApplicationDefaultCredentials;
use Illuminate\Support\Facades\Http;
use RuntimeException;

/**
 * Firestore data access via the Cloud Firestore REST API.
 *
 * On Windows/XAMPP the PHP gRPC extension is not available, so the
 * official google/cloud-firestore gRPC client cannot be used directly.
 * This service uses the Firestore REST API over HTTPS. It obtains short-lived
 * OAuth tokens through Google's Auth library, supporting explicit local
 * service-account credentials and production Application Default Credentials.
 *
 * @see https://firebase.google.com/docs/firestore/reference/rest
 */
class FirestoreService
{
    private const REST_BASE = 'https://firestore.googleapis.com/v1';
    private const SCOPE = 'https://www.googleapis.com/auth/datastore';
    private const TOKEN_LEEWAY = 60; // refresh this many seconds before expiry

    private ?string $accessToken = null;
    private int $tokenExpiresAt = 0;

    public function __construct(
        private readonly string $projectId,
        private readonly ?string $emulatorHost,
        private readonly ?string $credentialsPath,
    ) {
    }

    // ── Public interface ─────────────────────────────────────────────────

    /** Get a single document by collection + document ID. Returns null if not found. */
    public function get(string $collection, string $docId): ?array
    {
        $path = $this->docPath($collection, $docId);
        $response = $this->request('GET', $path);
        if ($response->status() === 404) return null;
        $response->throw();
        return $this->toArray($response->json());
    }

    /** Find a single document by a numericId field. */
    public function findByNumericId(string $collection, int $numericId): ?array
    {
        $results = $this->query($collection, [
            ['field' => 'numericId', 'op' => '==', 'value' => $numericId],
        ]);
        return $results[0] ?? null;
    }

    /** Fetch all documents in a collection. */
    public function all(string $collection): array
    {
        $url = $this->collectionUrl($collection);
        $results = [];
        $pageToken = null;
        do {
            $params = $pageToken ? ['pageToken' => $pageToken] : [];
            $response = $this->request('GET', $url, [], $params);
            $response->throw();
            $body = $response->json();
            foreach ($body['documents'] ?? [] as $doc) {
                $results[] = $this->toArray($doc);
            }
            $pageToken = $body['nextPageToken'] ?? null;
        } while ($pageToken !== null);
        return $results;
    }

    /**
     * Run a structured query with simple where clauses.
     *
     * @param array<array{field:string, op:string, value:mixed}> $wheres
     */
    public function query(string $collection, array $wheres = []): array
    {
        $filters = array_map(fn ($w) => $this->buildFilter($w), $wheres);
        $filter = count($filters) === 1
            ? $filters[0]
            : ['compositeFilter' => ['op' => 'AND', 'filters' => $filters]];

        $body = [
            'structuredQuery' => [
                'from' => [['collectionId' => $collection]],
                'where' => $filter,
            ],
        ];

        $url = $this->runQueryUrl();
        $response = $this->request('POST', $url, $body);
        $response->throw();

        $results = [];
        foreach ($response->json() as $row) {
            if (isset($row['document'])) {
                $results[] = $this->toArray($row['document']);
            }
        }
        return $results;
    }

    /** Create a new document with an auto-generated ID. Returns the document ID. */
    public function create(string $collection, array $data): string
    {
        $url = $this->collectionUrl($collection);
        $body = ['fields' => $this->toFields($data)];
        $response = $this->request('POST', $url, $body);
        $response->throw();
        $name = $response->json('name') ?? '';
        return basename($name);
    }

    /** Set (overwrite) a document at a specific path. */
    public function set(string $collection, string $docId, array $data): void
    {
        $path = $this->docPath($collection, $docId);
        $body = ['fields' => $this->toFields($data)];
        $this->request('PATCH', $path, $body)->throw();
    }

    /** Merge data into an existing document (creates if absent). */
    public function merge(string $collection, string $docId, array $data): void
    {
        $path = $this->docPath($collection, $docId);
        $body = ['fields' => $this->toFields($data)];
        $fieldPaths = array_map(fn ($k) => $k, array_keys($data));
        $this->request('PATCH', $path, $body, [
            'updateMask.fieldPaths' => $fieldPaths,
        ])->throw();
    }

    /** Update specific fields on an existing document (by Firestore doc ID). */
    public function update(string $collection, string $docId, array $data): void
    {
        $this->merge($collection, $docId, $data);
    }

    /** Update a document identified by its numericId field. Returns true if found. */
    public function updateByNumericId(string $collection, int $numericId, array $data): bool
    {
        $docs = $this->query($collection, [
            ['field' => 'numericId', 'op' => '==', 'value' => $numericId],
        ]);
        if (empty($docs)) return false;
        $this->merge($collection, $docs[0]['id'], $data);
        return true;
    }

    /** Delete a document identified by its numericId field. Returns true if found. */
    public function deleteByNumericId(string $collection, int $numericId): bool
    {
        $docs = $this->query($collection, [
            ['field' => 'numericId', 'op' => '==', 'value' => $numericId],
        ]);
        if (empty($docs)) return false;
        $this->delete($collection, $docs[0]['id']);
        return true;
    }

    /** Delete a document by its Firestore document ID. */
    public function delete(string $collection, string $docId): void
    {
        $path = $this->docPath($collection, $docId);
        $this->request('DELETE', $path)->throw();
    }

    /** Run a simple transaction (sequential operations, no rollback). */
    public function transaction(callable $fn): mixed
    {
        return $fn($this);
    }

    // ── REST helpers ─────────────────────────────────────────────────────

    private function collectionUrl(string $collection): string
    {
        if ($this->emulatorHost) {
            return "http://{$this->emulatorHost}/v1/projects/{$this->projectId}/databases/(default)/documents/{$collection}";
        }
        return self::REST_BASE . "/projects/{$this->projectId}/databases/(default)/documents/{$collection}";
    }

    private function docPath(string $collection, string $docId): string
    {
        return $this->collectionUrl($collection) . '/' . rawurlencode($docId);
    }

    private function runQueryUrl(): string
    {
        if ($this->emulatorHost) {
            return "http://{$this->emulatorHost}/v1/projects/{$this->projectId}/databases/(default)/documents:runQuery";
        }
        return self::REST_BASE . "/projects/{$this->projectId}/databases/(default)/documents:runQuery";
    }

    /** Make an authenticated HTTP request to Firestore REST API. */
    private function request(string $method, string $url, array $body = [], array $query = []): \Illuminate\Http\Client\Response
    {
        $headers = $this->emulatorHost
            ? []
            : ['Authorization' => 'Bearer ' . $this->getAccessToken()];

        $http = Http::withHeaders($headers)->timeout(15);

        return match ($method) {
            'GET'    => $http->get($url, $query),
            'POST'   => $http->post($url, $body),
            'PATCH'  => $http->patch($url . ($query ? '?' . $this->encodeQuery($query) : ''), $body),
            'DELETE' => $http->delete($url),
            default  => throw new RuntimeException("Unsupported method: $method"),
        };
    }

    /**
     * Encode REST query parameters while preserving repeated array keys.
     * Firestore updateMask.fieldPaths is a repeated query parameter; PHP's
     * default http_build_query would encode it as updateMask.fieldPaths[0],
     * which Firestore rejects.
     */
    private function encodeQuery(array $query): string
    {
        $pairs = [];
        foreach ($query as $key => $value) {
            foreach (is_array($value) ? $value : [$value] as $item) {
                $pairs[] = rawurlencode((string) $key) . '=' . rawurlencode((string) $item);
            }
        }

        return implode('&', $pairs);
    }

    // ── Firestore value conversion ────────────────────────────────────────

    /**
     * Convert a PHP array to Firestore field map format.
     *
     * @see https://firebase.google.com/docs/firestore/reference/rest/v1/Value
     */
    private function toFields(array $data): array
    {
        $fields = [];
        foreach ($data as $key => $value) {
            $fields[$key] = $this->toValue($value);
        }
        return $fields;
    }

    private function toValue(mixed $value): array
    {
        return match (true) {
            $value === null          => ['nullValue' => 'NULL_VALUE'],
            is_bool($value)          => ['booleanValue' => $value],
            is_int($value)           => ['integerValue' => (string) $value],
            is_float($value)         => ['doubleValue' => $value],
            is_string($value)        => ['stringValue' => $value],
            is_array($value) && array_is_list($value) => [
                'arrayValue' => ['values' => array_map(fn ($v) => $this->toValue($v), $value)],
            ],
            is_array($value)         => [
                'mapValue' => ['fields' => $this->toFields($value)],
            ],
            default                  => ['stringValue' => (string) $value],
        };
    }

    /**
     * Convert a Firestore REST document to a plain PHP array.
     * Extracts the document ID from the name and converts all field values.
     */
    private function toArray(array $doc): array
    {
        $name = $doc['name'] ?? '';
        $id = basename($name);
        $data = ['id' => $id];
        foreach ($doc['fields'] ?? [] as $key => $value) {
            $data[$key] = $this->fromValue($value);
        }
        return $data;
    }

    private function fromValue(array $value): mixed
    {
        if (isset($value['nullValue']))     return null;
        if (isset($value['booleanValue']))  return (bool) $value['booleanValue'];
        if (isset($value['integerValue']))  return (int) $value['integerValue'];
        if (isset($value['doubleValue']))   return (float) $value['doubleValue'];
        if (isset($value['stringValue']))   return (string) $value['stringValue'];
        if (isset($value['timestampValue'])) return $value['timestampValue'];
        if (isset($value['arrayValue'])) {
            return array_map(
                fn ($v) => $this->fromValue($v),
                $value['arrayValue']['values'] ?? []
            );
        }
        if (isset($value['mapValue'])) {
            $map = [];
            foreach ($value['mapValue']['fields'] ?? [] as $k => $v) {
                $map[$k] = $this->fromValue($v);
            }
            return $map;
        }
        if (isset($value['referenceValue'])) return $value['referenceValue'];
        if (isset($value['geoPointValue']))  return $value['geoPointValue'];
        if (isset($value['bytesValue']))     return $value['bytesValue'];
        return null;
    }

    private function buildFilter(array $where): array
    {
        $op = match ($where['op']) {
            '=='  => 'EQUAL',
            '!='  => 'NOT_EQUAL',
            '<'   => 'LESS_THAN',
            '<='  => 'LESS_THAN_OR_EQUAL',
            '>'   => 'GREATER_THAN',
            '>='  => 'GREATER_THAN_OR_EQUAL',
            'array-contains' => 'ARRAY_CONTAINS',
            default => 'EQUAL',
        };

        return [
            'fieldFilter' => [
                'field' => ['fieldPath' => $where['field']],
                'op'    => $op,
                'value' => $this->toValue($where['value']),
            ],
        ];
    }

    // ── Google OAuth token ────────────────────────────────────────────────

    private function getAccessToken(): string
    {
        if ($this->accessToken !== null && time() < $this->tokenExpiresAt - self::TOKEN_LEEWAY) {
            return $this->accessToken;
        }

        if ($this->credentialsPath !== null && $this->credentialsPath !== '') {
            // Laravel config values are not guaranteed to be exported by every
            // runtime; pass the configured ADC file path to Google's loader.
            putenv('GOOGLE_APPLICATION_CREDENTIALS=' . $this->credentialsPath);
        }

        $credentials = ApplicationDefaultCredentials::getCredentials(self::SCOPE);
        $token = $credentials->fetchAuthToken();

        if (empty($token['access_token'])) {
            throw new RuntimeException('Google credentials did not return an access token.');
        }

        $this->accessToken = $token['access_token'];
        $this->tokenExpiresAt = time() + (int) ($token['expires_in'] ?? 3600);

        return $this->accessToken;
    }
}
