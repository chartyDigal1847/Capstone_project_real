import { importPKCS8, SignJWT } from "jose";
import type { Env } from "./index.js";

const DATASTORE_SCOPE = "https://www.googleapis.com/auth/datastore";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
let accessTokenCache: { token: string; expiresAt: number } | undefined;

export interface FirestoreDocument {
  name: string;
  fields?: Record<string, unknown>;
  createTime?: string;
  updateTime?: string;
}

export interface FirestoreWrite {
  update?: FirestoreDocument;
  delete?: string;
  updateMask?: { fieldPaths: string[] };
  currentDocument?: { exists?: boolean; updateTime?: string };
}

export interface FirestoreFilter {
  field: string;
  op: "EQUAL" | "NOT_EQUAL" | "LESS_THAN" | "LESS_THAN_OR_EQUAL" | "GREATER_THAN" | "GREATER_THAN_OR_EQUAL" | "IN";
  value: unknown;
}

export interface FirestoreOrder {
  field: string;
  direction: "ASCENDING" | "DESCENDING";
}

export interface FirestoreCountFilter { field: string; op: FirestoreFilter["op"]; value: unknown; }

export class FirestoreRestError extends Error {
  constructor(readonly code: string, message: string) { super(message); }
}

function encodeValue(value: unknown): Record<string, unknown> {
  if (value === null) return { nullValue: null };
  if (value instanceof Date) return { timestampValue: value.toISOString() };
  if (typeof value === "string") return { stringValue: value };
  if (typeof value === "boolean") return { booleanValue: value };
  if (typeof value === "number") return Number.isSafeInteger(value)
    ? { integerValue: String(value) }
    : { doubleValue: value };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(encodeValue) } };
  if (value && typeof value === "object") return { mapValue: { fields: encodeFields(value as Record<string, unknown>) } };
  throw new Error("Unsupported Firestore field value.");
}

function encodeFields(fields: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(fields).map(([key, value]) => [key, encodeValue(value)]));
}

function decodeValue(value: Record<string, unknown>): unknown {
  if ("nullValue" in value) return null;
  if ("stringValue" in value) return value.stringValue;
  if ("booleanValue" in value) return value.booleanValue;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("doubleValue" in value) return value.doubleValue;
  if ("timestampValue" in value) return new Date(String(value.timestampValue));
  if ("arrayValue" in value) {
    const values = (value.arrayValue as { values?: Array<Record<string, unknown>> }).values ?? [];
    return values.map(decodeValue);
  }
  if ("mapValue" in value) {
    const fields = (value.mapValue as { fields?: Record<string, Record<string, unknown>> }).fields ?? {};
    return decodeFields(fields);
  }
  if ("referenceValue" in value) return value.referenceValue;
  return undefined;
}

function decodeFields(fields: Record<string, Record<string, unknown>> = {}): Record<string, unknown> {
  return Object.fromEntries(Object.entries(fields).map(([key, value]) => [key, decodeValue(value)]));
}

export function documentData(document: FirestoreDocument | null): Record<string, unknown> | null {
  return document ? decodeFields(document.fields as Record<string, Record<string, unknown>> | undefined) : null;
}

export class FirestoreRest {
  private readonly root: string;
  get projectId(): string { return this.env.FIREBASE_PROJECT_ID; }

  constructor(private readonly env: Env) {
    const base = env.FIRESTORE_EMULATOR_URL
      ? env.FIRESTORE_EMULATOR_URL.replace(/\/$/, "")
      : "https://firestore.googleapis.com";
    this.root = `${base}/v1/projects/${encodeURIComponent(env.FIREBASE_PROJECT_ID)}/databases/(default)/documents`;
  }

