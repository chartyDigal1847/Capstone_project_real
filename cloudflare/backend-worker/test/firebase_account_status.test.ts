import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../src/errors.js";
import { assertExpectedFirebaseAndroidApp, validateFirebaseAccountRecord, verifyCurrentFirebaseAccount, type Env } from "../src/index.js";

const env: Env = {
  MEDIA_BUCKET: {} as R2Bucket,
  FIREBASE_PROJECT_ID: "demo-localspot",
  FIREBASE_PROJECT_NUMBER: "1",
  FIREBASE_WEB_API_KEY: "test-web-api-key",
};

afterEach(() => vi.unstubAllGlobals());

describe("Firebase App Check Android identity", () => {
  it("requires the configured Android app ID and rejects tokens from another app", () => {
    expect(() => assertExpectedFirebaseAndroidApp("1:123:android:abc", "1:123:android:abc")).not.toThrow();
    expect(() => assertExpectedFirebaseAndroidApp("1:123:android:abc", "1:123:android:other")).toThrowError(ApiError);
    try { assertExpectedFirebaseAndroidApp("1:123:android:abc", "1:123:android:other"); }
    catch (error) { expect((error as ApiError).status).toBe(401); }
    try { assertExpectedFirebaseAndroidApp(undefined, "1:123:android:abc"); }
    catch (error) { expect((error as ApiError).status).toBe(503); }
  });
});

describe("Firebase account status validation", () => {
  it("accepts the matching active account when its revocation boundary is older", () => {
    expect(() => validateFirebaseAccountRecord("user-1", 200, {
      localId: "user-1",
      disabled: false,
      validSince: "199",
    })).not.toThrow();
  });

  it.each([
    ["disabled account", { localId: "user-1", disabled: true, validSince: "100" }],
    ["different UID", { localId: "other-user", disabled: false, validSince: "100" }],
  ])("rejects a %s", (_case, user) => {
    expect(() => validateFirebaseAccountRecord("user-1", 200, user)).toThrowError(ApiError);
    try { validateFirebaseAccountRecord("user-1", 200, user); }
    catch (error) { expect((error as ApiError).status).toBe(401); }
  });

  it("rejects tokens at or before the validSince revocation boundary", () => {
    expect(() => validateFirebaseAccountRecord("user-1", 200, {
      localId: "user-1",
      disabled: false,
      validSince: "200",
    })).toThrowError(ApiError);
  });

  it("fails closed when Firebase omits an account revocation boundary", () => {
    expect(() => validateFirebaseAccountRecord("user-1", 200, { localId: "user-1", disabled: false })).toThrowError(ApiError);
    try { validateFirebaseAccountRecord("user-1", 200, { localId: "user-1", disabled: false }); }
    catch (error) { expect((error as ApiError).status).toBe(503); }
  });

  it("fails closed when Firebase omits the disabled state", () => {
    expect(() => validateFirebaseAccountRecord("user-1", 200, { localId: "user-1", validSince: "199" })).toThrowError(ApiError);
    try { validateFirebaseAccountRecord("user-1", 200, { localId: "user-1", validSince: "199" }); }
    catch (error) { expect((error as ApiError).status).toBe(503); }
  });

  it("looks up current account status using the presented ID token", async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => Response.json({ users: [{ localId: "user-1", disabled: false, validSince: "199" }] }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(verifyCurrentFirebaseAccount("firebase-id-token", "user-1", 200, env)).resolves.toBeUndefined();
    expect(fetchMock).toHaveBeenCalledOnce();
    const [input, init] = fetchMock.mock.calls[0];
    expect(String(input)).toBe("https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=test-web-api-key");
    expect(JSON.parse(String(init?.body))).toEqual({ idToken: "firebase-id-token" });
  });

  it("rejects revoked tokens and fails closed on Auth service errors", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ error: { message: "INVALID_ID_TOKEN" } }, { status: 400 })));
    await expect(verifyCurrentFirebaseAccount("revoked-token", "user-1", 200, env)).rejects.toMatchObject({ status: 401 });

    vi.stubGlobal("fetch", vi.fn(async () => new Response("unavailable", { status: 503 })));
    await expect(verifyCurrentFirebaseAccount("valid-token", "user-1", 200, env)).rejects.toMatchObject({ status: 503 });
  });
});
