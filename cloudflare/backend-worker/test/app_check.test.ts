import { afterEach, describe, expect, it, vi } from "vitest";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { verifyAppCheck, type Env } from "../src/index.js";

const env: Env = {
  MEDIA_BUCKET: {} as R2Bucket,
  FIREBASE_PROJECT_ID: "demo-localspot",
  FIREBASE_PROJECT_NUMBER: "1",
  FIREBASE_ANDROID_APP_ID: "1:123456:android:localspot",
};

afterEach(() => vi.unstubAllGlobals());

describe("Firebase App Check JWT verification", () => {
  it("verifies signature, audience, issuer, issue time, and exact Android app identity", async () => {
    const { privateKey, publicKey } = await generateKeyPair("RS256", { extractable: true });
    const jwk = await exportJWK(publicKey);
    jwk.kid = "app-check-test-key";
    jwk.alg = "RS256";
    jwk.use = "sig";
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ keys: [jwk] }, { headers: { "Cache-Control": "max-age=3600" } })));

    const token = async (sub: string) => new SignJWT({ aud: "projects/1", sub })
      .setProtectedHeader({ alg: "RS256", kid: "app-check-test-key", typ: "JWT" })
      .setIssuer("https://firebaseappcheck.googleapis.com/1")
      .setIssuedAt()
      .setExpirationTime("5m")
      .sign(privateKey);

    const valid = await token(env.FIREBASE_ANDROID_APP_ID!);
    await expect(verifyAppCheck(valid, env)).resolves.toBe(env.FIREBASE_ANDROID_APP_ID);
    await expect(verifyAppCheck(await token("1:123456:android:other"), env)).rejects.toMatchObject({ status: 401 });
    await expect(verifyAppCheck(valid, { ...env, FIREBASE_ANDROID_APP_ID: undefined })).rejects.toMatchObject({ status: 503 });

    const forgedKeys = await generateKeyPair("RS256", { extractable: true });
    const forgedToken = await new SignJWT({ aud: "projects/1", sub: env.FIREBASE_ANDROID_APP_ID })
      .setProtectedHeader({ alg: "RS256", kid: "app-check-test-key", typ: "JWT" })
      .setIssuer("https://firebaseappcheck.googleapis.com/1")
      .setIssuedAt()
      .setExpirationTime("5m")
      .sign(forgedKeys.privateKey);
    await expect(verifyAppCheck(forgedToken, env)).rejects.toMatchObject({ status: 401 });

    const expiredToken = await new SignJWT({ aud: "projects/1", sub: env.FIREBASE_ANDROID_APP_ID })
      .setProtectedHeader({ alg: "RS256", kid: "app-check-test-key", typ: "JWT" })
      .setIssuer("https://firebaseappcheck.googleapis.com/1")
      .setIssuedAt(Math.floor(Date.now() / 1000) - 120)
      .setExpirationTime(Math.floor(Date.now() / 1000) - 60)
      .sign(privateKey);
    await expect(verifyAppCheck(expiredToken, env)).rejects.toMatchObject({ status: 401 });
  });
});
