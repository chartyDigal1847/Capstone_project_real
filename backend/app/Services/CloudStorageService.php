<?php

namespace App\Services;

use Google\Cloud\Storage\StorageClient;
use RuntimeException;

/**
 * Server-side verification of objects uploaded into Cloud Storage quarantine.
 * Client-reported size and content type are hints only; publication decisions
 * must use metadata read by the trusted backend.
 */
class CloudStorageService
{
    private ?StorageClient $client = null;

    public function __construct(
        private readonly ?string $projectId,
        private readonly ?string $bucketName,
        private readonly ?string $credentialsPath,
    ) {
    }

    /** @return array{size:int, content_type:string} */
    public function inspectObject(string $objectPath): array
    {
        if ($this->bucketName === null || $this->bucketName === '') {
            throw new RuntimeException('Firebase Storage bucket is not configured.');
        }

        $object = $this->client()
            ->bucket($this->bucketName)
            ->object($objectPath);

        if (! $object->exists()) {
            throw new CloudStorageObjectNotFound('Uploaded object does not exist in Cloud Storage.');
        }

        $info = $object->info();
        $size = (int) ($info['size'] ?? 0);
        $contentType = (string) ($info['contentType'] ?? '');

        if ($size < 1 || $contentType === '') {
            throw new RuntimeException('Uploaded object metadata is incomplete.');
        }

        return ['size' => $size, 'content_type' => $contentType];
    }

    private function client(): StorageClient
    {
        if ($this->client !== null) {
            return $this->client;
        }

        if ($this->credentialsPath !== null && $this->credentialsPath !== '') {
            putenv('GOOGLE_APPLICATION_CREDENTIALS=' . $this->credentialsPath);
        }

        $options = array_filter([
            'projectId' => $this->projectId,
        ], fn ($value) => $value !== null && $value !== '');

        return $this->client = new StorageClient($options);
    }
}
