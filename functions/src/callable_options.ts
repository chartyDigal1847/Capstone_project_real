/** App Check remains enforced except for the isolated demo project used by CI emulator transport tests. */
export const enforceCallableAppCheck = !(
  process.env.FUNCTIONS_EMULATOR === "true" && process.env.GCLOUD_PROJECT === "demo-localspot"
);
