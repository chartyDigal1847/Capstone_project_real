import { beforeAll, describe, expect, it } from "vitest";
import { exportJWK, generateKeyPair, importJWK, jwtVerify } from "jose";
import worker, { type Env } from "../src/index.js";
import { documentData, FirestoreRest } from "../src/firestore.js";

const authUrl = process.env.FIREBASE_AUTH_EMULATOR_URL;
const firestoreUrl = process.env.FIRESTORE_EMULATOR_URL;
const integration = describe.skipIf(!authUrl || !firestoreUrl);

const env: Env = {
  MEDIA_BUCKET: {} as R2Bucket,
  FIREBASE_PROJECT_ID: "demo-localspot",
  FIREBASE_PROJECT_NUMBER: "1",
  FIREBASE_AUTH_EMULATOR_URL: authUrl,
  FIRESTORE_EMULATOR_URL: firestoreUrl,
  LOCAL_EMULATORS: "true",
};

const db = new FirestoreRest(env);
const appCheck = "Bearer local-emulator-test";

async function newUser(prefix: string) {
  const email = `${prefix}-${crypto.randomUUID()}@example.test`;
  const response = await fetch(`${authUrl}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=emulator`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: "LocalSpotTest123!", returnSecureToken: true }),
  });
  expect(response.ok).toBe(true);
  const account = await response.json() as { localId: string; idToken: string };
  return { ...account, email };
}

