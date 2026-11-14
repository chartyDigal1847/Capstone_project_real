const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
const authHost = "http://127.0.0.1:9099";
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
const firestoreBase = `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents`;

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { response, body };
}

function field(value) {
  if (typeof value === "string") return { stringValue: value };
  if (typeof value === "number") return { integerValue: String(value) };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(field) } };
  return { nullValue: null };
}

async function main() {
  const suffix = randomUUID();
  const email = `rules-${suffix}@example.test`;
  const { response: authResponse, body: auth } = await jsonRequest(
    `${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email, password: "LocalSpot123!", returnSecureToken: true }),
    },
  );
  assert.equal(authResponse.status, 200, `Auth emulator signup failed: ${JSON.stringify(auth)}`);

  const token = auth.idToken;
  const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
  async function denied(path, fields, method = "POST", mask = "") {
    let url;
    if (method === "POST") {
      const [collection, documentId] = path.split("/");
      url = `${firestoreBase}/${collection}?documentId=${encodeURIComponent(documentId)}`;
    } else {
      url = `${firestoreBase}/${path}${mask ? `?${mask}` : ""}`;
    }
    const result = await jsonRequest(url, { method, headers, body: JSON.stringify({ fields }) });
    assert.equal(result.response.status, 403, `Expected rules to deny ${method} ${path}; got ${result.response.status}: ${JSON.stringify(result.body)}`);
  }

  await denied(`users/${auth.localId}`, {
    numericId: field(723456),
    name: field("Rules smoke user"),
    email: field(email),
    role: field("customer"),
    ownedStoreIds: field([]),
    memberStoreIds: field([]),
    storeGrants: field([]),
  });
  await denied(`users/${auth.localId}`, { role: field("admin") }, "PATCH", "updateMask.fieldPaths=role");
  await denied(`stores/store-${suffix}`, {});
  await denied(`products/product-${suffix}`, {});
  await denied(`listings/listing-${suffix}`, {});
  await denied(`storeMembers/member-${suffix}`, {});
  await denied(`stockMovements/movement-${suffix}`, {});
  await denied(`auditLogs/log-${suffix}`, {});
  console.log("Firestore Rules smoke checks passed (8 denied)");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