  private async authorization(): Promise<string> {
    if (this.env.LOCAL_EMULATORS === "true") return "Bearer owner";
    if (accessTokenCache && accessTokenCache.expiresAt > Date.now() + 60_000) return `Bearer ${accessTokenCache.token}`;
    if (!this.env.FIREBASE_SERVICE_ACCOUNT_JSON) throw new Error("Firestore service account secret is not configured.");
    let serviceAccount: { project_id?: string; client_email?: string; private_key?: string; token_uri?: string };
    try { serviceAccount = JSON.parse(this.env.FIREBASE_SERVICE_ACCOUNT_JSON); }
    catch { throw new Error("Firestore service account secret is invalid."); }
    if (!serviceAccount.client_email || !serviceAccount.private_key) throw new Error("Firestore service account secret is incomplete.");
    if (serviceAccount.project_id !== this.env.FIREBASE_PROJECT_ID) {
      throw new Error("Firestore service account project does not match the configured Firebase project.");
    }
    if (serviceAccount.token_uri && serviceAccount.token_uri !== TOKEN_URL) {
      throw new Error("Firestore service account token endpoint is not allowed.");
    }
    const now = Math.floor(Date.now() / 1000);
    const key = await importPKCS8(serviceAccount.private_key, "RS256");
    const assertion = await new SignJWT({ scope: DATASTORE_SCOPE })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(serviceAccount.client_email)
      .setAudience(TOKEN_URL)
      .setIssuedAt(now)
      .setExpirationTime(now + 3600)
      .sign(key);
    const tokenResponse = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
    });
    if (!tokenResponse.ok) throw new Error("Firestore OAuth token exchange failed.");
    const tokenBody = await tokenResponse.json() as { access_token?: string; expires_in?: number };
    if (!tokenBody.access_token) throw new Error("Firestore OAuth response did not include an access token.");
    accessTokenCache = { token: tokenBody.access_token, expiresAt: Date.now() + Math.max(60, tokenBody.expires_in ?? 3600) * 1000 };
    return `Bearer ${tokenBody.access_token}`;
  }

  private async request(path: string, init: RequestInit = {}): Promise<Response> {
    return fetch(`${this.root}${path}`, {
      ...init,
      headers: { Authorization: await this.authorization(), "Content-Type": "application/json", ...init.headers },
      signal: AbortSignal.timeout(8_000),
    });
  }

  async throwResponse(response: Response, operation: string): Promise<never> {
    let detail = "";
    let code = String(response.status);
    try {
      const body = await response.json() as { error?: { status?: string; message?: string } };
      code = body.error?.status ?? code;
      detail = body.error?.message ?? "";
    } catch { /* ignore a non-JSON error body */ }
    throw new FirestoreRestError(code, `${operation} failed (${response.status})${detail ? `: ${detail.slice(0, 180)}` : ""}.`);
  }

  async get(documentPath: string, transaction?: string): Promise<FirestoreDocument | null> {
    const encodedPath = documentPath.split("/").map(encodeURIComponent).join("/");
    if (transaction) {
      const fullName = `projects/${this.env.FIREBASE_PROJECT_ID}/databases/(default)/documents/${documentPath}`;
      const response = await this.request(":batchGet", {
        method: "POST",
        body: JSON.stringify({ documents: [fullName], transaction }),
      });
      if (!response.ok) throw new Error(`Firestore transactional get failed (${response.status}).`);
      const results = await response.json() as Array<{ found?: FirestoreDocument; missing?: string }>;
      return results[0]?.found ?? null;
    }
    const response = await this.request(`/${encodedPath}`);
    if (response.status === 404) return null;
    if (!response.ok) throw new Error(`Firestore get failed (${response.status}).`);
    return await response.json() as FirestoreDocument;
  }

  async query(collectionId: string, filters: FirestoreFilter[], limit: number, transaction?: string, orders: FirestoreOrder[] = [], startAfter?: string): Promise<FirestoreDocument[]> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000) throw new Error("Firestore query limit is invalid.");
    const where = filters.length === 1
      ? { fieldFilter: { field: { fieldPath: filters[0].field }, op: filters[0].op, value: encodeValue(filters[0].value) } }
      : filters.length > 1
        ? { compositeFilter: { op: "AND", filters: filters.map((filter) => ({ fieldFilter: { field: { fieldPath: filter.field }, op: filter.op, value: encodeValue(filter.value) } })) } }
        : undefined;
    const response = await this.request(":runQuery", {
      method: "POST",
      body: JSON.stringify({
        ...(transaction ? { transaction } : {}),
        structuredQuery: {
          from: [{ collectionId }],
          ...(where ? { where } : {}),
          ...(orders.length ? { orderBy: orders.map((order) => ({ field: { fieldPath: order.field }, direction: order.direction })) } : {}),
          ...(startAfter ? { startAt: { values: [{ referenceValue: startAfter }], before: false } } : {}),
          limit,
        },
      }),
    });
    if (!response.ok) await this.throwResponse(response, "Firestore query");
    const results = await response.json() as Array<{ document?: FirestoreDocument }>;
    return results.flatMap((result) => result.document ? [result.document] : []);
  }

  async listAll(collectionId: string, pageSize = 400): Promise<FirestoreDocument[]> {
    const documents: FirestoreDocument[] = [];
    let cursor: string | undefined;
    while (true) {
      const response = await this.request(":runQuery", {
        method: "POST",
        body: JSON.stringify({ structuredQuery: {
          from: [{ collectionId }],
          orderBy: [{ field: { fieldPath: "__name__" }, direction: "ASCENDING" }],
          limit: pageSize,
          ...(cursor ? { startAt: { values: [{ referenceValue: cursor }], before: false } } : {}),
        } }),
      });
      if (!response.ok) await this.throwResponse(response, "Firestore paginated query");
      const rows = await response.json() as Array<{ document?: FirestoreDocument }>;
      const page = rows.flatMap((row) => row.document ? [row.document] : []);
      documents.push(...page);
      if (page.length < pageSize) return documents;
      const last = page.at(-1)?.name;
      if (!last || last === cursor) throw new Error("Firestore pagination cursor did not advance.");
      cursor = last;
    }
  }

  async listSubcollection(parentDocumentPath: string, collectionId: string, limit = 500): Promise<FirestoreDocument[]> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000) throw new Error("Firestore subcollection query limit is invalid.");
    const parent = parentDocumentPath.split("/").map(encodeURIComponent).join("/");
    const documents: FirestoreDocument[] = [];
    let cursor: string | undefined;
    while (true) {
      const response = await this.request(`/${parent}:runQuery`, {
        method: "POST",
        body: JSON.stringify({ structuredQuery: {
          from: [{ collectionId }],
          orderBy: [{ field: { fieldPath: "__name__" }, direction: "ASCENDING" }],
          limit,
          ...(cursor ? { startAt: { values: [{ referenceValue: cursor }], before: false } } : {}),
        } }),
      });
      if (!response.ok) await this.throwResponse(response, "Firestore subcollection query");
      const rows = await response.json() as Array<{ document?: FirestoreDocument }>;
      const page = rows.flatMap((row) => row.document ? [row.document] : []);
      documents.push(...page);
      if (page.length < limit) return documents;
      const last = page.at(-1)?.name;
      if (!last || last === cursor) throw new Error("Firestore subcollection cursor did not advance.");
      cursor = last;
    }
  }

  async count(collectionId: string, filters: FirestoreCountFilter[] = []): Promise<number> {
    const where = filters.length === 1
      ? { fieldFilter: { field: { fieldPath: filters[0].field }, op: filters[0].op, value: encodeValue(filters[0].value) } }
      : filters.length > 1
        ? { compositeFilter: {
            op: "AND",
            filters: filters.map((filter) => ({ fieldFilter: { field: { fieldPath: filter.field }, op: filter.op, value: encodeValue(filter.value) } })),
          } }
        : undefined;
    const response = await this.request(":runAggregationQuery", {
      method: "POST",
      body: JSON.stringify({ structuredAggregationQuery: {
        structuredQuery: { from: [{ collectionId }], ...(where ? { where } : {}) },
        aggregations: [{ count: {}, alias: "count" }],
      } }),
    });
    if (!response.ok) await this.throwResponse(response, "Firestore count");
    const rows = await response.json() as Array<{ result?: { aggregateFields?: Record<string, Record<string, unknown>> } }>;
    const value = rows[0]?.result?.aggregateFields?.count?.integerValue;
    const result = Number(value ?? 0);
    if (!Number.isSafeInteger(result) || result < 0) throw new Error("Firestore returned an invalid aggregate count.");
    return result;
  }

  async create(collectionId: string, fields: Record<string, unknown>, documentId?: string): Promise<FirestoreDocument> {
    const query = documentId ? `?${new URLSearchParams({ documentId })}` : "";
    const response = await this.request(`/${encodeURIComponent(collectionId)}${query}`, {
      method: "POST",
      body: JSON.stringify({ fields: encodeFields(fields) }),
    });
    if (!response.ok) await this.throwResponse(response, "Firestore create");
    return await response.json() as FirestoreDocument;
  }

  async beginTransaction(): Promise<string> {
    const response = await this.request(":beginTransaction", { method: "POST", body: JSON.stringify({ options: { readWrite: {} } }) });
    if (!response.ok) await this.throwResponse(response, "Firestore beginTransaction");
    const body = await response.json() as { transaction?: string };
    if (!body.transaction) throw new Error("Firestore did not return a transaction handle.");
    return body.transaction;
  }

  async commit(writes: FirestoreWrite[], transaction?: string): Promise<void> {
    const response = await this.request(":commit", { method: "POST", body: JSON.stringify({ writes, ...(transaction ? { transaction } : {}) }) });
    if (!response.ok) await this.throwResponse(response, "Firestore commit");
  }

  async set(documentPath: string, fields: Record<string, unknown>, transaction?: string): Promise<void> {
    const write: FirestoreWrite = {
      update: {
        name: `projects/${this.env.FIREBASE_PROJECT_ID}/databases/(default)/documents/${documentPath}`,
        fields: encodeFields(fields),
      },
    };
    await this.commit([write], transaction);
  }

  async rollback(transaction: string): Promise<void> {
    const response = await this.request(":rollback", { method: "POST", body: JSON.stringify({ transaction }) });
    if (!response.ok && response.status !== 404) throw new Error(`Firestore rollback failed (${response.status}).`);
  }

  async runTransaction<T>(callback: (transaction: FirestoreTransaction) => Promise<T>, attempts = 5): Promise<T> {
    for (let attempt = 0; attempt < attempts; attempt++) {
      const id = await this.beginTransaction();
      const transaction = new FirestoreTransaction(this, id);
      try {
        const value = await callback(transaction);
        await this.commit(transaction.writes, id);
        return value;
      } catch (error) {
        try { await this.rollback(id); } catch { /* transaction may already be closed */ }
        const retryableConflict = error instanceof FirestoreRestError &&
          (error.code === "ABORTED" || /transaction lock timeout|transaction contention/i.test(error.message));
        if (retryableConflict && attempt + 1 < attempts) {
          const backoffMs = Math.min(25 * 2 ** attempt, 400) + Math.floor(Math.random() * 25);
          await new Promise((resolve) => setTimeout(resolve, backoffMs));
          continue;
        }
        throw error;
      }
    }
    throw new FirestoreRestError("ABORTED", "Firestore transaction retry limit was reached.");
  }
}