async function api(token: string, path: string, body: unknown, method = "POST") {
  const response = await worker.fetch(new Request(`http://127.0.0.1${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "X-Firebase-AppCheck": appCheck, "Content-Type": "application/json" },
    ...(method === "GET" ? {} : { body: JSON.stringify(body ?? {}) }),
  }), env);
  return { response, data: await response.json() as Record<string, unknown> };
}

async function seedStore(ownerUid: string, numericId: number) {
  await db.create("stores", { numericId, ownerUid, status: "approved" }, `integration-${numericId}`);
}

integration("Local Auth and Firestore emulator workflows", () => {
  beforeAll(async () => {
    const response = await fetch(`${firestoreUrl}/`);
    expect([200, 404, 405, 403]).toContain(response.status);
  });

  it("bootstraps an immutable customer role and returns the existing profile on retry", async () => {
    const user = await newUser("bootstrap");
    const first = await api(user.idToken, "/api/v1/auth/profile/bootstrap", { uid: "forged", role: "admin", name: "Bootstrap Test Name" });
    const retry = await api(user.idToken, "/api/v1/auth/profile/bootstrap", { uid: "forged", role: "admin" });
    const profile = await db.get(`users/${user.localId}`);
    expect(first.data.created).toBe(true);
    expect(retry.data.created).toBe(false);
    expect(profile?.fields?.role).toEqual({ stringValue: "customer" });
    expect(profile?.fields?.name).toEqual({ stringValue: "Bootstrap Test Name" });
    expect(profile?.fields?.email).toEqual({ stringValue: user.email });
    expect(profile?.fields?.uid).toBeUndefined();
  });

  it("treats concurrent Worker profile bootstraps as idempotent", async () => {
    const user = await newUser("bootstrap-race");
    try {
      const results = await Promise.all([
        api(user.idToken, "/api/v1/auth/profile/bootstrap", { name: "Worker Bootstrap" }),
        api(user.idToken, "/api/v1/auth/profile/bootstrap", { name: "Concurrent Bootstrap" }),
      ]);
      expect(results.map(({ response }) => response.status)).toEqual([200, 200]);
      expect(results.filter(({ data }) => data.created === true)).toHaveLength(1);
      expect(results.filter(({ data }) => data.created === false)).toHaveLength(1);
      const profile = await db.get(`users/${user.localId}`);
      expect(profile?.fields?.role).toEqual({ stringValue: "customer" });
    } finally {
      await db.commit([{
        delete: `projects/demo-localspot/databases/(default)/documents/users/${user.localId}`,
      }]);
      const deletion = await fetch(`${authUrl}/identitytoolkit.googleapis.com/v1/accounts:delete?key=emulator`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ idToken: user.idToken }),
      });
      expect(deletion.ok).toBe(true);
    }
  });

  it("deletes a recently authenticated customer and removes personal Firestore records", async () => {
    const user = await newUser("account-delete");
    await api(user.idToken, "/api/v1/auth/profile/bootstrap", {});
    await db.create("favorites", { uid: user.localId, storeId: 123 });
    await db.create("feedback", { uid: user.localId, body: "remove me" });
    await db.create("stores", { ownerUid: user.localId, status: "pending" }, `pending-${user.localId}`);
    const result = await api(user.idToken, "/api/v1/account/delete", {});
    expect(result.response.status).toBe(200);
    expect(await db.get(`users/${user.localId}`)).toBeNull();
    expect(await db.query("favorites", [{ field: "uid", op: "EQUAL", value: user.localId }], 10)).toHaveLength(0);
    expect(await db.query("feedback", [{ field: "uid", op: "EQUAL", value: user.localId }], 10)).toHaveLength(0);
    expect(await db.get(`stores/pending-${user.localId}`)).toBeNull();
  }, 30_000);

  it("paginates actual Firestore media derivative subcollections", async () => {
    const assetId = `pagination-${crypto.randomUUID()}`;
    const parentPath = `mediaAssets/${assetId}`;
    const revisionPaths = ["a", "b", "c"].map((revision) => `${parentPath}/derivatives/${revision}`);
    await db.set(parentPath, { uid: assetId, mediaType: "panorama" });
    try {
      await db.commit(revisionPaths.map((path, index) => ({
        update: {
          name: `projects/demo-localspot/databases/(default)/documents/${path}`,
          fields: { revision: { stringValue: String(index) } },
        },
      })));

      const revisions = await db.listSubcollection(parentPath, "derivatives", 2);

      expect(revisions.map((revision) => revision.name)).toEqual(revisionPaths.map((path) =>
        `projects/demo-localspot/databases/(default)/documents/${path}`));
    } finally {
      await db.commit([
        ...revisionPaths.map((path) => ({ delete: `projects/demo-localspot/databases/(default)/documents/${path}` })),
        { delete: `projects/demo-localspot/databases/(default)/documents/${parentPath}` },
      ]);
    }
  });

  it("deletes panorama revision objects and releases their quota with the account", async () => {
    const user = await newUser("account-delete-panorama");
    await api(user.idToken, "/api/v1/auth/profile/bootstrap", {});
    const assetId = "account-delete-panorama";
    const mediaPath = `mediaAssets/${user.localId}_${assetId}`;
    const tourId = 910_000_000 + Math.floor(Math.random() * 10_000_000);
    const tourPath = `tours/account-delete-${tourId}`;
    const originalKey = `tours/originals/${user.localId}/${tourId}/original`;
    const derivativeKeys = [0, 1].map((index) => `tours/derivatives/${user.localId}/${tourId}/${index + 1}/${"a".repeat(32)}_${String(index).repeat(64)}.jpg`);
    const objectKeys = [originalKey, ...derivativeKeys];
    const ledgerIds = await Promise.all(objectKeys.map(async (key) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key))), (byte) => byte.toString(16).padStart(2, "0")).join("")));
    const quotaPath = "projects/demo-localspot/databases/(default)/documents/system_config/storage_quota";
    const derivativePaths = ["revision-a", "revision-b"].map((revision) => `${mediaPath}/derivatives/${revision}`);
    const objects = new Set(objectKeys);
    const originalEnv = { privateJwk: env.R2_GATEWAY_PRIVATE_JWK, gatewayUrl: env.R2_GATEWAY_URL };
    const realFetch = globalThis.fetch;

    try {
      await db.create("mediaAssets", {
        uid: user.localId, assetId, mediaType: "panorama", status: "awaiting-privacy-processing",
        originalPath: originalKey, objectKey: originalKey, latestDerivativeObjectKey: derivativeKeys[1],
        linkedTourId: tourId, accountingState: "counted",
      }, `${user.localId}_${assetId}`);
      for (let index = 0; index < derivativePaths.length; index++) {
        const revisionId = index ? "revision-b" : "revision-a";
        const response = await fetch(`${firestoreUrl}/v1/projects/demo-localspot/databases/(default)/documents/${mediaPath}/derivatives?documentId=${revisionId}`, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer owner" },
          body: JSON.stringify({ fields: { objectKey: { stringValue: derivativeKeys[index] }, status: { stringValue: "verified" }, accountingState: { stringValue: "counted" } } }),
        });
        expect(response.ok).toBe(true);
      }
      await db.create("tours", {
        numericId: tourId, ownerUid: user.localId, status: "draft",
        nodes: [{ id: 1, original_path: originalKey }],
      }, tourPath.split("/")[1]);
      await db.commit([{ delete: quotaPath }]);
      await db.create("system_config", {
        storageProvider: "cloudflare_r2", limitBytes: 9_000_000_000,
        usedBytes: objectKeys.length * 100, reservedBytes: 0,
        remainingBytes: 9_000_000_000 - objectKeys.length * 100,
        usagePercent: 0, uploadEnabled: true, maintenanceLock: false,
      }, "storage_quota");
      for (let index = 0; index < objectKeys.length; index++) {
        await db.create("storageObjects", {
          objectKey: objectKeys[index], sizeBytes: 100, uid: user.localId,
          assetId, mediaType: "panorama", accountingState: "counted", countedInQuota: true,
        }, ledgerIds[index]);
      }
      const keyPair = await generateKeyPair("ES256", { extractable: true });
      const privateJwk = await exportJWK(keyPair.privateKey);
      privateJwk.kid = `account-delete-${crypto.randomUUID()}`;
      env.R2_GATEWAY_PRIVATE_JWK = JSON.stringify(privateJwk);
      env.R2_GATEWAY_URL = "http://127.0.0.1:8787";
      globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
        const target = new URL(typeof input === "string" || input instanceof URL ? input.toString() : input.url);
        if (target.origin !== "http://127.0.0.1:8787") return realFetch(input, init);
        const key = target.searchParams.get("key") ?? "";
        if (target.pathname === "/v1/internal/object" && init?.method === "DELETE") {
          const existed = objects.delete(key);
          return Response.json({ deleted: true, existed });
        }
        if (target.pathname === "/v1/internal/object" && init?.method === "HEAD") {
          return objects.has(key) ? new Response(null, { status: 200, headers: { "Content-Length": "100" } }) : new Response(null, { status: 404 });
        }
        return new Response("unsupported", { status: 405 });
      };

      const result = await api(user.idToken, "/api/v1/account/delete", {});

      expect(result.response.status, String(result.data.error)).toBe(200);
      expect(objects.size).toBe(0);
      expect(documentData(await db.get("system_config/storage_quota"))?.usedBytes).toBe(0);
      expect(documentData(await db.get(`storageObjects/${ledgerIds[0]}`))?.accountingState).toBe("deleted");
      for (const path of derivativePaths) expect(documentData(await db.get(path))?.status).toBe("deleted");
      expect(documentData(await db.get(mediaPath))?.uid).toBeNull();
      expect(documentData(await db.get(mediaPath))?.status).toBe("deleted");
      expect(await db.get(tourPath)).toBeNull();
    } finally {
      globalThis.fetch = realFetch;
      if (originalEnv.privateJwk === undefined) delete env.R2_GATEWAY_PRIVATE_JWK;
      else env.R2_GATEWAY_PRIVATE_JWK = originalEnv.privateJwk;
      if (originalEnv.gatewayUrl === undefined) delete env.R2_GATEWAY_URL;
      else env.R2_GATEWAY_URL = originalEnv.gatewayUrl;
      await db.commit([
        ...derivativePaths.map((path) => ({ delete: `projects/demo-localspot/databases/(default)/documents/${path}` })),
        ...ledgerIds.map((id) => ({ delete: `projects/demo-localspot/databases/(default)/documents/storageObjects/${id}` })),
        { delete: `projects/demo-localspot/databases/(default)/documents/${mediaPath}` },
        { delete: `projects/demo-localspot/databases/(default)/documents/${tourPath}` },
        { delete: quotaPath },
      ]);
    }
  }, 30_000);

  it("enforces feedback and report limits using Firestore transactions", async () => {
    const user = await newUser("limits");
    await api(user.idToken, "/api/v1/auth/profile/bootstrap", {});
    for (let i = 0; i < 5; i++) expect((await api(user.idToken, "/api/v1/feedback", { topic: "test", body: `feedback ${i}` })).response.status).toBe(200);
    expect((await api(user.idToken, "/api/v1/feedback", { topic: "test", body: "sixth" })).response.status).toBe(429);
    for (let i = 0; i < 10; i++) expect((await api(user.idToken, "/api/v1/reports", { target: "store", reason: `report ${i}` })).response.status).toBe(200);
    expect((await api(user.idToken, "/api/v1/reports", { target: "store", reason: "eleventh" })).response.status).toBe(429);
  }, 30_000);

  it("protects vendor sessions by store access, starter identity, and update throttle", async () => {
    const owner = await newUser("vendor-owner");
    const other = await newUser("vendor-other");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    await api(other.idToken, "/api/v1/auth/profile/bootstrap", {});
    const storeId = 600_000_000 + Math.floor(Math.random() * 10_000_000);
    await seedStore(owner.localId, storeId);
    const payload = { storeId, lat: 10.3, lng: 123.9 };
    expect((await api(owner.idToken, "/api/v1/vendor-locations/sessions/start", payload)).response.status).toBe(200);
    expect((await api(owner.idToken, "/api/v1/vendor-locations/sessions/start", payload)).response.status).toBe(409);
    expect((await api(other.idToken, "/api/v1/vendor-locations/sessions/stop", { storeId })).response.status).toBe(403);
    expect((await api(owner.idToken, "/api/v1/vendor-locations/sessions/update", payload)).response.status).toBe(429);
    expect((await api(owner.idToken, "/api/v1/vendor-locations/sessions/stop", { storeId })).response.status).toBe(200);
  }, 30_000);

  it("creates pending promotions and lets only an admin review them", async () => {
    const owner = await newUser("promotion-owner");
    const admin = await newUser("promotion-admin");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    await api(admin.idToken, "/api/v1/auth/profile/bootstrap", {});
    const storeId = 700_000_000 + Math.floor(Math.random() * 10_000_000);
    await seedStore(owner.localId, storeId);
    const now = new Date();
    const created = await api(owner.idToken, "/api/v1/promotions", {
      storeId,
      title: "Test promotion",
      offer: "10% off",
      starts_at: now.toISOString(),
      ends_at: new Date(now.getTime() + 86_400_000).toISOString(),
      sponsored: true,
    });
    const denied = await api(owner.idToken, "/api/v1/admin/promotions/review", { promotionId: created.data.id, status: "approved" });
    expect(created.data.status).toBe("pending");
    expect(denied.response.status).toBe(403);
    const adminDoc = `projects/demo-localspot/databases/(default)/documents/users/${admin.localId}`;
    await db.commit([{ update: { name: adminDoc, fields: { role: { stringValue: "admin" } } }, updateMask: { fieldPaths: ["role"] } }]);
    const reviewed = await api(admin.idToken, "/api/v1/admin/promotions/review", { promotionId: created.data.id, status: "approved" });
    expect(reviewed.response.status).toBe(200);
    expect(reviewed.data.status).toBe("approved");
    const promotion = documentData((await db.query("promotions", [
      { field: "numericId", op: "EQUAL", value: created.data.id },
    ], 1))[0] ?? null);
    expect(promotion?.status).toBe("approved");
    expect(promotion?.sponsoredRequested).toBe(true);
    expect(promotion?.sponsored).toBe(true);

    const rejectedOffer = await api(owner.idToken, "/api/v1/promotions", {
      storeId,
      title: "Rejected sponsored request",
      offer: "Test offer",
      starts_at: now.toISOString(),
      ends_at: new Date(now.getTime() + 86_400_000).toISOString(),
      sponsored: true,
    });
    const ownerReview = await api(owner.idToken, "/api/v1/admin/promotions/review", {
      promotionId: rejectedOffer.data.id,
      status: "rejected",
    });
    expect(ownerReview.response.status).toBe(403);
    const rejected = await api(admin.idToken, "/api/v1/admin/promotions/review", {
      promotionId: rejectedOffer.data.id,
      status: "rejected",
    });
    expect(rejected.response.status).toBe(200);
    const rejectedPromotion = documentData((await db.query("promotions", [
      { field: "numericId", op: "EQUAL", value: rejectedOffer.data.id },
    ], 1))[0] ?? null);
    expect(rejectedPromotion?.status).toBe("rejected");
    expect(rejectedPromotion?.sponsored).toBe(false);
  }, 30_000);

  it("submits a store, reviews it, manages staff grants, and protects listings", async () => {
    const owner = await newUser("store-owner");
    const staff = await newUser("store-staff");
    const admin = await newUser("store-admin");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    await api(staff.idToken, "/api/v1/auth/profile/bootstrap", {});
    await api(admin.idToken, "/api/v1/auth/profile/bootstrap", {});
    const application = await api(owner.idToken, "/api/v1/stores/applications", {
      type: "sariSari",
      is_mobile: false,
      name: "Integration Store",
      lat: 10.2,
      lng: 123.8,
      barangay: "Central",
      city: "Cebu",
      address: "1 Main",
      schedule: "Daily",
    });
    expect(application.data.status).toBe("pending");
    expect((await api(owner.idToken, "/api/v1/stores/applications", {
      type: "sariSari", is_mobile: false, name: "Duplicate", lat: 10, lng: 123,
    })).response.status).toBe(409);
    const updated = await api(owner.idToken, "/api/v1/stores/update", { storeId: application.data.id, lat: 10.25, lng: 123.85 });
    expect(updated.response.status).toBe(200);
    const adminPath = `projects/demo-localspot/databases/(default)/documents/users/${admin.localId}`;
    await db.commit([{ update: { name: adminPath, fields: { role: { stringValue: "admin" } } }, updateMask: { fieldPaths: ["role"] } }]);
    const review = await api(admin.idToken, "/api/v1/admin/stores/review", { storeId: application.data.id, status: "approved" });
    expect(review.data.status).toBe("approved");
    const staffProfile = documentData(await db.get(`users/${staff.localId}`))!;
    const membership = await api(owner.idToken, "/api/v1/stores/members/manage", {
      storeId: application.data.id,
      userNumericId: staffProfile.numericId,
      action: "set",
      inventory: true,
      promotions: false,
      location: true,
    });
    expect(membership.response.status).toBe(200);
    const directory = await api(owner.idToken, "/api/v1/stores/members", { storeId: application.data.id });
    expect(directory.data.members).toHaveLength(1);
    expect((directory.data.members as Array<{ store_grants: Array<{ inventory: boolean }> }>)[0].store_grants[0].inventory).toBe(true);

    const listing = await api(staff.idToken, "/api/v1/listings", {
      storeId: application.data.id,
      price: 35.5,
      quantity: 4,
      unit: "piece",
      availability: "in_stock",
      name: "Integration product",
      category: "Groceries",
    });
    expect(listing.response.status).toBe(200);
    const movements = await api(staff.idToken, "/api/v1/listings/movements", { listingId: listing.data.id });
    expect(movements.data.movements).toHaveLength(1);
    expect((await api(owner.idToken, "/api/v1/listings/update", { listingId: listing.data.id, quantity: 8 })).response.status).toBe(200);
    expect((await api(owner.idToken, "/api/v1/listings/archive", { listingId: listing.data.id })).response.status).toBe(200);
    const removed = await api(owner.idToken, "/api/v1/stores/members/manage", {
      storeId: application.data.id,
      userNumericId: staffProfile.numericId,
      action: "remove",
    });
    expect(removed.response.status).toBe(200);
    expect((await api(staff.idToken, "/api/v1/listings/movements", { listingId: listing.data.id })).response.status).toBe(403);
  }, 45_000);

  it("approves a store photo only after reserving, publishing, and accounting for its R2 copy", async () => {
    const owner = await newUser("store-photo-owner"), admin = await newUser("store-photo-admin");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    await api(admin.idToken, "/api/v1/auth/profile/bootstrap", {});
    const storeId = 1_500_000_000 + Math.floor(Math.random() * 10_000_000);
    const storeDocId = `review-${storeId}`, assetId = `photo-${crypto.randomUUID()}`;
    const sourceKey = `stores/processed/${owner.localId}/${assetId}.jpg`, publicKey = `stores/public/${storeId}/${assetId}.jpg`;
    const sourceBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
    const adminName = `projects/demo-localspot/databases/(default)/documents/users/${admin.localId}`;
    await db.commit([{ update: { name: adminName, fields: { role: { stringValue: "admin" } } }, updateMask: { fieldPaths: ["role"] } }]);
    await db.create("stores", { numericId: storeId, ownerUid: owner.localId, status: "pending", lat: 10.2, lng: 123.8 }, storeDocId);
    await db.create("mediaAssets", { uid: owner.localId, assetId, mediaType: "store", status: "ready", linkedStoreId: storeId, privatePath: sourceKey, objectKey: sourceKey, size: sourceBytes.length, contentType: "image/jpeg", extension: "jpg", accountingState: "counted" }, `${owner.localId}_${assetId}`);
    const quotaName = "projects/demo-localspot/databases/(default)/documents/system_config/storage_quota";
    await db.commit([{ delete: quotaName }]);
    await db.create("system_config", { storageProvider: "cloudflare_r2", limitBytes: 9_000_000_000, usedBytes: sourceBytes.length, reservedBytes: 0, remainingBytes: 9_000_000_000 - sourceBytes.length, usagePercent: 0, uploadEnabled: true, maintenanceLock: false }, "storage_quota");
    const hashPath = async (key: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key))), (byte) => byte.toString(16).padStart(2, "0")).join("");
    const sourceLedgerId = await hashPath(sourceKey), publicLedgerId = await hashPath(publicKey);
    await db.create("storageObjects", { objectKey: sourceKey, sizeBytes: sourceBytes.length, uid: owner.localId, assetId, mediaType: "store", accountingState: "counted", countedInQuota: true }, sourceLedgerId);
    const keys = await generateKeyPair("ES256", { extractable: true });
    const privateJwk = await exportJWK(keys.privateKey);
    privateJwk.kid = `store-review-${crypto.randomUUID()}`;
    env.R2_GATEWAY_PRIVATE_JWK = JSON.stringify(privateJwk);
    env.R2_GATEWAY_URL = "http://127.0.0.1:8787";
    const objects = new Map<string, { bytes: Uint8Array; contentType: string; metadata: Record<string, unknown> }>([[sourceKey, { bytes: sourceBytes, contentType: "image/jpeg", metadata: { reservationId: "source-reservation", uid: owner.localId, mediaType: "store" } }]]);
    const realFetch = globalThis.fetch;
    globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const target = new URL(typeof input === "string" || input instanceof URL ? input.toString() : input.url);
      if (target.origin !== "http://127.0.0.1:8787") return realFetch(input, init);
      const key = target.searchParams.get("key") ?? "", current = objects.get(key);
      if (target.pathname === "/v1/internal/object" && init?.method === "HEAD") return current
        ? new Response(null, { status: 200, headers: { "Content-Length": String(current.bytes.length), "Content-Type": current.contentType, "X-Object-Reservation-Id": String(current.metadata.reservationId), "X-Object-Uid": String(current.metadata.uid), "X-Object-Media-Type": String(current.metadata.mediaType), "X-Object-Public-Approved": String(current.metadata.publicApproved ?? false) } })
        : new Response(null, { status: 404 });
      if (target.pathname === "/v1/internal/object" && (!init?.method || init.method === "GET")) return current ? new Response(current.bytes as BodyInit, { headers: { "Content-Type": current.contentType } }) : new Response("missing", { status: 404 });
      if (target.pathname === "/v1/internal/object" && init?.method === "PUT") {
        const token = String(new Headers(init.headers).get("X-Gateway-Authorization")?.split(".")[1]);
        const metadata = JSON.parse(atob(token.replace(/-/g, "+").replace(/_/g, "/"))) as Record<string, unknown>;
        const bytes = new Uint8Array(await new Response(init.body).arrayBuffer());
        objects.set(key, { bytes, contentType: String(metadata.contentType), metadata });
        return Response.json({ key, size: bytes.length }, { status: 201 });
      }
      if (target.pathname === "/v1/internal/object" && init?.method === "DELETE") { objects.delete(key); return Response.json({ deleted: true, existed: Boolean(current) }); }
      if (target.pathname === "/v1/internal/publish" && init?.method === "POST") {
        if (!current) return Response.json({ error: "missing" }, { status: 404 });
        current.metadata.publicApproved = true;
        return Response.json({ published: true, key, size: current.bytes.length });
      }
      return new Response("unsupported", { status: 405 });
    };
    try {
      const result = await api(admin.idToken, "/api/v1/admin/stores/review", { storeId, status: "approved" });
      expect(result.response.status, String(result.data.error)).toBe(200);
      expect(result.data.status).toBe("approved");
      expect(objects.has(sourceKey)).toBe(false);
      expect(objects.get(publicKey)?.metadata.publicApproved).toBe(true);
      const media = documentData(await db.get(`mediaAssets/${owner.localId}_${assetId}`));
      expect(media?.status).toBe("ready");
      expect(media?.privatePath).toBeUndefined();
      expect(media?.publicPath).toBe(publicKey);
      expect(documentData(await db.get("system_config/storage_quota"))?.usedBytes).toBe(sourceBytes.length);
      expect(documentData(await db.get(`storageObjects/${publicLedgerId}`))?.accountingState).toBe("counted");
    } finally {
      globalThis.fetch = realFetch;
      delete env.R2_GATEWAY_PRIVATE_JWK;
      delete env.R2_GATEWAY_URL;
      await db.commit([
        { delete: `projects/demo-localspot/databases/(default)/documents/stores/${storeDocId}` },
        { delete: `projects/demo-localspot/databases/(default)/documents/mediaAssets/${owner.localId}_${assetId}` },
        { delete: `projects/demo-localspot/databases/(default)/documents/storageObjects/${sourceLedgerId}` },
        { delete: `projects/demo-localspot/databases/(default)/documents/storageObjects/${publicLedgerId}` },
        { delete: `projects/demo-localspot/databases/(default)/documents/uploadReservations/publish_${storeId}_${assetId}` },
        { delete: quotaName },
      ]);
    }
  }, 30_000);

  it("creates an idempotent draft tour and connects only its owner's viewpoints", async () => {
    const owner = await newUser("tour-owner");
    const other = await newUser("tour-other");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    await api(other.idToken, "/api/v1/auth/profile/bootstrap", {});
    const storeId = 800_000_000 + Math.floor(Math.random() * 10_000_000);
    await seedStore(owner.localId, storeId);
    const first = await api(owner.idToken, "/api/v1/tours/manage", { action: "create", storeId, title: "Draft tour" });
    const retry = await api(owner.idToken, "/api/v1/tours/manage", { action: "create", storeId, title: "Different retry title" });
    expect(first.response.status).toBe(200);
    expect(retry.data.id).toBe(first.data.id);
    const tourId = Number(first.data.id);
    const tourDocument = (await db.query("tours", [{ field: "numericId", op: "EQUAL", value: tourId }], 1))[0];
    const fullName = tourDocument.name;
    const path = fullName.slice(fullName.indexOf("/documents/") + "/documents/".length);
    await db.commit([{ update: { name: fullName, fields: { nodes: { arrayValue: { values: [
      { mapValue: { fields: { id: { integerValue: "1" }, connections: { arrayValue: { values: [] } } } } },
      { mapValue: { fields: { id: { integerValue: "2" }, connections: { arrayValue: { values: [] } } } } },
    ] } } } }, updateMask: { fieldPaths: ["nodes"] } }]);
    const linked = await api(owner.idToken, "/api/v1/tours/manage", { action: "connect", tourId, fromNodeId: 1, toNodeId: 2 });
    expect(linked.response.status).toBe(200);
    const denied = await api(other.idToken, "/api/v1/tours/manage", { action: "connect", tourId, fromNodeId: 1, toNodeId: 2 });
    expect(denied.response.status).toBe(403);
    expect(await db.get(path)).not.toBeNull();
  }, 30_000);

  it("restricts storage quota reporting to admins and returns Firestore aggregate counts", async () => {
    const admin = await newUser("quota-admin");
    const customer = await newUser("quota-customer");
    await api(admin.idToken, "/api/v1/auth/profile/bootstrap", {});
    await api(customer.idToken, "/api/v1/auth/profile/bootstrap", {});
    const adminName = `projects/demo-localspot/databases/(default)/documents/users/${admin.localId}`;
    await db.commit([{ update: { name: adminName, fields: { role: { stringValue: "admin" } } }, updateMask: { fieldPaths: ["role"] } }]);
    await db.create("mediaAssets", { status: "ready", mediaType: "product" });
    await db.create("mediaAssets", { status: "awaiting-privacy-processing", mediaType: "panorama" });
    await db.create("uploadReservations", { status: "reserved" });
    const denied = await api(customer.idToken, "/api/v1/admin/storage/quota", {});
    expect(denied.response.status).toBe(403);
    expect((await api(customer.idToken, "/api/v1/admin/storage/reconcile", {})).response.status).toBe(403);
    expect((await api(customer.idToken, "/api/v1/admin/media/cleanup-reservations", {})).response.status).toBe(403);
    const result = await api(admin.idToken, "/api/v1/admin/storage/quota", {});
    expect(result.response.status).toBe(200);
    expect(result.data.storedImages).toBeGreaterThanOrEqual(1);
    expect(result.data.storedPanoramas).toBeGreaterThanOrEqual(1);
    expect(result.data.pendingUploads).toBeGreaterThanOrEqual(1);
    expect((await api(customer.idToken, "/api/v1/admin/storage/orphans/delete", { key: "products/public/example/image.jpg" })).response.status).toBe(403);
    const protectedKey = `products/public/example/${crypto.randomUUID()}.jpg`;
    const ledgerId = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(protectedKey))), (byte) => byte.toString(16).padStart(2, "0")).join("");
    await db.create("storageObjects", { objectKey: protectedKey, accountingState: "counted", countedInQuota: true, orphaned: false }, ledgerId);
    const protectedObject = await api(admin.idToken, "/api/v1/admin/storage/orphans/delete", { key: protectedKey });
    expect(protectedObject.response.status).toBe(412);
  }, 30_000);

  it("reserves upload bytes and issues a gateway-compatible owner-bound token", async () => {
    const owner = await newUser("media-owner");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    const profileName = `projects/demo-localspot/databases/(default)/documents/users/${owner.localId}`;
    await db.commit([{ update: { name: profileName, fields: { role: { stringValue: "owner" } } }, updateMask: { fieldPaths: ["role"] } }]);
    const quotaName = "projects/demo-localspot/databases/(default)/documents/system_config/storage_quota";
    await db.commit([{ delete: quotaName }]);
    await db.create("system_config", { storageProvider: "cloudflare_r2", limitBytes: 9_000_000_000, usedBytes: 100, reservedBytes: 0, remainingBytes: 8_999_999_900, usagePercent: 100 / 9_000_000_000 * 100, uploadEnabled: true, maintenanceLock: false }, "storage_quota");
    const keys = await generateKeyPair("ES256", { extractable: true });
    const privateJwk = await exportJWK(keys.privateKey);
    const publicJwk = await exportJWK(keys.publicKey);
    privateJwk.kid = publicJwk.kid = `local-${crypto.randomUUID()}`;
    env.R2_GATEWAY_PRIVATE_JWK = JSON.stringify(privateJwk);
    env.R2_GATEWAY_URL = "http://127.0.0.1:8787";
    try {
      const assetId = `asset-${crypto.randomUUID()}`;
      const reserved = await api(owner.idToken, "/api/v1/media/reservations", { mediaType: "product", assetId, contentType: "image/jpeg", expectedBytes: 1234 });
      expect(reserved.response.status).toBe(200);
      expect(reserved.data.objectKey).toBe(`products/quarantine/${owner.localId}/${assetId}`);
      expect(String(reserved.data.uploadUrl)).toContain("/v1/uploads/");
      const { payload } = await jwtVerify(String(reserved.data.uploadToken), await importJWK(publicJwk, "ES256"), { issuer: "localspot-functions", audience: "locentra-upload-gateway" });
      expect(payload.sub).toBe(owner.localId);
      expect(payload.scope).toBe("upload");
      expect(payload.jti).toBe(reserved.data.reservationId);
      expect(payload.objectKey).toBe(reserved.data.objectKey);
      expect(payload.maxBytes).toBe(1234);
      expect((await api(owner.idToken, "/api/v1/media/reservations", { mediaType: "product", assetId, contentType: "image/jpeg", expectedBytes: 1234 })).response.status).toBe(409);
      const quota = documentData(await db.get("system_config/storage_quota"));
      expect(quota?.reservedBytes).toBe(1234);
      const reservation = await db.get(`uploadReservations/${String(reserved.data.reservationId)}`);
      expect(documentData(reservation)?.status).toBe("reserved");
      await db.commit([{ delete: reservation!.name }, { delete: `projects/demo-localspot/databases/(default)/documents/mediaAssets/${owner.localId}_${assetId}` }]);
    } finally {
      delete env.R2_GATEWAY_PRIVATE_JWK;
      delete env.R2_GATEWAY_URL;
      await db.commit([{ delete: quotaName }]);
    }
  }, 30_000);

  it("serializes concurrent quota reservations and rejects bytes beyond the hard limit", async () => {
    const owner = await newUser("media-quota-race");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    const profileName = `projects/demo-localspot/databases/(default)/documents/users/${owner.localId}`;
    await db.commit([{ update: { name: profileName, fields: { role: { stringValue: "owner" } } }, updateMask: { fieldPaths: ["role"] } }]);
    const quotaName = "projects/demo-localspot/databases/(default)/documents/system_config/storage_quota";
    await db.commit([{ delete: quotaName }]);
    await db.create("system_config", { storageProvider: "cloudflare_r2", limitBytes: 9_000_000_000, usedBytes: 9_000_000_000 - 100, reservedBytes: 0, remainingBytes: 100, usagePercent: 100, uploadEnabled: true, maintenanceLock: false }, "storage_quota");
    const keys = await generateKeyPair("ES256", { extractable: true });
    const privateJwk = await exportJWK(keys.privateKey), publicJwk = await exportJWK(keys.publicKey);
    privateJwk.kid = publicJwk.kid = `quota-race-${crypto.randomUUID()}`;
    env.R2_GATEWAY_PRIVATE_JWK = JSON.stringify(privateJwk);
    env.R2_GATEWAY_URL = "http://127.0.0.1:8787";
    const assetIds = ["race-a", "race-b", "race-c"].map((suffix) => `${suffix}-${crypto.randomUUID()}`);
    let successfulReservation: string | undefined;
    try {
      const concurrent = await Promise.all(assetIds.slice(0, 2).map((assetId) => api(owner.idToken, "/api/v1/media/reservations", {
        mediaType: "product", assetId, contentType: "image/jpeg", expectedBytes: 60,
      })));
      expect(concurrent.map(({ response }) => response.status).sort(), JSON.stringify(concurrent.map(({ data }) => data))).toEqual([200, 429]);
      const success = concurrent.find(({ response }) => response.status === 200)!;
      successfulReservation = String(success.data.reservationId);
      expect(documentData(await db.get("system_config/storage_quota"))?.reservedBytes).toBe(60);

      const beyondLimit = await api(owner.idToken, "/api/v1/media/reservations", {
        mediaType: "product", assetId: assetIds[2], contentType: "image/jpeg", expectedBytes: 41,
      });
      expect(beyondLimit.response.status).toBe(429);
      expect(documentData(await db.get("system_config/storage_quota"))?.reservedBytes).toBe(60);
    } finally {
      const deletes: Array<{ delete: string }> = [{ delete: quotaName }, { delete: `projects/demo-localspot/databases/(default)/documents/systemRateLimits/${owner.localId}_mediaUpload` }];
      if (successfulReservation) deletes.push({ delete: `projects/demo-localspot/databases/(default)/documents/uploadReservations/${successfulReservation}` });
      for (const assetId of assetIds) deletes.push({ delete: `projects/demo-localspot/databases/(default)/documents/mediaAssets/${owner.localId}_${assetId}` });
      await db.commit(deletes);
      delete env.R2_GATEWAY_PRIVATE_JWK;
      delete env.R2_GATEWAY_URL;
    }
  }, 30_000);

  it("finalizes a product image through the gateway and moves quota to the sanitized object", async () => {
    const owner = await newUser("media-finalize");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    const profileName = `projects/demo-localspot/databases/(default)/documents/users/${owner.localId}`;
    await db.commit([{ update: { name: profileName, fields: { role: { stringValue: "owner" } } }, updateMask: { fieldPaths: ["role"] } }]);
    const quotaName = "projects/demo-localspot/databases/(default)/documents/system_config/storage_quota";
    await db.commit([{ delete: quotaName }]);
    await db.create("system_config", { storageProvider: "cloudflare_r2", limitBytes: 9_000_000_000, usedBytes: 0, reservedBytes: 0, remainingBytes: 9_000_000_000, usagePercent: 0, uploadEnabled: true, maintenanceLock: false }, "storage_quota");
    const keys = await generateKeyPair("ES256", { extractable: true });
    const privateJwk = await exportJWK(keys.privateKey), publicJwk = await exportJWK(keys.publicKey);
    privateJwk.kid = publicJwk.kid = `finalize-${crypto.randomUUID()}`;
    env.R2_GATEWAY_PRIVATE_JWK = JSON.stringify(privateJwk);
    env.R2_GATEWAY_URL = "http://127.0.0.1:8787";
    const objects = new Map<string, { bytes: Uint8Array; contentType: string; reservationId: string; uid: string; mediaType: string }>();
    const realFetch = globalThis.fetch;
    let cleanupAssetId: string | undefined, cleanupReservationId: string | undefined;
    globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const target = new URL(typeof input === "string" || input instanceof URL ? input.toString() : input.url);
      if (target.origin !== "http://127.0.0.1:8787") return realFetch(input, init);
      const key = target.searchParams.get("key") ?? "";
      const existing = objects.get(key);
      if (init?.method === "HEAD") return existing
        ? new Response(null, { status: 200, headers: { "Content-Length": String(existing.bytes.length), "Content-Type": existing.contentType, "X-Object-Reservation-Id": existing.reservationId, "X-Object-Uid": existing.uid, "X-Object-Media-Type": existing.mediaType } })
        : new Response(null, { status: 404 });
      if (init?.method === "DELETE") { objects.delete(key); return Response.json({ deleted: true, existed: Boolean(existing) }); }
      if (init?.method === "PUT") {
        const payload = JSON.parse(atob(String(new Headers(init.headers).get("X-Gateway-Authorization")?.split(".")[1]).replace(/-/g, "+").replace(/_/g, "/"))) as Record<string, unknown>;
        const bytes = new Uint8Array(await new Response(init.body).arrayBuffer());
        objects.set(key, { bytes, contentType: String(payload.contentType), reservationId: String(payload.reservationId), uid: String(payload.uid), mediaType: String(payload.mediaType) });
        return Response.json({ key, size: bytes.length }, { status: 201 });
      }
      if (init?.method === "GET" || !init?.method) return existing ? new Response(existing.bytes as BodyInit, { headers: { "Content-Type": existing.contentType } }) : new Response("missing", { status: 404 });
      return new Response("unsupported", { status: 405 });
    };
    try {
      const assetId = `asset-${crypto.randomUUID()}`;
      cleanupAssetId = assetId;
      const bytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 1, 2, 0xff, 0xda, 0x00, 0x02, 1, 2, 0xff, 0xd9]);
      const reservation = await api(owner.idToken, "/api/v1/media/reservations", { mediaType: "product", assetId, contentType: "image/jpeg", expectedBytes: bytes.length });
      cleanupReservationId = String(reservation.data.reservationId);
      objects.set(String(reservation.data.objectKey), { bytes, contentType: "image/jpeg", reservationId: String(reservation.data.reservationId), uid: owner.localId, mediaType: "product" });
      const finalized = await api(owner.idToken, "/api/v1/media/finalize", { reservationId: reservation.data.reservationId });
      expect(finalized.response.status).toBe(200);
      expect(finalized.data.status).toBe("ready");
      expect(finalized.data.downloadUrl).toContain("/v1/media/public/");
      expect(objects.has(String(reservation.data.objectKey))).toBe(false);
      const media = documentData(await db.get(`mediaAssets/${owner.localId}_${assetId}`));
      expect(media?.status).toBe("ready");
      expect(media?.metadataStripped).toBe(true);
      expect(media?.accountingState).toBe("counted");
      const quota = documentData(await db.get("system_config/storage_quota"));
      expect(quota?.usedBytes).toBe((objects.values().next().value as { bytes: Uint8Array }).bytes.length);
      expect(quota?.reservedBytes).toBe(0);
      const processed = await db.get(`uploadReservations/${String(reservation.data.reservationId)}_processed`);
      expect(documentData(processed)?.status).toBe("completed");
      const deleted = await api(owner.idToken, "/api/v1/media/delete", { assetId });
      expect(deleted.response.status).toBe(200);
      expect(deleted.data.ok).toBe(true);
      expect(objects.size).toBe(0);
      expect(documentData(await db.get("system_config/storage_quota"))?.usedBytes).toBe(0);
      expect(documentData(await db.get(`mediaAssets/${owner.localId}_${assetId}`))?.status).toBe("deleted");
      const repeatedDelete = await api(owner.idToken, "/api/v1/media/delete", { assetId });
      expect(repeatedDelete.response.status).toBe(200);
      expect(repeatedDelete.data.ok).toBe(true);
      expect(documentData(await db.get("system_config/storage_quota"))?.usedBytes).toBe(0);
    } finally {
      globalThis.fetch = realFetch;
      delete env.R2_GATEWAY_PRIVATE_JWK;
      delete env.R2_GATEWAY_URL;
      if (cleanupAssetId && cleanupReservationId) {
        const originalKey = `products/quarantine/${owner.localId}/${cleanupAssetId}`;
        const outputKey = `products/public/${owner.localId}/${cleanupAssetId}.jpg`;
        const hashPath = async (key: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key))), (byte) => byte.toString(16).padStart(2, "0")).join("");
        await db.commit([
          { delete: `projects/demo-localspot/databases/(default)/documents/mediaAssets/${owner.localId}_${cleanupAssetId}` },
          { delete: `projects/demo-localspot/databases/(default)/documents/uploadReservations/${cleanupReservationId}` },
          { delete: `projects/demo-localspot/databases/(default)/documents/uploadReservations/${cleanupReservationId}_processed` },
          { delete: `projects/demo-localspot/databases/(default)/documents/storageObjects/${await hashPath(originalKey)}` },
          { delete: `projects/demo-localspot/databases/(default)/documents/storageObjects/${await hashPath(outputKey)}` },
        ]);
      }
      await db.commit([{ delete: quotaName }]);
    }
  }, 30_000);

  it("issues a short-lived private-media capability bound to the requesting account", async () => {
    const owner = await newUser("private-media-owner"), other = await newUser("private-media-other");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    await api(other.idToken, "/api/v1/auth/profile/bootstrap", {});
    const assetId = `private-${crypto.randomUUID()}`, mediaPath = `mediaAssets/${owner.localId}_${assetId}`;
    const mediaName = `projects/demo-localspot/databases/(default)/documents/${mediaPath}`;
    await db.create("mediaAssets", { uid: owner.localId, assetId, mediaType: "store", status: "ready", privatePath: `stores/processed/${owner.localId}/${assetId}.jpg` }, `${owner.localId}_${assetId}`);
    const keys = await generateKeyPair("ES256", { extractable: true });
    const privateJwk = await exportJWK(keys.privateKey), publicJwk = await exportJWK(keys.publicKey);
    privateJwk.kid = publicJwk.kid = `private-${crypto.randomUUID()}`;
    env.R2_GATEWAY_PRIVATE_JWK = JSON.stringify(privateJwk);
    env.R2_GATEWAY_URL = "http://127.0.0.1:8787";
    try {
      const access = await api(owner.idToken, "/api/v1/media/private-access", { assetId });
      expect(access.response.status).toBe(200);
      expect(access.data.url).toContain("/v1/media/private?key=");
      const { payload } = await jwtVerify(String(access.data.token), await importJWK(publicJwk, "ES256"), { issuer: "localspot-functions", audience: "locentra-upload-gateway" });
      expect(payload.sub).toBe(owner.localId);
      expect(payload.scope).toBe("media:read");
      expect(payload.objectKey).toBe(`stores/processed/${owner.localId}/${assetId}.jpg`);
      expect((await api(other.idToken, "/api/v1/media/private-access", { assetId })).response.status).toBe(404);
    } finally {
      delete env.R2_GATEWAY_PRIVATE_JWK;
      delete env.R2_GATEWAY_URL;
      await db.commit([{ delete: mediaName }]);
    }
  }, 30_000);

  it("blocks media deletion while a product, store, or tour still references it", async () => {
    const owner = await newUser("linked-media-owner");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    const assetId = `linked-${crypto.randomUUID()}`;
    await db.create("mediaAssets", { uid: owner.localId, assetId, mediaType: "product", status: "ready", objectKey: `products/public/${owner.localId}/${assetId}.jpg`, linkedProductId: 77 }, `${owner.localId}_${assetId}`);
    try {
      const result = await api(owner.idToken, "/api/v1/media/delete", { assetId });
      expect(result.response.status).toBe(412);
      expect(result.data.error).toContain("Remove this media");
    } finally {
      await db.commit([{ delete: `projects/demo-localspot/databases/(default)/documents/mediaAssets/${owner.localId}_${assetId}` }, { delete: `projects/demo-localspot/databases/(default)/documents/systemRateLimits/${owner.localId}_mediaDelete` }]);
    }
  }, 30_000);

  it("rejects and deletes a panorama derivative whose stored bytes do not match its reserved SHA-256", async () => {
    const owner = await newUser("derivative-digest");
    const reservationId = crypto.randomUUID(), revisionId = crypto.randomUUID().replace(/-/g, "");
    const assetId = `digest-${crypto.randomUUID()}`, tourId = 700_000_000 + Math.floor(Math.random() * 10_000_000), nodeId = 1;
    const bytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 1, 2, 0xff, 0xda, 0x00, 0x02, 1, 2, 0xff, 0xd9]);
    const wrongDigest = "a".repeat(64);
    const objectKey = `tours/derivatives/${owner.localId}/${tourId}/${nodeId}/${revisionId}_${wrongDigest}.jpg`;
    const reservationPath = `uploadReservations/${reservationId}`;
    const quotaName = "projects/demo-localspot/databases/(default)/documents/system_config/storage_quota";
    await db.commit([{ delete: quotaName }]);
    await db.create("system_config", { storageProvider: "cloudflare_r2", limitBytes: 9_000_000_000, usedBytes: 0, reservedBytes: bytes.length, remainingBytes: 9_000_000_000 - bytes.length, usagePercent: bytes.length / 9_000_000_000 * 100, uploadEnabled: true, maintenanceLock: false }, "storage_quota");
    await db.create("uploadReservations", {
      uid: owner.localId, assetId, mediaType: "panorama", purpose: "processed", objectKey,
      reservedBytes: bytes.length, tourId, nodeId, revisionId, derivativeSha256: wrongDigest,
      originalPath: `tours/originals/${owner.localId}/${tourId}/original-${assetId}`,
      status: "reserved", createdAt: new Date(), expiresAt: new Date(Date.now() + 300_000),
    }, reservationId);
    const realFetch = globalThis.fetch;
    const stored = { exists: true };
    const keys = await generateKeyPair("ES256", { extractable: true });
    const privateJwk = await exportJWK(keys.privateKey), publicJwk = await exportJWK(keys.publicKey);
    privateJwk.kid = publicJwk.kid = `digest-${crypto.randomUUID()}`;
    env.R2_GATEWAY_PRIVATE_JWK = JSON.stringify(privateJwk);
    env.R2_GATEWAY_URL = "http://127.0.0.1:8787";
    globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const target = new URL(typeof input === "string" || input instanceof URL ? input.toString() : input.url);
      if (target.origin !== "http://127.0.0.1:8787") return realFetch(input, init);
      if (init?.method === "HEAD") return stored.exists ? new Response(null, { status: 200, headers: {
        "Content-Length": String(bytes.length), "Content-Type": "image/jpeg",
        "X-Object-Reservation-Id": reservationId, "X-Object-Uid": owner.localId,
        "X-Object-Media-Type": "panorama-derivative",
      } }) : new Response(null, { status: 404 });
      if (!init?.method || init.method === "GET") return stored.exists ? new Response(bytes as BodyInit, { headers: { "Content-Type": "image/jpeg" } }) : new Response(null, { status: 404 });
      if (init?.method === "DELETE") { stored.exists = false; return Response.json({ deleted: true, existed: true }); }
      return new Response(null, { status: 404 });
    };
    try {
      const finalized = await api(owner.idToken, "/api/v1/media/panorama-derivative/finalize", { reservationId });
      expect(finalized.response.status, JSON.stringify(finalized.data)).toBe(412);
      expect(stored.exists).toBe(false);
      expect(documentData(await db.get(reservationPath))?.status).toBe("released");
      const quota = documentData(await db.get("system_config/storage_quota"));
      expect(quota?.usedBytes).toBe(0);
      expect(quota?.reservedBytes).toBe(0);
    } finally {
      globalThis.fetch = realFetch;
      delete env.R2_GATEWAY_PRIVATE_JWK;
      delete env.R2_GATEWAY_URL;
      await db.commit([
        { delete: `projects/demo-localspot/databases/(default)/documents/${reservationPath}` },
        { delete: quotaName },
      ]);
    }
  }, 30_000);

  it("reserves an immutable panorama derivative against its verified owner draft", async () => {
    const owner = await newUser("derivative-owner");
    await api(owner.idToken, "/api/v1/auth/profile/bootstrap", {});
    const tourId = 930_000_000 + Math.floor(Math.random() * 10_000_000), storeId = tourId + 10_000_000;
    const assetId = `pano-${crypto.randomUUID()}`;
    const originalPath = `tours/originals/${owner.localId}/${tourId}/${assetId}`;
    const secondAssetId = `pano-${crypto.randomUUID()}`, secondOriginalPath = `tours/originals/${owner.localId}/${tourId}/${secondAssetId}`;
    const storePath = `stores/derivative-${crypto.randomUUID()}`, tourPath = `tours/derivative-${crypto.randomUUID()}`;
    const mediaPath = `mediaAssets/${owner.localId}_${assetId}`, quotaName = "projects/demo-localspot/databases/(default)/documents/system_config/storage_quota";
    const ratePath = `projects/demo-localspot/databases/(default)/documents/systemRateLimits/${owner.localId}_panoramaDerivativeUpload`;
    await db.create("stores", { numericId: storeId, ownerUid: owner.localId, status: "approved" }, storePath.split("/")[1]);
    await db.create("tours", { numericId: tourId, storeId, ownerUid: owner.localId, status: "draft", nodes: [{ id: 1, original_path: originalPath }] }, tourPath.split("/")[1]);
    await db.create("mediaAssets", { uid: owner.localId, assetId, mediaType: "panorama", originalPath, linkedTourId: tourId, status: "awaiting-privacy-processing" }, `${owner.localId}_${assetId}`);
    await db.create("mediaAssets", { uid: owner.localId, assetId: secondAssetId, mediaType: "panorama", originalPath: secondOriginalPath, status: "awaiting-privacy-processing" }, `${owner.localId}_${secondAssetId}`);
    await db.commit([{ delete: quotaName }]);
    await db.create("system_config", { storageProvider: "cloudflare_r2", limitBytes: 9_000_000_000, usedBytes: 100, reservedBytes: 0, remainingBytes: 8_999_999_900, usagePercent: 0, uploadEnabled: true, maintenanceLock: false }, "storage_quota");
    const keys = await generateKeyPair("ES256", { extractable: true });
    const privateJwk = await exportJWK(keys.privateKey), publicJwk = await exportJWK(keys.publicKey);
    privateJwk.kid = publicJwk.kid = `derivative-${crypto.randomUUID()}`;
    env.R2_GATEWAY_PRIVATE_JWK = JSON.stringify(privateJwk);
    env.R2_GATEWAY_URL = "http://127.0.0.1:8787";
    const objects = new Map<string, { bytes: Uint8Array; reservationId: string; uid: string; mediaType: string; sha256?: string; publicApproved?: boolean }>();
    let derivativeFullReads = 0;
    const realFetch = globalThis.fetch;
    globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const target = new URL(typeof input === "string" || input instanceof URL ? input.toString() : input.url);
      if (target.origin === "http://127.0.0.1:8787" && init?.method === "HEAD" && [originalPath, secondOriginalPath].includes(target.searchParams.get("key") ?? "")) {
        return new Response(null, { status: 200, headers: { "Content-Length": "2048", "Content-Type": "image/jpeg", "X-Object-Uid": owner.localId, "X-Object-Media-Type": "panorama" } });
      }
      if (target.origin === "http://127.0.0.1:8787") {
        const key = target.searchParams.get("key") ?? "", stored = objects.get(key);
        if (init?.method === "HEAD") return stored ? new Response(null, { status: 200, headers: { "Content-Length": String(stored.bytes.length), "Content-Type": "image/jpeg", "X-Object-Reservation-Id": stored.reservationId, "X-Object-Uid": stored.uid, "X-Object-Media-Type": stored.mediaType, ...(stored.sha256 ? { "X-Object-Sha256": stored.sha256, "X-Object-Verified-Sha256": stored.sha256 } : {}), ...(stored.publicApproved ? { "X-Object-Public-Approved": "true" } : {}) } }) : new Response(null, { status: 404 });
        if (!init?.method || init.method === "GET") {
          if (stored?.mediaType === "panorama-derivative") derivativeFullReads++;
          return stored ? new Response(stored.bytes as BodyInit, { headers: { "Content-Type": "image/jpeg" } }) : new Response(null, { status: 404 });
        }
        if (init.method === "DELETE") { objects.delete(key); return Response.json({ deleted: true, existed: Boolean(stored) }); }
        if (init.method === "POST" && target.pathname === "/v1/internal/publish" && stored) { stored.publicApproved = true; return Response.json({ published: true, key, size: stored.bytes.length, sha256: stored.sha256 }); }
        return new Response(null, { status: 404 });
      }
      return realFetch(input, init);
    };
    let cleanupReservationId: string | undefined, cleanupRevisionId: string | undefined, cleanupKey: string | undefined, cleanupExtraReservationId: string | undefined, cleanupExtraLedgerId: string | undefined;
    try {
      const addedNode = await api(owner.idToken, "/api/v1/tours/manage", { action: "addNode", tourId, title: "Second viewpoint", originalPath: secondOriginalPath });
      expect(addedNode.response.status).toBe(200);
      expect((addedNode.data.nodes as Array<Record<string, unknown>>).map((node) => node.id)).toEqual([1, 2]);
      expect((addedNode.data.nodes as Array<Record<string, unknown>>)[0].connections).toEqual([2]);
      expect(documentData(await db.get(`mediaAssets/${owner.localId}_${secondAssetId}`))?.linkedTourId).toBe(tourId);
      const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 1, 2, 0xff, 0xda, 0x00, 0x02, 1, 2, 0xff, 0xd9]);
      const sha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", jpeg.slice().buffer as ArrayBuffer)), (byte) => byte.toString(16).padStart(2, "0")).join("");
      const reserved = await api(owner.idToken, "/api/v1/media/panorama-derivative/reservations", { tourId, nodeId: 1, assetId, contentType: "image/jpeg", expectedBytes: 1024, derivativeSha256: sha256, processingVersion: "localspot-panorama-local-v1" });
      expect(reserved.response.status).toBe(200);
      expect(reserved.data.objectKey).toMatch(new RegExp(`^tours/derivatives/${owner.localId}/${tourId}/1/[a-f0-9]{32}_${sha256}\\.jpg$`));
      const { payload } = await jwtVerify(String(reserved.data.uploadToken), await importJWK(publicJwk, "ES256"), { issuer: "localspot-functions", audience: "locentra-upload-gateway" });
      expect(payload.mediaType).toBe("panorama-derivative");
      expect(payload.sub).toBe(owner.localId);
      expect(payload.tourId).toBe(tourId);
      expect(payload.nodeId).toBe(1);
      expect(payload.derivativeSha256).toBe(sha256);
      const reservation = documentData(await db.get(`uploadReservations/${String(reserved.data.reservationId)}`));
      cleanupReservationId = String(reserved.data.reservationId);
      cleanupRevisionId = String(reservation?.revisionId);
      cleanupKey = String(reserved.data.objectKey);
      expect(reservation?.revisionId).toBeTruthy();
      expect(reservation?.processingVersion).toBe("localspot-panorama-local-v1");
      expect(documentData(await db.get("system_config/storage_quota"))?.reservedBytes).toBe(1024);
      objects.set(cleanupKey, { bytes: jpeg, reservationId: cleanupReservationId, uid: owner.localId, mediaType: "panorama-derivative", sha256 });
      const finalized = await api(owner.idToken, "/api/v1/media/panorama-derivative/finalize", { reservationId: cleanupReservationId });
      expect(finalized.response.status).toBe(200);
      expect(derivativeFullReads).toBe(0);
      expect(finalized.data.status).toBe("verified");
      expect(finalized.data.sha256).toBe(sha256);
      expect(finalized.data.accountingState).toBe("counted");
      const tour = documentData(await db.get(tourPath))!;
      const node = (tour.nodes as Array<Record<string, unknown>>)[0];
      expect(node.privacy_status).toBe("awaiting-owner-review");
      expect((node.verified_derivative as Record<string, unknown>).revisionId).toBe(cleanupRevisionId);
      expect(documentData(await db.get(`${mediaPath}/derivatives/${cleanupRevisionId}`))?.status).toBe("verified");
      const quota = documentData(await db.get("system_config/storage_quota"));
      expect(quota?.usedBytes).toBe(100 + jpeg.length);
      expect(quota?.reservedBytes).toBe(0);
      const reviewPayload = { tourId, nodeId: 1, derivativeSha256: sha256, processingVersion: "localspot-panorama-local-v1", inspectedDirections: Array.from({ length: 48 }, (_, index) => index), acknowledgedMissRisk: true, acknowledgedManualInspection: true };
      const review = await api(owner.idToken, "/api/v1/tours/panorama/review", reviewPayload);
      expect(review.response.status).toBe(200);
      expect((review.data.review as Record<string, unknown>).recordType).toBe("owner-attestation-not-privacy-proof");
      expect((review.data.review as Record<string, unknown>).directionCount).toBe(48);
      const reviewRetry = await api(owner.idToken, "/api/v1/tours/panorama/review", reviewPayload);
      expect(reviewRetry.response.status).toBe(200);
      expect((reviewRetry.data.review as Record<string, unknown>).reviewedAt).toBe((review.data.review as Record<string, unknown>).reviewedAt);
      expect((await api(owner.idToken, "/api/v1/tours/panorama/review", { ...reviewPayload, inspectedDirections: Array.from({ length: 47 }, (_, index) => index) })).response.status).toBe(412);
      const privateAccess = await api(owner.idToken, "/api/v1/tours/panorama/private-access", { tourId, nodeId: 1, variant: "derivative" });
      expect(privateAccess.response.status).toBe(200);
      expect(privateAccess.data.contentType).toBe("image/jpeg");
      const privateCapability = await jwtVerify(String(privateAccess.data.token), await importJWK(publicJwk, "ES256"), { issuer: "localspot-functions", audience: "locentra-upload-gateway" });
      expect(privateCapability.payload.sub).toBe(owner.localId);
      expect(privateCapability.payload.objectKey).toBe(cleanupKey);
      const tourBeforePublish = documentData(await db.get(tourPath))!;
      const secondReservationId = crypto.randomUUID(), secondRevisionId = crypto.randomUUID().replace(/-/g, "");
      cleanupExtraReservationId = secondReservationId;
      const secondKey = `tours/derivatives/${owner.localId}/${tourId}/2/${secondRevisionId}_${sha256}.jpg`;
      const firstNode = (tourBeforePublish.nodes as Array<Record<string, unknown>>)[0];
      const secondDerivative = { ...(firstNode.verified_derivative as Record<string, unknown>), objectKey: secondKey, revisionId: secondRevisionId, reservationId: secondReservationId };
      const draftSecondNode = (tourBeforePublish.nodes as Array<Record<string, unknown>>).find((node) => Number(node.id) === 2)!;
      const secondNode = { ...draftSecondNode, verified_derivative: secondDerivative, owner_review: firstNode.owner_review, owner_reviewed: true, privacy_status: "awaiting-owner-review" };
      await db.set(tourPath, { ...tourBeforePublish, nodes: (tourBeforePublish.nodes as Array<Record<string, unknown>>).map((node) => Number(node.id) === 2 ? secondNode : node) });
      objects.set(secondKey, { bytes: jpeg, reservationId: secondReservationId, uid: owner.localId, mediaType: "panorama-derivative", sha256 });
      const secondLedger = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secondKey))), (byte) => byte.toString(16).padStart(2, "0")).join("");
      cleanupExtraLedgerId = secondLedger;
      await db.create("storageObjects", { objectKey: secondKey, sizeBytes: jpeg.length, uid: owner.localId, assetId, mediaType: "panorama", reservationId: secondReservationId, accountingState: "counted", countedInQuota: true }, secondLedger);
      await db.create("uploadReservations", { reservationId: secondReservationId, uid: owner.localId, assetId, mediaType: "panorama", objectKey: secondKey, reservedBytes: jpeg.length, actualBytes: jpeg.length, purpose: "processed", status: "completed", tourId, nodeId: 2, revisionId: secondRevisionId }, secondReservationId);
      await db.set("system_config/storage_quota", { storageProvider: "cloudflare_r2", limitBytes: 9_000_000_000, usedBytes: 100 + 2 * jpeg.length, reservedBytes: 0, remainingBytes: 9_000_000_000 - 100 - 2 * jpeg.length, usagePercent: ((100 + 2 * jpeg.length) / 9_000_000_000) * 100, uploadEnabled: true, maintenanceLock: false });
      const published = await api(owner.idToken, "/api/v1/tours/panorama/publish", { tourId });
      expect(published.response.status).toBe(200);
      expect(published.data.status).toBe("published");
      expect(objects.get(cleanupKey)?.publicApproved).toBe(true);
      expect(objects.get(secondKey)?.publicApproved).toBe(true);
      const publicAccess = await api(owner.idToken, "/api/v1/tours/panorama/published-access", { tourId, nodeId: 1 });
      expect(publicAccess.response.status).toBe(200);
      expect(publicAccess.data.url).toContain("/v1/media/panorama?key=");
      const publicCapability = await jwtVerify(String(publicAccess.data.token), await importJWK(publicJwk, "ES256"), { issuer: "localspot-functions", audience: "locentra-upload-gateway" });
      expect(publicCapability.payload.scope).toBe("media:public-read");
      expect(publicCapability.payload.derivativeSha256).toBe(sha256);
    } finally {
      globalThis.fetch = realFetch;
      delete env.R2_GATEWAY_PRIVATE_JWK;
      delete env.R2_GATEWAY_URL;
      const deletes: Array<{ delete: string }> = [
        { delete: `projects/demo-localspot/databases/(default)/documents/stores/${storePath.split("/")[1]}` },
        { delete: `projects/demo-localspot/databases/(default)/documents/tours/${tourPath.split("/")[1]}` },
        { delete: `projects/demo-localspot/databases/(default)/documents/${mediaPath}` },
        { delete: `projects/demo-localspot/databases/(default)/documents/mediaAssets/${owner.localId}_${secondAssetId}` },
        { delete: ratePath },
        { delete: quotaName },
      ];
      if (cleanupReservationId) deletes.push({ delete: `projects/demo-localspot/databases/(default)/documents/uploadReservations/${cleanupReservationId}` });
      if (cleanupRevisionId) deletes.push({ delete: `projects/demo-localspot/databases/(default)/documents/${mediaPath}/derivatives/${cleanupRevisionId}` });
      if (cleanupKey) {
        const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(cleanupKey)));
        const ledger = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
        deletes.push({ delete: `projects/demo-localspot/databases/(default)/documents/storageObjects/${ledger}` });
      }
      if (cleanupExtraReservationId) deletes.push({ delete: `projects/demo-localspot/databases/(default)/documents/uploadReservations/${cleanupExtraReservationId}` });
      if (cleanupExtraLedgerId) deletes.push({ delete: `projects/demo-localspot/databases/(default)/documents/storageObjects/${cleanupExtraLedgerId}` });
      await db.commit(deletes);
    }
  }, 30_000);
});
