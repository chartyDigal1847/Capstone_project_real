<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Jobs\ProcessRecognitionJob;
use App\Models\RecognitionJob;
use App\Support\Audit;
use App\Support\ImageText;
use Illuminate\Http\Request;

class RecognitionController extends Controller
{
    public function suggest(Request $request)
    {
        $data = $request->validate([
            'hint' => ['nullable', 'string'],
            'barcode' => ['nullable', 'string'],
            'image' => ['nullable', 'string', 'max:2000000'],
        ]);
        $extracted = ImageText::extract($data['hint'] ?? null, $data['barcode'] ?? null, $data['image'] ?? null);
        $job = RecognitionJob::create([
            'hint' => $extracted['text'] !== '' ? $extracted['text'] : ($data['hint'] ?? null),
            'barcode' => $extracted['barcode'],
            'ocr_text' => $extracted['text'] !== '' ? $extracted['text'] : null,
            'status' => 'pending',
            'suggestions' => [],
            'objects' => [],
        ]);
        ProcessRecognitionJob::dispatch($job->id);

        return response()->json(['data' => $job->fresh()->toApi()]);
    }

    public function show(RecognitionJob $job)
    {
        return response()->json(['data' => $job->toApi()]);
    }

    public function confirm(Request $request, RecognitionJob $job)
    {
        $request->validate([
            'product_id' => ['nullable', 'integer', 'exists:products,id'],
            'attributes' => ['nullable', 'array'],
        ]);
        $job->update([
            'status' => 'confirmed',
            'confirmed_at' => now(),
        ]);
        Audit::record($request->user(), 'recognition.confirm', RecognitionJob::class, $job->id, [
            'product_id' => $request->input('product_id'),
        ]);

        return response()->json(['data' => $job->fresh()->toApi()]);
    }
}
