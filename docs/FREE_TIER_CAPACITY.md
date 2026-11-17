# Free-tier capacity and billing checks

Checked against the official vendor documentation on 2026-11-17. These limits can change; recheck them before production setup.

## Firebase Spark

Spark does not require payment information for no-cost Firebase products. Email, social, anonymous, and custom Authentication have a documented 3,000 daily active user no-cost limit. Standard Firestore has 1 GiB stored data, 50,000 document reads/day, 20,000 writes/day, 20,000 deletes/day, and 10 GiB/month outbound transfer. When a Spark quota is exceeded, that product is shut off for the rest of the calendar month, so exceeding quota is an availability failure rather than an overage bill. Sources: [Firebase pricing plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans), [Firestore quotas](https://firebase.google.com/docs/firestore/quotas), [Authentication limits](https://firebase.google.com/docs/auth/limits).

For the 50–100 user trial, these quotas are plausible but not guaranteed. Catalog loading reads directly from Firestore, and each screen refresh, search, realtime listener, and admin inventory scan consumes reads. Production readiness needs observed per-user and daily usage from a staging project.

## Cloudflare Workers Free

The current Free limits are 100,000 requests/day, 10 ms CPU per HTTP request, 10 ms CPU per Cron invocation, 128 MB memory, and 50 subrequests per request. Cron runs in UTC. Cloudflare also documents a 100 MB incoming request-body maximum for Free-plan domains. The app's panorama cap is 50 MiB, below that published domain limit, but Cloudflare's limit page does not explicitly state whether the same body cap applies to a `workers.dev` hostname; validate the largest signed upload against the actual isolated trial endpoint before release. Sources: [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [Cron Triggers](https://developers.cloudflare.com/workers/configuration/cron-triggers/).

The API Worker and gateways share the account’s Workers capacity. A user-supplied Cloudflare dashboard screenshot shows the 100,000 requests/day allowance, with 5 requests and 0 observability events used today. The isolated trial API Worker has no Cron configured. The full R2 reconciliation scans the bucket and Firestore ledgers; it is admin-triggered and has not been measured against realistic inventory, so it may exceed the 10 ms Free CPU limit. The checked-in local Wrangler config can exercise batched cleanup, but no cleanup Cron is enabled on the deployed trial Worker until its CPU and Free-plan behavior are validated.

Panorama uploads stream through the gateway into R2. Derivative uploads pass their signed SHA-256 to the R2 Worker binding's `put()` checksum option, allowing the backend to verify R2's stored checksum from object metadata without loading the full derivative into memory. Gateway unit tests verify checksum mismatch rejection. A separate Wrangler local R2 smoke test streamed 50 MiB and confirmed the stored SHA-256; local mocks and Wrangler's local runtime do not establish deployed Workers Free CPU or memory behavior.

## Cloudflare R2 Standard

Current included usage is 10 GB-month storage, 1 million Class A operations/month, 10 million Class B operations/month, and free egress. Standard storage only; deletes are free. Sources: [R2 pricing](https://developers.cloudflare.com/r2/pricing/), [usage-based billing](https://developers.cloudflare.com/billing/understand/usage-based-billing/).

The app’s 9,000,000,000-byte quota is below the 10 GB-month allowance only if this LocalSpot bucket is the dominant R2 usage in the account and its monthly average remains within that allowance. The R2 allowance is account usage, so other buckets and apps can consume it. Public media reads count as Class B operations; R2 egress itself is free.

R2 overages are usage-billed. Cloudflare’s published spending-limit control currently supports Workers and Durable Objects, not R2, and its spending limits do not guarantee a maximum invoice. Sources: [spending limits](https://developers.cloudflare.com/billing/manage/spend-management/), [billing policy](https://developers.cloudflare.com/billing/understand/billing-policy/). Therefore the 9 GB app-side quota does not by itself guarantee a zero Cloudflare bill. A user-supplied R2 dashboard screenshot showed 70 Class A operations, 36 Class B operations, 0 B storage, and $0 current billable usage for Nov 15–Dec 15. The new isolated trial bucket separately reports 0 objects and 0 B.

## Readiness gates

- Keep R2 Standard storage and the 9,000,000,000-byte reservation limit; monitor the entire Cloudflare account’s R2 storage and operation totals, including existing buckets.
- The isolated trial Workers and private R2 bucket are deployed; the existing Worker and bucket remain unchanged. Keep trial uploads disabled until an authorized administrator completes initial reconciliation and review. Continue monitoring account-level usage and billing behavior; these screenshots are point-in-time checks, not a spend cap.
- Measure Workers request and CPU usage for both Workers, especially the batched cleanup, admin reconciliation, and media flows, before relying on the Free plan.
- Measure Firestore daily reads/writes and stored bytes under staging usage, including direct Flutter catalog access.
- Keep Spark quota exhaustion and Cloudflare Free request/CPU exhaustion as explicit service availability risks for the trial.
