<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Store;
use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Illuminate\Validation\Rule;
use Laravel\Sanctum\PersonalAccessToken;

class AuthController extends Controller
{
    public function register(Request $request)
    {
        $data = $request->validate([
            'name' => ['required', 'string', 'max:120'],
            'email' => ['required', 'email', 'max:190', 'unique:users,email'],
            'password' => ['required', 'string', 'min:4'],
            'role' => ['required', Rule::in(['customer', 'owner', 'staff'])],
        ]);

        $user = User::create([
            'name' => $data['name'],
            'email' => $data['email'],
            'password' => $data['password'],
            'role' => $data['role'],
            'status' => 'active',
        ]);

        return response()->json(['data' => $this->tokenPayload($user)], 201);
    }

    public function login(Request $request)
    {
        $data = $request->validate([
            'email' => ['required', 'email'],
            'password' => ['required', 'string'],
        ]);

        $user = User::where('email', $data['email'])->first();
        if (! $user || ! Hash::check($data['password'], $user->password)) {
            return response()->json(['message' => 'Email or password is incorrect.'], 422);
        }
        if ($user->status !== 'active') {
            return response()->json(['message' => 'This account is suspended.'], 403);
        }

        $user->tokens()->delete();

        return response()->json(['data' => $this->tokenPayload($user)]);
    }

    public function me(Request $request)
    {
        $user = $request->user();
        $stores = $user->isAdmin()
            ? Store::orderBy('name')->get()
            : Store::query()
                ->where(function ($query) use ($user) {
                    $query->where('owner_id', $user->id)
                        ->orWhereIn('id', $user->memberStores()->pluck('stores.id'));
                })
                ->get();

        return response()->json([
            'data' => [
                'user' => $user->toApi(),
                'stores' => $stores->map->toApi()->values(),
            ],
        ]);
    }

    public function logout(Request $request)
    {
        $user = $request->user();
        $plain = $request->bearerToken();
        if ($plain) {
            PersonalAccessToken::findToken($plain)?->delete();
        }
        $user?->tokens()->delete();

        return response()->json(['data' => true]);
    }

    private function tokenPayload(User $user): array
    {
        $minutes = (int) config('sanctum.expiration', 10080);
        $expiresAt = now()->addMinutes($minutes);

        return [
            'token' => $user->createToken('mobile', ['*'], $expiresAt)->plainTextToken,
            'token_expires_at' => $expiresAt->toIso8601String(),
            'user' => $user->toApi(),
        ];
    }
}
