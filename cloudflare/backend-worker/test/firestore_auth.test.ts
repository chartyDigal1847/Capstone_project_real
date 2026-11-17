import { afterEach, describe, expect, it, vi } from "vitest";
import { decodeJwt, exportPKCS8, generateKeyPair } from "jose";
import type { Env } from "../src/index.js";

const tokenUrl = "https://oauth2.googleapis.com/token";

async function makeSecret(token_uri?: string): Promise<string> {
  const { privateKey } = await generateKeyPair("RS256", { extractable: true });
  return JSON.stringify({
    type: "service_account",
    project_id: "spark-project",
    private_key: await exportPKCS8(privateKey),
    client_email: "worker@spark-project.iam.gserviceaccount.com",
    ...(token_uri ? { token_uri } : {}),
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("Firestore service-account OAuth", () => {
  it("sends a standard scoped assertion only to Google's token endpoint", async () => {
    const secret = await makeSecret();
    const requests: Array<{ url: string; init?: RequestInit }> = [];
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      requests.push({ url, init });
      if (url === tokenUrl) return Response.json({ access_token: "test-access-token", expires_in: 3600 });
      return new Response(null, { status: 404 });
    }));

    const { FirestoreRest } = await import("../src/firestore.js");
    const db = new FirestoreRest({
      MEDIA_BUCKET: {} as R2Bucket,
      FIREBASE_PROJECT_ID: "spark-project",
      FIREBASE_PROJECT_NUMBER: "123",
      FIREBASE_SERVICE_ACCOUNT_JSON: secret,
    } as Env);
    await expect(db.get("users/example")).resolves.toBeNull();

    expect(requests.map(({ url }) => url)).toEqual([
      tokenUrl,
      "https://firestore.googleapis.com/v1/projects/spark-project/databases/(default)/documents/users/example",
    ]);
    const assertionForm = new URLSearchParams(String(requests[0].init?.body));
    const claims = decodeJwt(assertionForm.get("assertion")!);
    expect(claims).toMatchObject({
      iss: "worker@spark-project.iam.gserviceaccount.com",
      aud: tokenUrl,
      scope: "https://www.googleapis.com/auth/datastore",
    });
    expect(claims).not.toHaveProperty("sub");
  });

  it("rejects a non-Google token_uri before sending the signed assertion", async () => {
    const secret = await makeSecret("https://attacker.example/token");
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const { FirestoreRest } = await import("../src/firestore.js");
    const db = new FirestoreRest({
      MEDIA_BUCKET: {} as R2Bucket,
      FIREBASE_PROJECT_ID: "spark-project",
      FIREBASE_PROJECT_NUMBER: "123",
      FIREBASE_SERVICE_ACCOUNT_JSON: secret,
    } as Env);
    await expect(db.get("users/example")).rejects.toThrow("token endpoint is not allowed");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects service-account credentials for another Firebase project", async () => {
    const secret = (await makeSecret()).replace('"project_id":"spark-project"', '"project_id":"another-project"');
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const { FirestoreRest } = await import("../src/firestore.js");
    const db = new FirestoreRest({
      MEDIA_BUCKET: {} as R2Bucket,
      FIREBASE_PROJECT_ID: "spark-project",
      FIREBASE_PROJECT_NUMBER: "123",
      FIREBASE_SERVICE_ACCOUNT_JSON: secret,
    } as Env);
    await expect(db.get("users/example")).rejects.toThrow("project does not match");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
