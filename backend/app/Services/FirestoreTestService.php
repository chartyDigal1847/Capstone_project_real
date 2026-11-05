<?php

namespace App\Services;

use RuntimeException;

/**
 * In-memory Firestore mock for testing.
 *
 * Implements the same public interface as FirestoreService but stores
 * data in PHP arrays. This allows tests to run without gRPC, the Firestore
 * emulator, or any external dependencies.
 */
class FirestoreTestService extends FirestoreService
{
    /** @var array<string, array<string, array<string, mixed>>> */
    private array $collections = [];

    private int $idCounter = 1;

    public function __construct()
    {
        // Skip parent constructor — no FirestoreClient needed.
    }

    public function get(string $collection, string $docId): ?array
    {
        $data = $this->collections[$collection][$docId] ?? null;
        if ($data === null) {
            return null;
        }
        return array_merge(['id' => $docId], $data);
    }

    public function findByNumericId(string $collection, int $numericId): ?array
    {
        foreach ($this->collections[$collection] ?? [] as $docId => $data) {
            if (($data['numericId'] ?? null) === $numericId) {
                return array_merge(['id' => $docId], $data);
            }
        }
        return null;
    }

    public function all(string $collection): array
    {
        $results = [];
        foreach ($this->collections[$collection] ?? [] as $docId => $data) {
            $results[] = array_merge(['id' => $docId], $data);
        }
        return $results;
    }

    public function query(string $collection, array $wheres = []): array
    {
        $results = [];
        foreach ($this->collections[$collection] ?? [] as $docId => $data) {
            $match = true;
            foreach ($wheres as $where) {
                $field = $where['field'];
                $op = $where['op'];
                $value = $where['value'];
                $docVal = $data[$field] ?? null;

                if ($op === '==' && $docVal !== $value) { $match = false; break; }
                if ($op === '!=' && $docVal === $value) { $match = false; break; }
                if ($op === '>=' && ($docVal === null || $docVal < $value)) { $match = false; break; }
                if ($op === '<=' && ($docVal === null || $docVal > $value)) { $match = false; break; }
                if ($op === '>' && ($docVal === null || $docVal <= $value)) { $match = false; break; }
                if ($op === '<' && ($docVal === null || $docVal >= $value)) { $match = false; break; }
                if ($op === 'array-contains' && (!is_array($docVal) || !in_array($value, $docVal, true))) { $match = false; break; }
            }
            if ($match) {
                $results[] = array_merge(['id' => $docId], $data);
            }
        }
        return $results;
    }

    public function create(string $collection, array $data): string
    {
        $docId = 'doc_' . $this->idCounter++;
        $this->collections[$collection][$docId] = $data;
        return $docId;
    }

    public function set(string $collection, string $docId, array $data): void
    {
        $this->collections[$collection][$docId] = $data;
    }

    public function merge(string $collection, string $docId, array $data): void
    {
        $existing = $this->collections[$collection][$docId] ?? [];
        $this->collections[$collection][$docId] = array_merge($existing, $data);
    }

    public function update(string $collection, string $docId, array $data): void
    {
        $existing = $this->collections[$collection][$docId] ?? [];
        foreach ($data as $key => $value) {
            $existing[$key] = $value;
        }
        $this->collections[$collection][$docId] = $existing;
    }

    public function updateByNumericId(string $collection, int $numericId, array $data): bool
    {
        foreach ($this->collections[$collection] ?? [] as $docId => $data2) {
            if (($data2['numericId'] ?? null) === $numericId) {
                foreach ($data as $key => $value) {
                    $this->collections[$collection][$docId][$key] = $value;
                }
                return true;
            }
        }
        return false;
    }

    public function deleteByNumericId(string $collection, int $numericId): bool
    {
        foreach ($this->collections[$collection] ?? [] as $docId => $data) {
            if (($data['numericId'] ?? null) === $numericId) {
                unset($this->collections[$collection][$docId]);
                return true;
            }
        }
        return false;
    }

    public function delete(string $collection, string $docId): void
    {
        unset($this->collections[$collection][$docId]);
    }

    public function transaction(callable $fn): mixed
    {
        return $fn($this);
    }

    /**
     * Seed a document directly into the in-memory store.
     * Used by test setup to populate test data.
     */
    public function seed(string $collection, string $docId, array $data): void
    {
        $this->collections[$collection][$docId] = $data;
    }

    /**
     * Clear all data — useful between tests.
     */
    public function reset(): void
    {
        $this->collections = [];
    }
}
