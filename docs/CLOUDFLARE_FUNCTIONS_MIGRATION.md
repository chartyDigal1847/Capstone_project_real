# Firebase Functions to Cloudflare Worker mapping

This is the implementation inventory for `functions/src`. Callable routes are available to Flutter when the build sets `LOCALSPOT_BACKEND_URL`; without it, Flutter keeps its Firebase Functions fallback. The existing Auth trigger is still present and should only be removed after the Worker path has been deployed and verified. No production Worker URL or credentials are configured by this migration.

Inventory audit: **35 callable HTTPS functions**, **1 Auth user-created trigger**, and **2 scheduled functions** are exported. No `onRequest` HTTP triggers or Firestore document triggers were found in `functions/src`; every callable and event export is represented below.

## Callable functions

| Firebase Function | Worker replacement | Notes |
| --- | --- | --- |
| `resolveReport` | `POST /api/v1/admin/reports/resolve` | Admin only |
| `submitUserFeedback` | `POST /api/v1/feedback` | App Check and Auth required |
| `submitUserReport` | `POST /api/v1/reports` | App Check and Auth required |
| `listActiveVendorLocations` | `GET /api/v1/vendor-locations/active` | Authenticated |
| `startVendorLocationSession` | `POST /api/v1/vendor-locations/sessions/start` | Owner or location-granted staff |
| `updateVendorLocationSession` | `POST /api/v1/vendor-locations/sessions/update` | Session starter only |
| `stopVendorLocationSession` | `POST /api/v1/vendor-locations/sessions/stop` | Session starter only |
| `createStorePromotion` | `POST /api/v1/promotions` | Store authorization enforced |
| `reviewStorePromotion` | `POST /api/v1/admin/promotions/review` | Admin only |
| `createStoreListing` | `POST /api/v1/listings` | Store authorization enforced |
| `updateStoreListing` | `POST /api/v1/listings/update` | Store authorization enforced |
| `archiveStoreListing` | `POST /api/v1/listings/archive` | Store authorization enforced |
| `listStoreListingMovements` | `POST /api/v1/listings/movements` | Store authorization enforced |
| `submitStoreApplication` | `POST /api/v1/stores/applications` | Owner profile required |
| `updateStore` | `POST /api/v1/stores/update` | Owner authorization enforced |
| `reviewStoreApplication` | `POST /api/v1/admin/stores/review` | Includes image publication and rejection cleanup |
| `approveStoreApplication` | `POST /api/v1/admin/stores/approve` | Admin only; forces approved status |
| `manageStoreMembership` | `POST /api/v1/stores/members/manage` | Owner or admin |
| `listStoreMemberships` | `POST /api/v1/stores/members` | Owner or admin |
| `manageStoreTour` | `POST /api/v1/tours/manage` | Create, connect, and add viewpoint actions |
| `reserveMediaUpload` | `POST /api/v1/media/reservations` | Quota-backed R2 upload capability |
| `finalizeMediaUpload` | `POST /api/v1/media/finalize` | Image validation, metadata stripping, ledger accounting |
| `reservePanoramaDerivativeUpload` | `POST /api/v1/media/panorama-derivative/reservations` | Quota-backed immutable derivative upload |
| `finalizePanoramaDerivativeUpload` | `POST /api/v1/media/panorama-derivative/finalize` | Hash and R2 metadata verification |
| `deleteMediaAsset` | `POST /api/v1/media/delete` | Ownership, unlink, and quota checks |
| `getPrivateMediaAccess` | `POST /api/v1/media/private-access` | Short-lived private capability |
| `cleanupAbandonedMediaReservations` | `POST /api/v1/admin/media/cleanup-reservations` | Admin only |
| `recordTourPanoramaReview` | `POST /api/v1/tours/panorama/review` | Owner review is an attestation, not proof of privacy safety |
| `getPublishedTourPanoramaAccess` | `POST /api/v1/tours/panorama/published-access` | Published tour capability |
| `getPanoramaPrivateMediaAccess` | `POST /api/v1/tours/panorama/private-access` | Owner-only private original/derivative access |
| `publishStoreTour` | `POST /api/v1/tours/panorama/publish` | Requires verified derivatives and owner review |
| `requestStorageReconciliation` | `POST /api/v1/admin/storage/reconcile` | Admin only; shares the reconciliation maintenance lock |
| `getStorageQuota` | `POST /api/v1/admin/storage/quota` | Admin only |
| `deleteStorageOrphan` | `POST /api/v1/admin/storage/orphans/delete` | Admin only; requires active orphan record |
| `deleteUserAccount` | `POST /api/v1/account/delete` | Recent auth; removes user data, panorama originals and every derivative revision through quota-aware R2 deletion, then Firebase Auth user |

## Event and scheduled functions

| Firebase trigger | Worker replacement | Current migration state |
| --- | --- | --- |
| `initializeUserProfile` (`onUserCreated`) | `POST /api/v1/auth/profile/bootstrap` | Idempotent endpoint; Flutter calls it after registration and login when Worker URL is configured. Login repairs a missing profile after an interrupted registration. Firebase trigger remains deployed. |
| `cleanupExpiredMediaAssets` (scheduled cleanup) | Cloudflare Cron `*/15 * * * *` UTC | Implemented in resumable batches: scans at most 5 candidate records and deletes at most 2 R2 objects per invocation. |
| `reconcileCloudflareR2Storage` (formerly every 15 minutes) | Admin route `/api/v1/admin/storage/reconcile` | Implemented on demand; automatic scheduling is disabled until realistic inventory scans are measured against Cloudflare Free Cron CPU limits. |

## Remaining work

- Panorama image generation remains on-device, as intended. The Worker verifies derivative ownership, bytes, hash, quota, and owner review, but does not prove the pixels are privacy-safe; online publication remains gated pending that validation.
- Flutter uses the Worker only when explicitly configured. Validate the full Android emulator workflow before removing the Firebase Functions fallbacks or Auth trigger.
- Configure production service-account and gateway credentials only after the no-billing IAM approach and production change approval are resolved. Do not deploy this local Wrangler configuration.
