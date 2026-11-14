const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
const authHost = "http://127.0.0.1:9099";
const storageHost = "http://127.0.0.1:9199";
const bucket = `${projectId}.appspot.com`;

async function request(url, options = {}) {
  const response = await fetch(url, options);
  return { response, body: await response.text() };
}

async function createUser() {
  const email = `storage-${randomUUID()}@example.test`;
  const { response, body } = await request(
    `${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email, password: "LocalSpot123!", returnSecureToken: true }),
    },
  );
  assert.equal(response.status, 200, `Auth emulator signup failed: ${body}`);
  return JSON.parse(body);
}

async function upload(path, token, contentType = "image/png") {
  const query = new URLSearchParams({ uploadType: "media", name: path });
  return request(`${storageHost}/v0/b/${bucket}/o?${query}`, {
    method: "POST",
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": contentType,
    },
    body: Buffer.from([137, 80, 78, 71]),
  });
}

async function objectRequest(path, token, method = "GET") {
  return request(`${storageHost}/v0/b/${bucket}/o/${encodeURIComponent(path)}?alt=media`, {
    method,
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

async function main() {
  const owner = await createUser();
  const other = await createUser();
  const suffix = randomUUID();
  const productOriginal = `products/quarantine/${owner.localId}/${suffix}.png`;
  const tourOriginal = `tours/originals/${owner.localId}/${suffix}.png`;
  try {
    assert.equal((await upload(productOriginal, owner.idToken)).response.status, 200, "Owner product quarantine upload");
    assert.equal((await objectRequest(productOriginal, owner.idToken)).response.status, 200, "Owner product quarantine read");
    assert.notEqual((await objectRequest(productOriginal, other.idToken)).response.status, 200, "Other user cannot read product quarantine");
    assert.notEqual((await objectRequest(productOriginal, null)).response.status, 200, "Guest cannot read product quarantine");

    assert.equal((await upload(tourOriginal, owner.idToken)).response.status, 200, "Owner tour original upload");
    assert.notEqual((await objectRequest(tourOriginal, other.idToken)).response.status, 200, "Other user cannot read tour originals");
    assert.notEqual((await upload(`products/public/${owner.localId}/${suffix}.png`, owner.idToken)).response.status, 200, "Client cannot publish product media");
    assert.notEqual((await upload(`stores/processed/${owner.localId}/${suffix}.png`, owner.idToken)).response.status, 200, "Client cannot write processed store media");
    assert.notEqual((await upload(`stores/public/${suffix}/photo.png`, owner.idToken)).response.status, 200, "Client cannot write public store media");
    assert.notEqual((await upload(`tours/public/${suffix}/view.png`, owner.idToken)).response.status, 200, "Client cannot write public tour media");
    assert.notEqual((await upload(`stores/quarantine/${owner.localId}/${suffix}.txt`, owner.idToken, "text/plain")).response.status, 200, "Non-image upload rejected");
    assert.notEqual((await upload(`products/quarantine/${owner.localId}/${suffix}-guest.png`, null)).response.status, 200, "Guest upload rejected");
    console.log("Storage Rules smoke checks passed (private uploads, owner isolation, content-type validation, and server-only publishing)");
  } finally {
    await Promise.all([
      objectRequest(productOriginal, owner.idToken, "DELETE"),
      objectRequest(tourOriginal, owner.idToken, "DELETE"),
    ]);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
