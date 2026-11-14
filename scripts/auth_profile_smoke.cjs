const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
const authHost = "http://127.0.0.1:9099";
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
const firestoreBase = `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents`;

async function request(url, options = {}) {
  const response = await fetch(url, options);
  const body = await response.json().catch(() => null);
  return { response, body };
}

async function main() {
  const email = `profile-${randomUUID()}@example.test`;
  const signup = await request(`${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password: "LocalSpot123!", returnSecureToken: true }),
  });
  assert.equal(signup.response.status, 200, `Auth signup failed: ${JSON.stringify(signup.body)}`);

  let profile;
  for (let attempt = 0; attempt < 30; attempt++) {
    const result = await request(`${firestoreBase}/users/${signup.body.localId}`, {
      headers: { authorization: `Bearer ${signup.body.idToken}` },
    });
    if (result.response.status === 200) {
      profile = result.body;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  assert.ok(profile, "Auth trigger did not create the Firestore user profile within 7.5 seconds.");
  assert.equal(profile.fields.role.stringValue, "customer");
  assert.deepEqual(profile.fields.ownedStoreIds.arrayValue?.values ?? [], []);
  assert.deepEqual(profile.fields.memberStoreIds.arrayValue?.values ?? [], []);
  assert.deepEqual(profile.fields.storeGrants.arrayValue?.values ?? [], []);
  console.log("Auth profile trigger smoke check passed");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