export class FirestoreTransaction {
  readonly writes: FirestoreWrite[] = [];
  constructor(private readonly db: FirestoreRest, private readonly id: string) {}

  get(path: string): Promise<FirestoreDocument | null> { return this.db.get(path, this.id); }

  query(collection: string, filters: FirestoreFilter[], limit: number, orders: FirestoreOrder[] = [], startAfter?: string): Promise<FirestoreDocument[]> {
    return this.db.query(collection, filters, limit, this.id, orders, startAfter);
  }

  set(path: string, fields: Record<string, unknown>): void {
    this.writes.push({ update: { name: this.name(path), fields: encodeFields(fields) } });
  }

  create(path: string, fields: Record<string, unknown>): void {
    this.writes.push({ update: { name: this.name(path), fields: encodeFields(fields) }, currentDocument: { exists: false } });
  }

  patch(path: string, fields: Record<string, unknown>, deleteFieldPaths: string[] = []): void {
    this.writes.push({ update: { name: this.name(path), fields: encodeFields(fields) }, updateMask: { fieldPaths: [...Object.keys(fields), ...deleteFieldPaths] } });
  }

  delete(path: string): void { this.writes.push({ delete: this.name(path) }); }

  private name(path: string): string { return `projects/${this.db.projectId}/databases/(default)/documents/${path}`; }
}
