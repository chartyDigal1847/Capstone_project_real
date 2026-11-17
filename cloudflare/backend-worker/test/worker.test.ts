import { describe, expect, it } from "vitest";
import worker, { type Env } from "../src/index.js";

const env: Env = {
  MEDIA_BUCKET: {} as R2Bucket,
  FIREBASE_PROJECT_ID: "demo-localspot",
  FIREBASE_PROJECT_NUMBER: "1",
  FIREBASE_AUTH_EMULATOR_URL: "http://127.0.0.1:9099",
  FIRESTORE_EMULATOR_URL: "http://127.0.0.1:8080",
  LOCAL_EMULATORS: "true",
};

describe("backend worker foundation", () => {
  it("exposes a simple health check without backend credentials", async () => {
    const response = await worker.fetch(new Request("http://127.0.0.1/healthz"), env);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  it("rejects protected calls without a Firebase ID token", async () => {
    const response = await worker.fetch(new Request("http://127.0.0.1/api/v1/auth/profile/bootstrap", { method: "POST" }), env);
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "A valid Authorization bearer token is required." });
  });

  it("rejects a malformed Firebase token and a token using the wrong signing algorithm", async () => {
    for (const token of ["not-a-jwt", "eyJhbGciOiJIUzI1NiIsImtpZCI6Im5vbmUifQ.e30.signature"]) {
      const response = await worker.fetch(new Request("http://127.0.0.1/api/v1/auth/profile/bootstrap", {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "X-Firebase-AppCheck": "Bearer invalid" },
      }), env);
      expect(response.status).toBe(401);
    }
  });

  it("does not accept a UID from the request body as authentication", async () => {
    const response = await worker.fetch(new Request("http://127.0.0.1/api/v1/auth/profile/bootstrap", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ uid: "attacker-controlled" }),
    }), env);
    expect(response.status).toBe(401);
  });

  it("refuses emulator configuration on public hosts", async () => {
    const response = await worker.fetch(new Request("https://localspot-backend-local.example.workers.dev/healthz"), env);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "This Worker is configured for local emulators only." });
  });

  it("keeps emulator mode available to a physical device on the private LAN", async () => {
    const response = await worker.fetch(new Request("http://192.168.1.20/healthz"), env);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });
});
