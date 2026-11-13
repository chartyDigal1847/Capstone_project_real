# LocalSpot — App Development Plan

**Philippine Local Store & Product Locator**

*Firebase-only Flutter app · Version 2.0 · Updated 12 November 2026*

**Platform:** Flutter Android app · Firebase Authentication · Cloud Firestore · Cloud Storage · Firebase Cloud Functions<br>
**Development environment:** Flutter SDK + Firebase CLI + FlutterFire CLI + Firebase Local Emulator Suite<br>
**Trusted server-side runtime:** Firebase Cloud Functions 2nd gen (Node.js + TypeScript)<br>
**Working product name:** LocalSpot (renameable)  
**Revision focus:** Remove Laravel and PostgreSQL from the target architecture. Flutter uses Firebase client SDKs for rules-protected reads and limited safe writes. Firebase Cloud Functions is the trusted server-side layer for privileged operations, moderation, inventory invariants, automation and media processing. Firestore is the only primary application database; Cloud Storage holds media. The Firebase Emulator Suite is used for local development and tests. No self-managed Linux/VMware server or Docker backend is required.

---

## Contents

1. [Executive Summary](#1-executive-summary)
2. [Feature Scope and Priorities](#2-feature-scope-and-priorities)
3. [User Roles and Permissions](#3-user-roles-and-permissions)
4. [Screen Inventory and Navigation](#4-screen-inventory-and-navigation)
5. [Core Workflows](#5-core-workflows)
6. [AI Product Identification and Intelligent Search Design](#6-ai-product-identification-and-intelligent-search-design)
7. [2D Mapping and 360° Store Tours](#7-2d-mapping-and-360-store-tours)
8. [Technical Architecture](#8-technical-architecture)
9. [Firestore Data Model](#9-firestore-data-model)
10. [Firebase Client Access and Cloud Function Contracts](#10-firebase-client-access-and-cloud-function-contracts)
11. [Security, Privacy and Data Quality](#11-security-privacy-and-data-quality)
12. [Development Roadmap and Milestones](#12-development-roadmap-and-milestones)
13. [Enhanced Acceptance Checklist](#13-enhanced-acceptance-checklist)
14. [Pilot Launch Strategy](#14-pilot-launch-strategy)
15. [Firebase Development Environment](#15-firebase-development-environment)
16. [Production Readiness and Deployment](#16-production-readiness-and-deployment)
17. [Reference Documentation](#17-reference-documentation)
18. [Implementation Backlog — What to Build Next](#18-implementation-backlog--what-to-build-next)
19. [Firebase Project Setup and Migration Checklist](#19-firebase-project-setup-and-migration-checklist)

---

## 1. Executive Summary

LocalSpot is a location-based product discovery platform for the Philippines. It connects searches for products with participating physical stores and vendors near the customer. The app is for browsing, store discovery, advertising and navigation—not online ordering or delivery.

The target architecture is **Flutter + Firebase Authentication + Cloud Firestore + Cloud Storage + Firebase Cloud Functions**. Laravel, PostgreSQL, a self-managed backend server and a VMware Linux server are not part of the target system. Firebase provides managed identity, database, file storage and server-side functions. Cloud Functions is the trusted backend for sensitive operations; it is not a replacement name for a Laravel REST API and does not require the project owner to maintain an always-running server.

The core audience includes sari-sari stores, market stalls, mobile street vendors, hardware stores, electronics and technology shops, appliance retailers, clothing and footwear stores, bookstores, auto-parts sellers, general-merchandise shops, supermarkets and other physical retailers. LocalSpot supports any lawful product category with a monetary value that is offered by a participating physical seller—not just food. Sellers can publish products with photos, AI-assisted suggestions and manual confirmation. Customers can search by text or picture and find participating sellers around their current location.

### Product goals
- Help customers find participating stores listing a product near their current or manually selected search location.
- Automatically determine the customer’s current location after permission is granted, and update the on-screen location while the map or navigation experience is active.
- Keep the map, store markers, route preview and store-tour viewer inside LocalSpot.
- Let local vendors list items without a barcode, formal inventory system or large catalog.
- Use AI-assisted visual analysis, OCR and optional barcode/catalog lookup as suggestion tools; require owner confirmation or manual encoding.
- Support fixed business locations and optional, seller-controlled live public locations for mobile vendors.
- Show prices, units and reported availability with a last-confirmed timestamp.
- Provide an embedded, owner-created 360° store tour with people-privacy processing, manual blur correction and a publication gate that prevents raw/unprocessed panoramas from becoming public.

### Explicit non-goals
- No Laravel REST API, PHP backend, PostgreSQL database, Docker-hosted application server or self-managed VMware server in the target architecture.
- No shopping cart, checkout, online payment, delivery dispatch or rider tracking.
- No assumption that every physical seller or product is included; search participating and approved listings.
- No assumption that AI knows a seller's actual price or live stock without owner input.
- No background tracking of customers by default and no continuous public tracking of vendors without an explicit, active sharing session.
- No third-party Street View or street-imagery integration in this release. The owner-created 360° store tour is the only immersive-view feature in scope.

### Current project status (as reported in the previous plan)
The Flutter app already has a Firebase Authentication integration, a Firestore data layer called `LocalSpotFirebaseApi`, demo seed data and initial store/product/search/map/tour flows. The uploaded prior plan reports 39 Firebase data paths and 20 passing smoke tests. Those are project-reported implementation results and have not been independently re-run as part of this document update.

The current architecture change is **not complete merely because Flutter already talks to Firestore**. The existing rules and direct-write patterns must be reviewed. Sensitive operations currently performed directly from Flutter must be moved behind callable or event-driven Cloud Functions. Required remaining work includes production-grade Firestore and Storage Rules, Cloud Functions, App Check enforcement, Cloud Storage media workflows, geohash queries, testing, backups, billing controls and release hardening.

### Primary enhancement goal
A customer can search using a product name, known alias, broad category, supported attributes, natural-language query interpretation or product photo suggestion, then discover matching listings near their current or selected location. Owners can identify products with AI assistance, confirm or correct details, and publish store tours only after privacy processing and review. Every screen and interactive control must be connected to actual data and behavior; static pictures or nonfunctional buttons do not count as completed features.

### Architecture boundary
- Flutter + Firebase client SDKs perform authentication, permitted catalog reads, realtime listeners and limited safe user-owned operations protected by Security Rules.
- Firebase Cloud Functions 2nd gen (Node.js + TypeScript) performs privileged mutations, role changes, approval workflows, audit writes, scheduled cleanup and trusted media processing.
- Firestore is the single source of truth for application records.
- Cloud Storage stores image/video/panorama bytes; Firestore stores only paths and metadata.
- Firebase App Check is enabled for production app attestation on supported Firebase products. Authentication, App Check and Security Rules solve different problems and must be used together.
- Map tiles and routing may still use an external provider because Firebase is not a map-tile or road-routing service. Keep provider keys and privileged calls out of the Android app where required.

## 2. Feature Scope and Priorities
This table describes the current product direction for the enhancement release. Existing functionality should be regression-tested; new items are not considered complete until their acceptance criteria pass.

| **Feature** | **Current target** | **Implementation notes** |
|---|---|---|
| Accounts and roles | Firebase Authentication; customer, owner, staff and admin roles | Firestore Security Rules protect client access; Cloud Functions verifies caller identity and authoritative role/membership before privileged actions. Never trust client-supplied roles. |
| Store directory and products | Store all primary application records in Cloud Firestore | Seller records in Firestore remain the source of product-location results; do not limit the catalog to food or groceries. |
| Product text search | Retain and improve current search | Support curated aliases, common local names, known misspellings and category fallback; do not promise arbitrary typo-tolerant full-text search. |
| In-app 2D map | **Required** | Map rendered inside Flutter; show current location, store pins and selected-store details. Do not launch an external map by default. |
| Automatic current location | **Required** | Request foreground permission, get an initial fix, and subscribe to movement updates while map/navigation is active. |
| Nearby results refresh | **Required** | Refresh or re-rank when the user moves a meaningful distance; debounce requests to reduce battery and API usage. |
| In-app route preview | **Required** | Draw the route on the LocalSpot map, with distance and ETA if the selected route provider supports it. |
| In-app turn-by-turn navigation | Later enhancement | Add voice/instruction guidance only after route provider, rerouting, background behavior and licensing are validated. |
| Owner photo-assisted product entry | Retain | Photo suggestions, OCR, optional barcode lookup and manual owner confirmation. |
| Customer visual search | Retain / improve | A photo finds matching participating listings; it does not infer unreported stock. |
| Advertising | Retain | Approved sponsored store cards and offers; clearly label sponsored placements. |
| Fixed local business locations | **Required** | Store coordinates stay fixed unless an authorized owner edits them. |
| Mobile-vendor live location | Optional, seller-controlled | Share only during an explicit active session, display update time and expire stale sessions. |
| Owner 360° store tour | Retain and embed | Panorama viewer and connected viewpoints open inside LocalSpot; independent of third-party street imagery. |
| Third-party Street View | **Out of scope for this release** | Do not integrate Google Street View, Mapillary, KartaView or Panoramax in this version. |
| Functional UI and API integration | **Required** | Every interactive element performs a defined action and reflects real state/API results; no inert controls or production screens backed by hardcoded demo data. |
| Category and intent-assisted search | **Required** | Queries such as “food near me”, “tech” and “hardware” expand into known category families and supported filters. AI may interpret wording, but Firestore retrieval remains based on indexed fields. |
| Improved AI product identification | **Required enhancement** | Combine visual analysis, OCR, optional barcode lookup, catalog similarity and structured attribute suggestions; owner confirms before saving. |
| Automatic 360° privacy blur | **Required before publication** | Detect/blur people, including whole-person regions where feasible, plus faces and selected sensitive regions; support manual corrections and block publication on failure. |
| Online ordering | Out of scope | No cart, checkout or delivery functionality. |

### Success measures
- Relevant product searches returning one or more participating local sellers.
- Accuracy and freshness of product listings, store coordinates and availability.
- Percentage of map opens where the device position is obtained successfully after permission.
- Position update latency and map-follow stability during foreground use.
- Route-preview completion rate and destination pin accuracy.
- Number of mobile-vendor sessions that expire or are stopped correctly.
- Successful in-app 360° store-tour use and product-search coverage across supported product categories.

## 3. User Roles and Permissions
| **Role** | **Can do** | **Restrictions** |
|---|---|---|
| Customer | Browse/search; view stores/products; use the embedded map and tours; allow foreground location; view routes; save favorites; report inaccurate information | Cannot edit inventory or manage stores. Location sharing is optional and can be denied. |
| Store owner | Register a store; manage own listings, prices, availability, promotions and tours; manage authorized staff; update regular location; start/stop an optional mobile-vendor location session | Cannot modify another owner's store. Public live location is not enabled automatically. |
| Store staff | Perform explicitly granted inventory, listing and location tasks for assigned stores | Cannot change owner/admin privileges or start public location sharing unless the owner has granted that permission. |
| Administrator | Review stores, moderate content/promotions, handle reports, suspend accounts and inspect audit records | Administrative actions should be logged and restricted to authorized admins. |

Access control must be enforced by Firestore Security Rules for direct client operations and by explicit authorization checks inside Cloud Functions for privileged operations. Hiding a button in Flutter is not sufficient security. Cloud Functions using the Admin SDK bypass Firestore Security Rules, so every function must validate the caller, role, resource ownership and input itself.

### Store types and location modes
Support sari-sari stores, fruit and vegetable vendors, public-market stalls, street/mobile vendors, hardware stores, construction-supply shops, electronics/technology stores, appliance retailers, clothing and footwear stores, bookstores, auto/motorcycle-parts shops, general-merchandise stores, convenience stores, supermarkets and other physical sellers. Allow landmarks and barangay/city information where formal street addresses are incomplete. Product categories must cover lawful retail goods across these businesses, not food only.

- **Fixed location:** default for sari-sari stores, shops and market stalls. The owner can correct the registered pin.
- **Regular selling area:** suitable for vendors who work at a known area or on a schedule.
- **Live public location session:** an optional mode for mobile vendors. The owner explicitly starts sharing, sees that sharing is active, and can stop it. Updates stop and the public live location expires when the session ends or times out.
- **Customer location:** used on-device for map centering and passed to a location-aware Firestore query only when needed for nearby results or route calculation. Do not create a customer movement history by default.

## 4. Screen Inventory and Navigation
### Customer screens
| **Screen** | **Required content / action** |
|---|---|
| Home | Location-aware search, product text/camera search, categories, nearby products and sponsored placements. |
| Search results | Exact, alias, category, attribute and AI-assisted likely matches; distance; price/unit where supplied; availability freshness; filters/sorting; clear empty/error states and match labels. |
| Product detail | Product identity, photos, category, brand/model/variant and relevant attributes; nearby stores listing the product; exact/category/similarity match type where relevant. |
| Store detail | Store name/type, location, address/landmark, hours, catalog, promotions and 360° tour button. |
| Embedded 2D map | Current-position marker, follow/recenter control, store pins, selected-store card, radius and seller-type filters. |
| In-app route preview | Origin/destination, route polyline, distance, ETA if supported, route status and start-navigation action. |
| In-app navigation | Foreground position updates, route progress and rerouting if supported by the chosen provider. |
| 360° store tour | Embedded panorama viewer using sanitized images only; linked viewpoints, loading/failure states, return-to-store and optional product hotspots later. |
| Location and privacy settings | Permission status, follow-my-location toggle, manual search area, and controls/explanations for location usage. |
| Favorites and profile | Saved stores/products, account settings and reports. |

### Store-owner screens
| **Screen** | **Required content / action** |
|---|---|
| Owner dashboard | Store status, listing count, last-updated listings, quick add-product and promotion shortcuts. |
| Store registration | Business type, name, location pin, address/landmark, schedule and verification information. |
| Add product | Photo, optional barcode, candidate selection for multiple items, AI/OCR/catalog candidates, progress state, manual encoding, category-specific fields and owner confirmation. |
| Inventory | Search listings, edit price/unit, quantity/availability, archive and view stock movements. |
| Promotions | Create offer, time range, preview, moderation status and sponsored status. |
| 360° tour editor | Upload/capture panoramas; show privacy-processing status; inspect sanitized preview; add manual blur masks; connect viewpoints; publish only after processing/review passes. |
| Vendor location sharing | Show regular location, start/stop optional live-location session, show sharing status and expiry, manually correct the pin. |
| Staff and settings | Invite staff, assign limited permissions and manage profile. |

### Suggested bottom navigation
Customer: Home · Search · Map · Saved · Profile. Owner: Dashboard · Inventory · Scan Product · Promotions · Store/Profile. The map screen must remain in the Flutter app; opening an external mapping application is an optional fallback only.

### Functional interaction contract — no static-only screens
Every button, category chip, product/store card, map marker, filter, camera control, form, toggle and tour arrow must have a defined, tested behavior.
- Wire every control to a callback/state transition, navigation route, repository call or Firestore write. Remove controls that do nothing; if a future feature is not implemented, label it unavailable instead of making it appear functional.
- Use persisted Firestore data in normal app flows. Hardcoded or seeded demo records are allowed only in clearly identified development/test environments.
- Represent loading/progress, success, empty results, validation errors, permission denial, stale information, offline/network failure, server errors and retry/cancel behavior where relevant.
- Validate forms, display field-level errors, avoid duplicate submissions, preserve safe input after recoverable errors, and confirm destructive changes.
- Debounce text search, cancel stale requests, paginate large result sets, and preserve filters when returning to search results.
- Map controls must actually recenter/follow the user, toggle follow mode, filter stores, open selected-store details, request route previews and support manual area selection.
- The 360° viewer must support panorama drag/look, supported zoom gestures, connected viewpoint navigation, progress/loading indicators, privacy status and failed-image recovery.
- Owner edits to products, prices, availability, promotions and tours must persist through an authorized Firestore operation or Cloud Function and refresh affected screens after success.
- Test actual user journeys with Flutter widget/integration tests and Firestore rules/emulator tests. A clickable mockup is not a completed implementation.

Use a feature-based Flutter architecture with one consistent state-management approach (for example, Riverpod or Bloc), repositories for data access, typed request/response models and separated UI/controller logic.

## 5. Core Workflows

### A. Account registration and authentication
1. Customer or owner creates an account or signs in through Firebase Authentication using the Flutter Firebase Auth SDK.
2. Firebase Auth maintains the authenticated session and refreshes ID tokens automatically. Flutter does not send tokens to Laravel because there is no Laravel API in this architecture.
3. An Auth `onCreate` Cloud Function may create a minimal `users/{uid}` profile with the least-privileged default role (`customer`). The client may update only explicitly allowlisted profile fields through Firestore Rules.
4. A user who wants to become a store owner submits a store application. Submitting an application does not grant owner or admin privileges.
5. An authorized admin reviews the application through a protected admin workflow. A callable Cloud Function validates the admin claim, updates approval status, creates the store-owner membership and writes an audit record atomically where practical.
6. Logout uses Firebase Auth `signOut`. Account deletion uses a callable Cloud Function to verify the caller, require recent authentication where appropriate, clean up owned data according to retention policy and delete/disable the Auth account using the Admin SDK.

### B. Owner registration and store publishing
1. User signs in and submits a store application from Flutter.
2. Enter store details and select a business category.
3. Use device location as a suggestion if permission is granted, or pin the location manually.
4. Enter barangay/city, street address where available, landmark and operating schedule.
5. Flutter invokes `submitStoreApplication`; the function validates fields, limits duplicate/spam submissions and saves a pending application.
6. An authorized admin invokes `approveStoreApplication`. The function checks admin authorization, creates/updates the store and owner membership, and writes an audit event.
7. Only an approved store can publish customer-visible listings and tours.

### C. AI-assisted product entry
1. Open Add Product and take a clear photo, choose an existing image, or use the optional barcode scanner.
2. If multiple objects are visible, detect/crop candidate items or ask the owner to select the product to identify.
3. Use Firebase AI Logic with a supported multimodal Gemini model for initial visual suggestions, or a trusted Cloud Function-backed Google AI service when secret credentials, stronger server-side controls or additional detection APIs are needed. OCR/barcode/catalog lookups may be separate steps.
4. Treat all generated text, labels, attributes and confidence values as untrusted suggestions. Validate structured output against an explicit schema.
5. Show the suggested name, category, brand/model where supported by evidence, likely attributes, confidence/match strength and unknown fields.
6. Let the owner choose a match, correct suggestions or manually create a product. Do not invent a brand, model, dimensions, compatibility or price when evidence is missing.
7. Owner confirms the store-specific price, selling unit, stock/availability and listing photo.
8. Flutter invokes a callable function such as `createStoreListing` or `updateStoreListing`. The function checks the authenticated owner/staff membership and grants, validates price/units/category, writes the listing and audit record, and returns a structured result.

**Important data rule:** AI suggestions are not confirmed inventory. The owner confirms product identity and store-specific values. Low-confidence or unknown matches must always have a usable manual-entry path.

### D. Customer search, discovery and navigation
1. Customer types a specific item (“Makita drill”), a broad category (“food”, “tech”, “hardware”), a need (“USB-C charger for Samsung phone”), or uses photo search.
2. The initial Firebase-only search uses normalized exact/prefix fields, aliases, category hierarchy, known synonyms, product attributes and Firestore composite indexes. Nearby results use geohash range queries followed by exact-distance filtering.
3. Firebase AI Logic may optionally classify a natural-language query into structured search intent, category IDs and attribute filters. AI query interpretation is not a guarantee of full-catalog semantic retrieval; the app must display uncertain matches honestly.
4. Request foreground location permission when nearby search or the map needs it. If permission is denied, use a selected map point or manually entered area.
5. Filter listings by selected radius and store status; rank by exact match, category/attribute match, distance and listing freshness, with optional price sorting where values are comparable.
6. Broad category queries expand the category tree: “food” includes grocery, produce, drinks and other food subcategories; “tech” includes electronics, computers, phones, peripherals and accessories; “hardware” includes tools, fasteners, plumbing/electrical supplies and building materials.
7. Show real product/store cards and map pins with category, store type, distance, supplied price/unit and last availability confirmation. Empty results provide practical alternatives such as increasing radius, clearing filters or viewing the parent category.
8. Tapping a card opens real details. Tapping Navigate opens a route preview inside LocalSpot; it does not launch another map app by default.
9. Opening a published store tour launches the interactive viewer using privacy-processed images. Third-party Street View remains out of scope.

### E. Store-tour publishing
1. Owner creates a draft tour for an approved store.
2. Capture or upload compatible 360° panoramas to a private Storage quarantine path using Firebase Storage SDK.
3. A Storage-triggered Cloud Function validates the upload and starts an idempotent processing workflow. Keep the original private and set tour/media status to `processing`.
4. Processing creates sanitized derivatives, previews and viewer tiles only after image privacy checks. The function records processing status, model/version and any review flags in Firestore.
5. Owner inspects the sanitized preview, adds manual blur masks where needed and confirms the final derivative.
6. `publishStoreTour` verifies every required node has an approved sanitized derivative, then publishes the tour. Customers can only read published tour metadata and sanitized assets.

### F. Customer real-time location behavior
1. Check whether device location services are enabled and request permission with a clear explanation.
2. Get an initial position and show the user-location marker on the embedded map.
3. Subscribe to location updates only while the map-follow or navigation feature is active in the foreground.
4. Keep the map centered only while the user has enabled Follow My Location; allow normal map panning without repeatedly snapping back.
5. Refresh nearby results only after a configured movement/time threshold or deliberate user action, with debounce/throttling to reduce battery and Firestore reads.
6. Stop location subscriptions when the relevant screen/mode ends. If permission is denied, show a manual-location option without blocking the app.

### G. Optional live location for mobile vendors
1. An authorized owner/staff member explicitly starts a public location session by calling `startVendorLocationSession`.
2. The function verifies the caller's store membership and `location` grant, creates a session with a maximum expiry and writes an audit event.
3. The app displays a clear active-sharing indicator and the time the position was last updated.
4. During the session, Flutter sends location updates at a reasonable interval or movement threshold through `updateVendorLocationSession`; the function rechecks membership, session status, coordinates and rate limits.
5. Owner can stop sharing through `stopVendorLocationSession`. A scheduled Cloud Function also expires stale sessions automatically.
6. Customer map displays the reported position only while the session is active and fresh; otherwise show the regular selling area or last known location clearly labelled as stale.

### H. 360° store-tour privacy processing and publication gate
1. Owner uploads the original panorama to a private, non-public path such as `quarantine/{uid}/tours/{tourId}/{assetId}/original`.
2. A Cloud Storage finalize trigger validates file type, size, dimensions and owner/store association. It writes an idempotent job/status record in Firestore. Never trust a client-provided `processingStatus`.
3. A Cloud Function task validates orientation/metadata and prepares overlapping perspective crops or cubemap faces for detection where the selected processing library supports it.
4. Run person detection/segmentation to identify full visible people where supported, plus face detection as an additional pass. Optionally detect license plates, documents, screens and other configured sensitive regions. Do not rely on a general-purpose text model as the sole privacy detector.
5. Project masks back onto the source panorama, add a safety margin, apply strong blur/pixelation, recheck seams/poles and strip unnecessary EXIF/GPS metadata from public derivatives.
6. Generate public previews, thumbnails and viewer tiles only from the sanitized derivative. Never make the unblurred original publicly readable.
7. Save processing status, model/version, timestamp, flags and errors. If processing fails or uncertainty is high, keep the tour unpublished and route it to manual review.
8. Let the owner inspect the sanitized preview and add manual blur regions for missed people, faces, license plates, paperwork, screens or private areas. The published version must not have a control that restores an unblurred area.
9. `publishStoreTour` checks the status of every asset and publishes only after required processing and owner review succeed. Keep originals privately restricted or delete them after a documented retention period; any replaced image must pass through the full pipeline again.

**Processing constraint:** Cloud Functions 2nd gen has execution, memory and payload limits. Set upload limits, process panoramas in bounded tasks, make work retryable and test worst-case image sizes. If required image processing cannot reliably fit within managed function limits, document that the privacy pipeline needs a dedicated processing service; do not silently publish unprocessed images or claim Firebase Functions can handle unlimited media.

**Privacy caveat:** Automated detection is imperfect. Whole-person segmentation plus face detection is more protective than face-only blur, but still needs testing for crowded shops, people behind shelves/glass, mirrors, motion blur, distant people and panorama seams. Manual review is required before publication; never promise that AI processing guarantees anonymity.

## 6. AI Product Identification and Intelligent Search Design

LocalSpot supports **any lawful product category sold by participating physical stores**, not just food or packaged groceries. The Firebase-only MVP must provide useful exact, alias, category, attribute and nearby search without pretending that Firestore is a full-text or vector search engine.

### A. Owner-side photo identification pipeline

1. **Capture and validate:** take a clear photo or select an image; validate file type, size and image quality before sending it to an AI model.
2. **Object selection:** if several items are visible, ask the owner to select/crop the target item or present multiple candidate regions.
3. **Visual suggestions:** use Firebase AI Logic with a supported multimodal Gemini model to suggest a likely product name, broad category and visible attributes. Use a trusted Cloud Function-backed Google AI service only when server-side credentials, additional processing or stricter server-side control is required.
4. **OCR/barcode:** read visible model/part numbers or labels where supported. Barcode lookup is optional and must never be required.
5. **Catalog matching:** normalize the AI/OCR/barcode suggestions and compare them against Firestore product names, aliases, identifiers, category terms and attributes.
6. **Candidate ranking:** rank exact model/part-number and barcode matches ahead of generic visual/category guesses. Show uncertainty and unknown fields.
7. **Owner confirmation:** owner chooses/corrects the product, manually enters missing details and confirms the store-specific price, selling unit and availability.
8. **Trusted save:** Flutter invokes `createStoreListing`/`updateStoreListing`; the Cloud Function validates the owner/staff grant and saves the confirmed data.

AI suggestions are untrusted input. Never let the model write directly to Firestore, assign roles, approve stores, set prices/stock, or claim product compatibility/safety without owner confirmation or a trusted catalog source. Manual product creation must always remain available.

### B. Customer image search

Customer photo search is different from owner registration. Firebase AI Logic can suggest likely product/category terms from the image. Flutter then queries Firestore using the returned canonical name, known aliases, category IDs and supported attributes, optionally constrained by the user's selected location. If the photo contains multiple products, ask which item to search for. Label results as likely/category-based when identity is uncertain. The Firebase-only MVP does not perform vector nearest-neighbour search over all catalog images.

### C. Firebase-only text and category search

Use these retrieval signals:
- **Exact identifiers:** product name, brand, model, SKU/part number and barcode.
- **Normalized prefix search:** searchable lowercase/normalized name fields and bounded prefix-token fields prepared when products/listings are written.
- **Aliases and local terms:** curated alternate spellings, plurals and Filipino/English/local names stored in Firestore.
- **Hierarchical categories:** category IDs, parent IDs and ancestor IDs so broad searches include descendants.
- **Typed attributes:** category-specific values such as size, material, voltage, capacity, model and compatibility where confirmed.
- **Geospatial filtering:** geohash range queries followed by exact-distance calculation using latitude/longitude.
- **Ranking:** exact identifier/name first, then alias/prefix/category/attribute matches, then distance and listing freshness. Sponsored results must be clearly labelled and must not masquerade as organic relevance.

Firestore structured queries must be bounded, paginated and supported by committed composite indexes. Use Firebase AI Logic optionally to convert a natural-language request into a small structured search intent (category, attributes and compatibility phrase). Validate the AI output and map it only to known category IDs and allowed filters; never allow AI to generate arbitrary database queries.

**Important search limitation:** Cloud Firestore does not provide native general-purpose full-text search or vector similarity. The Firebase-only MVP can support practical prefix/alias/category/attribute search, but it cannot promise exhaustive typo tolerance, semantic retrieval or image-embedding similarity. If those become essential, a dedicated external search provider is an explicit future architecture exception requiring a separate security, privacy and cost decision. Firestore remains the source of truth.

### D. Required query behavior

| Query | Expected behavior in the Firebase-only MVP |
|---|---|
| `food near me` | Expand into food, grocery, drinks, fresh produce and other food subcategories; query matching listings within the selected radius. |
| `tech` | Expand to electronics, computers, phones, peripherals and technology accessories; show subcategory filters. |
| `hardware` | Expand to hand/power tools, fasteners, plumbing/electrical supplies and building materials. |
| Exact model or part number | Rank exact identifier matches ahead of broad category or AI suggestions. |
| Misspelled/local product name | Use known aliases and curated normalization; show a “did you mean” suggestion when there is no known alias. Do not promise arbitrary typo matching. |
| `USB-C charger for Samsung phone` | Use query interpretation to suggest category/attribute filters, but show compatibility only when confirmed listing/catalog data supports it. |
| Photo of a drill | Suggest tool category/name, inspect visible brand/model text where possible, then search Firestore names/aliases/categories and nearby listings. |
| Photo of fruit or vegetables | Suggest produce/category matches and let owners define variety and selling unit. |

### E. Category taxonomy and flexible attributes

Use a hierarchical taxonomy, not a food-only flat list. Initial top-level families include:
- Food, grocery, drinks and produce;
- Hardware, tools, building, plumbing and electrical supplies;
- Electronics, computers, mobile devices and accessories;
- Appliances, furniture, home improvement and household goods;
- Clothing, footwear, bags and accessories;
- Books, education, office and art supplies;
- Automotive, motorcycle and bicycle parts/accessories;
- Sports, outdoor, hobby, garden, agricultural and pet supplies;
- Personal care, toys, gifts, handmade and second-hand products where permitted.

Categories can define optional typed attributes with units, validation and searchability. Examples include apparel size/colour/material; electronics model/storage/capacity/compatibility; hardware dimensions/material/voltage; auto parts make/model/year; and produce variety/unit. Not every category field is mandatory. Owners confirm product claims and store-specific values.

### F. Search screen behavior

- The search field supports text, camera search, clear, suggestions and retry.
- Category cards/chips execute actual category queries; they are not decorative elements.
- Debounce text input, cancel stale requests, paginate results and preserve filters when returning from details.
- Display real results with product/store image, category, location, price/unit if supplied, distance, last confirmation and a map action.
- Support filters for category/subcategory, radius, seller type, price range, freshness/availability and relevant attributes.
- Default sort is relevance plus distance; offer price or freshness sorting where comparable data exists.
- A broad query must traverse category descendants; it must not rely on literal text alone.
- Empty results offer actions to widen radius, clear filters, select a parent category or try a suggested search.
- Label exact, alias, category-based and AI-assisted matches clearly where that distinction affects user expectations.

### G. Location-aware results and source of truth

Use `geolocator` or an equivalent maintained Flutter plugin for the initial position and foreground movement updates. Request permission when needed; allow manual area selection if denied. Keep customer coordinates transient for nearby queries by default and do not store a location-history trail.

Filter by distance, refresh only after a configured distance/time threshold or user action, and avoid running a Firestore query for every GPS update. LocalSpot's participating store listings are the source of product availability: recognition/search can suggest what an item is, but cannot independently know current physical stock.

### H. Evaluation and improvement loop

Build a manually reviewed test set across product categories, price-unit formats, local naming and low-quality images. Measure exact-match accuracy, category precision/recall, prefix/alias search relevance, AI suggestion quality, latency, read counts, cost and failure rate. Review user/owner corrections before adding aliases or reference data. Do not silently use uploaded photos to train models without a documented lawful basis and privacy notice.

## 7. 2D Mapping and 360° Store Tours
### Product requirement: embedded map and store tour
LocalSpot's standard 2D map, current-location marker, store pins, route preview and owner-created 360° store tour must remain inside the Flutter app. Do not launch Google Maps or another external mapping app as the default action. An external navigation app may be offered as an optional fallback only. **Third-party Street View and street-level imagery are out of scope for this release.**

| **Experience** | **Recommended implementation** | **Key constraint** |
|---|---|---|
| In-app 2D map | MapLibre Flutter with a production-grade tile/style provider whose terms permit LocalSpot's product directory and advertising use | MapLibre is the renderer, not the map-data host. Select a suitable provider or self-host tiles; meet attribution and usage rules. |
| Store and product pins | Render LocalSpot's verified store records as app-owned markers/layers | Store/product records come from LocalSpot's own database, not a third-party POI directory. |
| Current location | Flutter `geolocator` (or an equivalent maintained plugin) for initial position and foreground updates | Request permission transparently; handle approximate, denied and disabled location cases. |
| In-app route preview | A routing service compatible with the selected base map; draw route geometry on the embedded map | Check commercial use, quotas, ETA support, coverage, licensing and price. Keep provider credentials server-side when applicable. |
| Turn-by-turn navigation | Later enhancement using a provider/SDK that permits an in-app navigation experience | Route preview and a live marker are not a full navigation engine. Test rerouting, voice instructions, battery use and background behavior separately. |
| Owner 360° store tour | App-owned panorama storage and embedded 360° viewer with linked tour nodes | This is the immersive experience in scope and does not rely on third-party Street View coverage. |
| Tour capture guidance | Manual viewpoint placement initially; optional guided spacing later | GPS alone is not reliable enough for precise indoor distance measurement. |

### Product catalogue scope
LocalSpot is a **general physical-product locator**, not a food-only app. Any lawful product sold by a participating physical store may be listed, provided the listing has enough information to identify the item and the owner supplies or confirms the store-specific price and availability.

Product categories can include:
- Food, groceries, drinks, fresh produce and market goods;
- Hardware, hand tools, power tools, plumbing/electrical supplies and construction materials;
- Electronics, computers, phones, chargers, accessories and other technology products;
- Appliances, furniture, home improvement, household goods and décor;
- Clothing, footwear, bags, jewellery and other accessories;
- Books, school supplies, office supplies, art and craft materials;
- Automotive and motorcycle parts, bicycle parts, lubricants and accessories;
- Sports, outdoor, hobby, garden, agriculture and pet supplies;
- Personal-care products, toys, gifts, handmade products and second-hand goods where permitted by platform policy.

The product catalog must support categories and category-specific attributes without requiring every item to have a barcode. Use generic shared fields (name, category, brand, model/variant, identifiers and images) plus optional category-specific attributes (such as material, dimensions, voltage, capacity, size, compatibility or condition). The owner must confirm AI suggestions and all store-specific values.

### Automatic people-privacy blurring for 360° tours

**Release gate:** a panorama must not become publicly visible until automated privacy processing succeeds and the sanitized image has passed owner review.

Recommended pipeline:
1. Keep the original upload in private staging; never make the raw file or its thumbnails publicly accessible.
2. Dispatch a retryable Cloud Functions task and expose real progress states to the owner: uploading, processing, needs review, ready to publish or failed/retry.
3. Convert the equirectangular image into overlapping perspective crops/cubemap faces for detection, then project the masks back onto the panorama to reduce misses caused by distortion, seams and poles.
4. Use person detection/segmentation to blur whole visible people where feasible, and face detection as an additional pass. Optionally detect license plates, paperwork, screens and other configured sensitive regions.
5. Pad masks, apply strong blur/pixelation, recheck panorama seams, strip EXIF GPS metadata, and create every public preview/thumbnail/viewer tile only from the sanitized derivative.
6. If the model fails or confidence is low, keep the image unpublished and require manual review. The owner can add blur masks for missed people or sensitive details.
7. Publish only the sanitized derivative. Restrict access to the original and apply a documented retention/deletion policy. Replaced images must be processed again. Do not provide an “unblur” control for the public copy.

Automatic detection can miss people behind shelves/glass, small or distant people, reflections, poorly lit scenes and unusual angles. Whole-person masking is more protective than face-only blur because clothing, tattoos and context can still identify someone. Review is required; blur reduces privacy risk but does not guarantee anonymity.

### Required customer experience
- Standard 2D map is the default and remains usable without any immersive imagery.
- Current location is detected automatically after permission; the user may enable or disable Follow My Location.
- Nearby product results can refresh as the user moves, without making repeated requests for every small GPS change.
- A selected store's route is previewed on the LocalSpot map. External navigation remains an optional fallback.
- The store's own 360° tour opens inside LocalSpot and remains available independently of third-party map imagery.
- If a store has no tour, show its available photos and store information instead of an unavailable Street View screen.
- Comply with the selected map-tile/routing provider's usage limits, privacy rules and content licence. Do not promise Street View functionality in this release.

### Implementation order
1. Finish the embedded 2D map with LocalSpot store pins using the selected tile provider.
2. Add automatic current-position detection, permission/error states and Follow My Location.
3. Add backend-driven product/store pins, all-category search filters and movement-throttled search refresh.
4. Add the in-app route preview and draw its route geometry on the 2D map.
5. Embed and test the owner-created 360° store-tour viewer.
6. Expand product catalog taxonomy and category-specific attributes for non-food merchandise.
7. Validate the enhanced app on supported Android devices and confirm that no map or tour action unintentionally launches an external application.

## 8. Technical Architecture

### Target architecture: Flutter + Firebase (no Laravel)

| **Layer** | **Recommended technology** | **Responsibilities** |
|---|---|---|
| Mobile client | Flutter + Dart | Customer/owner/admin UI, camera, map, GPS, 360° tours and Firebase client SDK integration. |
| Identity provider | Firebase Authentication | Account creation/sign-in, credential management, password reset and Firebase UID. |
| Client data access | Firebase Flutter SDKs | Direct, rules-protected Firestore reads/listeners and only explicitly permitted low-risk writes. |
| Primary application database | Cloud Firestore Standard edition | Users, stores, categories, products, store listings, promotions, tour metadata, recognition jobs, location sessions and audit records. |
| Media/object storage | Cloud Storage for Firebase | Product photos, store images, private original panoramas, sanitized panorama derivatives and generated previews. Firestore stores metadata and object paths, not image bytes. |
| Trusted backend | Firebase Cloud Functions 2nd gen, Node.js 22 + TypeScript | Privileged mutations, authorization, approvals, membership changes, inventory invariants, audit events, scheduled cleanup, notifications and media workflow orchestration. |
| Client/app protection | Firebase App Check (Play Integrity for Android production) | Attest supported app requests and reduce unauthorized-client abuse. Use debug provider only in local/debug builds. |
| AI | Firebase AI Logic (Gemini models) and, where required, Google Cloud AI services invoked by Functions | Product-photo suggestions, query intent parsing and optional image analysis. AI results remain untrusted suggestions. |
| Search | Firestore indexed query fields for MVP | Exact/prefix/alias/category/attribute/geohash search. Native full-text and vector similarity are not provided by Firestore; advanced search is deferred or an explicit external-service exception. |
| Map rendering and data | MapLibre Flutter + a commercially suitable tile/style provider | In-app 2D map, store pins and route rendering. MapLibre is the renderer, not a map-data host. |
| Location services | Flutter `geolocator` or equivalent maintained plugin | Initial location and foreground position stream; permission handling and map-follow state. |
| Routing services | Compatible hosted or self-managed routing provider | In-app route geometry and ETA where supported. Routing is a separate provider integration, not a Firebase feature. |
| Notifications | Firebase Cloud Messaging | Push notifications; privileged notification sends are initiated by Cloud Functions. |
| Monitoring | Crashlytics, Analytics, Cloud Logging/Monitoring | App crash reporting, product analytics, function logs, error rates and billing/usage monitoring. |
| CI and release checks | Git-based CI pipeline + Firebase CLI | Flutter tests, Functions TypeScript tests, Emulator Suite rules tests, security checks and staged Firebase deployment. |

### Request and trust boundaries

1. Flutter signs the user in through Firebase Authentication. Firebase Auth supplies the authenticated identity to Firebase SDK requests; the app does not send a token to a Laravel API.
2. Flutter reads public approved catalog records directly from Firestore. Firestore Security Rules restrict which documents and fields can be read.
3. Flutter may write only low-risk user-owned data explicitly allowed by Security Rules, such as selected profile fields and favorites. Rules validate UID ownership and permitted fields.
4. Sensitive mutations call an authenticated callable Cloud Function (for example, store approval, membership changes, inventory changes, promotion publication, live vendor sessions, tour publication or account deletion).
5. Each callable function validates `request.auth`, verifies required App Check context, validates all input, reads authoritative role/membership documents, checks resource ownership and grants, applies rate limits/idempotency where needed, writes through the Admin SDK and records an audit event.
6. Cloud Functions using the Firebase Admin SDK bypass Firestore Security Rules. Function code must therefore implement authorization explicitly; never assume rules protect Admin SDK writes.
7. Flutter uploads media only to a UID-scoped private Storage quarantine path under Storage Rules. A Storage-triggered Cloud Function verifies ownership and metadata before processing. The function writes sanitized derivatives; clients cannot write to processed/published paths.
8. Customers can read only approved published media. Raw originals and pending assets remain private.
9. Firestore remains the source of truth. Any future external search index is derived, optional and rebuildable.

### Cloud Functions design

- Use **2nd-generation Cloud Functions** with TypeScript and a currently supported Node.js runtime (Node.js 22 is the preferred baseline for this plan; recheck Firebase runtime support before upgrades/deployment).
- Prefer callable functions (`onCall`) for app-invoked privileged operations because the Firebase client SDK carries Auth and App Check context. Use Firestore/Storage event triggers for background workflows and scheduled functions for expiry/cleanup.
- Put functions in an explicitly configured region. `asia-southeast1` (Singapore) is available for Cloud Functions; align callable functions and event-driven functions with the Firestore/Storage region where supported to reduce latency and cross-region charges. Verify current regional availability and pricing at deployment time.
- Split functions by domain (`auth`, `stores`, `listings`, `promotions`, `vendorLocations`, `tours`, `media`, `admin`, `maintenance`) rather than creating one large function.
- Use typed request/response schemas, strict validation, clear error codes and structured logs. Never trust client-supplied role, owner ID, price currency, publication status or audit fields.
- Use Firestore transactions/batched writes for related state changes; make event handlers idempotent because triggers may be delivered more than once.
- Apply App Check enforcement to callable functions in production where supported. For high-cost operations, add per-user quotas, throttling and cost controls.
- Store any external provider secret in Firebase/Google Cloud Secret Manager and bind it only to the relevant function. Never embed secrets in Flutter or public Remote Config.
- Keep function permissions least-privileged. Separate admin actions from owner actions and log all sensitive operations.

### Architecture principles

- Firestore is the single source of truth for application records. Do not add MySQL or PostgreSQL.
- Firebase Authentication is the sole account identity provider. Do not use Laravel Sanctum or a second login/token system.
- Use Firebase Auth `uid` as the stable account identifier and document ID for `users/{uid}`.
- Client-writable profile fields must be allowlisted; role, account status, store approval, membership grants and admin status are never client-editable.
- Use custom claims only for coarse, server-managed privileges such as admin status where appropriate. Use store membership documents for store-scoped grants and check them inside both Rules and Functions.
- Direct Flutter Firestore access is permitted only where rules clearly constrain the operation. Sensitive state transitions must go through Cloud Functions.
- Firestore Security Rules protect client SDK access. Cloud Functions Admin SDK bypasses Rules, so every function performs its own authorization and validation.
- Use Cloud Storage for media bytes. Keep original 360° uploads private; publish only sanitized derivatives after privacy processing and owner review.
- Never put service-account credentials, private API keys or privileged secrets in Flutter, Git or public configuration. Cloud Functions use managed service identity/Secret Manager.
- Use Firestore document schemas with explicit `schemaVersion`, timestamps, bounded document size and clear ownership. A Firestore document has a 1 MiB maximum size; never store image bytes or an entire store inventory in one document.
- Design for Firestore query limitations: denormalize fields needed for common queries, store geohash plus latitude/longitude for nearby lookup, create composite indexes and paginate.
- Firestore is not a full-text/vector search engine. Do not claim native typo-tolerant semantic search; scope MVP search to indexed fields and aliases, and document any later external-search exception.
- Use idempotent asynchronous tasks with bounded retries, failure statuses and reprocessing controls for AI/media workflows.
- Keep development, staging and production Firebase projects separate. Never point a development app at production data.
- Do not claim production readiness until Auth, Rules, App Check, Functions, Storage access controls, backups/exports, restore tests, billing alerts and monitoring are verified.

### Deployment approach

Firebase Authentication, Firestore and Cloud Storage are managed services. Deploy Cloud Functions through the Firebase CLI. The Firebase Local Emulator Suite is for development and CI, not production hosting. The application does not need a continuously running Laravel/PHP server, PostgreSQL instance, Docker Compose backend or VMware Linux VM. Docker may be used for unrelated tooling, but it is not part of the LocalSpot target architecture.

## 9. Firestore Data Model

Firestore is a document database, not a relational SQL database. Model each independently queried record as a document; use subcollections only where the data is naturally owned by a parent. Keep commonly queried fields denormalized where needed, and keep document sizes small.

| **Collection / document path** | **Purpose / important fields** |
|---|---|
| `users/{uid}` | Firebase Auth UID, display profile, account status, role summary, created/updated timestamps. Roles are server-managed, not client-editable. |
| `stores/{storeId}` | Owner UID, name, type, approval status, address/landmark, lat/lng, geohash, schedule, fixed/mobile mode. |
| `stores/{storeId}/members/{uid}` | Membership role and granular grants for inventory, promotions, staff and vendor-location actions. |
| `categories/{categoryId}` | Hierarchical taxonomy: slug, name, parent ID, ancestor IDs, active status and display order. |
| `categorySynonyms/{synonymId}` | Broad phrases and local/alternate terms mapped to category IDs or category subtrees. |
| `products/{productId}` | Shared identity: canonical name, brand, model/variant, category IDs, identifiers, general attributes and moderation status. |
| `productAliases/{aliasId}` | Alternate spellings, brand/model variations and Filipino/English/local names linked to a product or category. |
| `storeListings/{listingId}` | Query-friendly top-level store listing: store ID, product ID, category/ancestor IDs, geohash, lat/lng, price in integer centavos, currency `PHP`, unit, quantity/availability, condition, listing status and last-confirmed time. |
| `stores/{storeId}/stockMovements/{movementId}` | Optional audit history of stock additions, removals and adjustments. |
| `productAttributeSchemas/{categoryId}` | Category-specific attribute definitions, types, units, validation and display rules. |
| `productRecognitionJobs/{jobId}` | Private input object path, owner UID, status, candidates, model/version, confidence, error and owner decision. |
| `mediaAssets/{assetId}` | Cloud Storage object paths, media type, owner/store, private/public state, processing status, blur status, metadata-stripped flag and retention deadline. |
| `storeTours/{tourId}` | Store ID, title, draft/published status and publication details. |
| `storeTours/{tourId}/nodes/{nodeId}` | Panorama asset ID, sequence/order, orientation, position on the tour layout and node status. |
| `storeTours/{tourId}/connections/{connectionId}` | From-node, to-node and arrow/hotspot placement metadata. |
| `promotions/{promotionId}` | Store ID, offer, date range, sponsored status, approval state, targeting constraints and limits. |
| `vendorLocationSessions/{sessionId}` | Owner/store, start/end/expiry, active status, last position, geohash and last update. Only explicit active public sessions are returned to customers. |
| `favorites/{favoriteId}` or `users/{uid}/favorites/{favoriteId}` | User-saved stores/products. Choose one canonical pattern and use it consistently. |
| `reports/{reportId}` | Customer reports for incorrect products, prices, stores, images or promotions. |
| `auditLogs/{logId}` | Append-only record of important owner/admin actions. Client writes are denied. |

### Firestore query and modeling rules

- Do not embed an entire inventory array in `stores/{storeId}`. Keep each listing independently queryable in `storeListings/{listingId}`.
- Store a stable `storeId`, `productId`, category IDs/ancestor IDs, geohash, latitude and longitude on each listing when this makes nearby product queries practical.
- For nearby queries, query geohash ranges, then calculate exact distance and discard false positives. Keep the result set bounded and paginated.
- Store money as integer minor units (for PHP, centavos) plus an explicit currency code; do not use binary floating point for prices.
- Use timestamps consistently (server timestamps for authoritative changes) and record `lastConfirmedAt` separately from `updatedAt`.
- Use subcollections for store memberships, stock movements and tour nodes/connections where parent ownership is meaningful. Remember that deleting a parent document does not automatically delete its subcollections; implement explicit recursive cleanup.
- Create and commit `firestore.indexes.json` and `firestore.rules` to source control. Deploy indexes/rules through CI or a documented release step.
- Define document contracts and a `schemaVersion` for records that may evolve. Use idempotent maintenance scripts or bounded Cloud Functions task-queue jobs for large document migrations; do not treat Firestore as a schemaless free-for-all.
- Keep image bytes, large AI payloads and panorama derivatives out of regular profile/listing documents. Store media in Cloud Storage and store only paths/metadata in Firestore.
- No external search index is required for the Firebase-only MVP. If an external index is approved later, treat it as a derived copy only; Firestore remains the source of truth and the index must be rebuildable.

### Data model rule

One shared product can appear in many stores. Each `storeListings` document owns its own price, selling unit, reported stock, condition and freshness timestamp. This avoids duplicating the canonical product identity for every seller while keeping store listings searchable by product and location.

## 10. Firebase Client Access and Cloud Function Contracts

There is no Laravel REST API and no custom always-on backend. Flutter uses Firebase SDKs directly for allowed operations. The following contracts describe the intended Firebase access pattern, not routes on a REST server.

### A. Direct client operations protected by Firestore Security Rules

| **Area** | **Client operation** | **Required rule behavior** |
|---|---|---|
| Public catalog | Read approved stores, products, categories, active listings and published promotions | Allow only public fields/documents whose status is approved/published; never expose private owner or moderation fields. |
| User profile | Create a minimal profile or update allowlisted fields for `request.auth.uid` | Enforce matching UID; deny changes to role, account status, claims, owner approval and admin fields. |
| Favorites | Create/delete the signed-in user's own favorite records | Restrict document path to the signed-in UID; validate referenced target ID and allowed fields. |
| Reports/feedback | Callable submission with UID attribution, validation and per-account rate limits; all direct client mutations denied | User can create a report but cannot edit status, moderation result or audit metadata. |
| Store/listing mutations | Not direct client writes in production | Use callable Cloud Functions to verify store membership, grants and business invariants. |
| Admin/moderation data | No direct client writes; restrict reads to authorized admins | Use admin-only Functions for state transitions and immutable audit events. |

### B. Callable Cloud Functions (app-invoked privileged operations)

| **Function contract** | **Purpose and required checks** |
|---|---|
| `submitStoreApplication` | Authenticated user submits a store application; validate fields, location, category and duplicate/spam limits. Does not grant owner privileges. |
| `approveStoreApplication` | Admin-only; approve/reject application, create store and owner membership, update appropriate claims/profile state, and write audit event. |
| `manageStoreMembership` | Store owner/admin changes staff membership or grants; cannot grant admin rights; verify caller's current store authority. |
| `createStoreListing` | Verify approved store, owner/staff inventory grant, product data, price in integer centavos, currency, unit and listing status. |
| `updateStoreListing` | Verify listing belongs to an authorized store and only permitted fields are changing; record last-confirmed time and audit event. |
| `archiveStoreListing` | Verify listing ownership/grant and archive rather than silently erase required history. |
| `createOrUpdatePromotion` | Verify store authority, dates, fields and moderation/sponsored-placement rules. |
| `startVendorLocationSession` | Verify owner/staff location grant; enforce maximum duration and explicit sharing. |
| `updateVendorLocationSession` | Verify same active session and membership; validate coordinates, freshness and update rate. |
| `stopVendorLocationSession` | Stop the session immediately and record the stop event. |
| `publishStoreTour` | Verify store authority and that all panorama nodes have approved sanitized derivatives and owner review. |
| `submitReport` | Validate report target/reason, apply abuse controls and write protected moderation status/audit metadata. |
| `adminModerateContent` | Admin-only; approve/reject/suspend content and write an audit record. |
| `deleteUserAccount` | Verify caller identity/recent authentication as required, clean up related data under retention policy and delete/disable Firebase Auth account. |

Every callable function must:
- Require `request.auth` except explicitly public maintenance/event functions.
- Require a valid App Check token in production where supported; enable `enforceAppCheck` for callable functions.
- Validate every input field and reject unknown or privileged fields.
- Load current user status, role and store membership from trusted Firestore records or server-managed custom claims.
- Check ownership and granular grants for the exact resource being changed.
- Apply rate limits/quotas and idempotency keys to expensive or repeatable operations.
- Use server timestamps and write audit metadata that the client cannot forge.
- Return only the minimum data needed by Flutter and use stable, documented error codes.

### C. Event-driven and scheduled Cloud Functions

| **Trigger** | **Purpose** |
|---|---|
| Auth `onCreate` | Create a least-privileged customer profile; never infer owner/admin status from client registration data. |
| Firestore listing create/update | Validate or propagate safe derived metadata; update optional local category aggregates/search tokens. Avoid recursive trigger loops. |
| Storage object finalized | Validate upload path, ownership, content type, size and metadata; enqueue product-image or panorama processing. |
| Panorama processing task | Produce sanitized derivatives, update processing state and fail closed if processing does not complete. |
| Scheduled vendor-session expiry | Mark expired live-location sessions inactive and stop public location display. |
| Scheduled cleanup | Remove expired quarantine files/orphaned assets according to retention policy. |
| Scheduled reconciliation | Detect missing media, stale processing jobs and inconsistent derived fields; do not overwrite authoritative owner data without validation. |

### D. Search contract for the Firebase-only MVP

- Query Firestore using exact names/identifiers, normalized prefix fields, curated aliases, category IDs/ancestor IDs, seller type, selected typed attributes and geohash ranges.
- Use Firebase AI Logic optionally to interpret natural-language text into a bounded structured query (category, attributes, compatibility terms). Validate its output and never let AI generate an arbitrary Firestore query or bypass rules.
- Image search can ask Firebase AI Logic to suggest a likely product/category; use the suggestion to query Firestore fields and show uncertainty. Do not claim vector nearest-neighbour search.
- Firestore does not provide native full-text search. Full semantic/vector search and broad misspelling tolerance are deferred. A future Algolia/Typesense/other search integration would be an explicit external-service exception, not part of the Firebase-only MVP.

### E. Media upload contract

1. Flutter uploads to a path scoped to the authenticated UID, such as `quarantine/{uid}/{assetId}/original`.
2. Storage Rules enforce authentication, matching UID, allowed image MIME types, file-size limits and no client access to other users' raw uploads.
3. A Cloud Storage finalize trigger validates path/object metadata and checks the Firestore owner/store relationship before processing.
4. Cloud Functions create sanitized derivatives under a separate processed path. Client writes to processed/published paths are denied.
5. Firestore media metadata records owner, store, object path, processing status, review status, derivative path, timestamps and retention deadline.
6. Customers can read only published derivatives associated with approved stores/tours. Raw originals remain private.

## 11. Security, Privacy and Data Quality

### Authentication and account security

- Use Firebase Authentication as the only account identity provider. Firebase SDKs manage ID-token refresh; there is no Laravel token exchange.
- Enable only sign-in providers actually supported by LocalSpot. Start with email/password and/or Google sign-in as decided by the product; do not add phone/SMS login without understanding its abuse and per-message costs.
- Require email verification where appropriate, configure password policy and recovery, and use recent authentication for sensitive account changes/deletion.
- Use Firebase Auth UID as the stable account identifier and `users/{uid}` document key.
- Create new user profiles with least-privileged default access. Account creation never creates an owner/admin role.
- Disabled/deleted accounts must be denied by Rules/Functions using current account status. Do not rely only on hiding UI controls.

### Firestore Security Rules

- Commit `firestore.rules` and `firestore.indexes.json` to version control and deploy them through a documented CI/release step.
- Default to deny. Add explicit read/write permissions collection by collection.
- Public users may read only approved/published catalog documents. Keep public store/catalog data separate from private profile fields, store verification documents, pending applications, staff records, reports, audit logs and moderation data; Firestore Rules cannot hide individual fields in an otherwise readable document.
- Users may update only an allowlist of their own profile fields. Rules must reject role, claims, account status, approval status, membership grants, owner UID, moderation state and audit-field changes.
- Use store membership documents and granular grants for staff access. Check membership against the store ID referenced by the target listing/promotion/tour; do not trust client-supplied store IDs alone.
- Allow direct client writes only for low-risk operations that can be fully validated in Rules. Route sensitive state changes through Cloud Functions.
- Security Rules must validate document shape, required fields, field types, allowed field changes, document ownership and immutable fields.
- Test both permitted and denied operations with the Emulator Suite. Include attempts to self-promote to admin, edit another store, change owner IDs, publish unreviewed media and read private originals.

### Cloud Functions security

- Use Cloud Functions 2nd gen with TypeScript and managed runtime identity. Do not embed service-account JSON keys in Flutter, Git or the function source.
- For callable functions, require Firebase Authentication and enforce App Check in production where supported (`enforceAppCheck: true`). App Check is an additional app-attestation layer, not authorization.
- Explicitly verify caller status, admin role or store membership/grants inside every privileged function. Admin SDK access bypasses Firestore Security Rules.
- Validate data server-side: coordinates, price minor units, currency, units, category IDs, URLs, image size/type, panorama dimensions and model attributes.
- Use transactions/batched writes when multiple documents must change consistently. Make functions idempotent and safe against retries/double taps/replayed requests.
- Apply per-UID and per-store rate limits to expensive AI, upload, report, inventory and vendor-location operations. Add quotas and cooldowns for AI calls.
- Store external API secrets using Functions secrets/Secret Manager and bind them only to functions that need them. Never expose secrets via Flutter assets, Remote Config, Firestore documents or logs.
- Use least-privilege runtime service accounts. Separate admin functions from owner/customer functions where practical.
- Write append-only audit records for store approval, role/membership changes, inventory changes, promotion approvals, account suspensions and tour publication. Clients cannot modify audit records.

### Firebase App Check

- Register the Android app with Play Integrity for production App Check.
- Use the App Check debug provider only for debug/emulator/testing builds; never ship debug tokens in a release APK/AAB.
- Start in monitoring mode, verify legitimate devices are passing, then enforce App Check for supported products: Firestore, Storage, callable Cloud Functions and Firebase AI Logic.
- Enforce App Check at the callable function definition for sensitive callable functions, not only through a console toggle.
- Monitor rejection/attestation metrics after each staged release. App Check does not replace Authentication or Security Rules.

### Cloud Storage security

- Upload only to authenticated UID-scoped private quarantine paths; restrict content types, file sizes and allowed path patterns in Storage Rules.
- Deny client reads of raw originals and deny client writes/deletes to processed/published derivatives.
- Only trusted Cloud Functions may move media to approved publication state or create processed derivatives.
- Verify store ownership/membership and upload metadata in the function; an authenticated UID alone does not prove that the user owns the target store.
- Keep raw panoramas private with a documented retention/deletion period. Customers may read only sanitized derivatives attached to published tours.
- Strip unnecessary EXIF GPS metadata from public derivatives. Use versioning/lifecycle controls only where justified and monitor storage/egress costs.

### Data protection, backups and recovery

- Configure Firestore backups or scheduled exports where budget and selected Firestore edition/features permit. Verify current pricing and retention behavior.
- Define backup/restore expectations for Cloud Storage objects separately from Firestore metadata.
- Test restoring Firestore data and required media into a separate non-production project. A configured backup that has never been restored is not a verified recovery plan.
- Choose Firestore and Storage locations deliberately before provisioning. Firestore database location cannot be changed later.
- Keep product images and tour media in Cloud Storage, not Firestore documents. Strip unnecessary EXIF GPS metadata from public derivatives.
- Preserve private originals only for the documented retention period, then purge them through a tested scheduled function. Do not delete the only copy needed for pending review/support.
- Define recovery objectives: acceptable data loss and restoration time. Document how to rebuild derived search tokens/aggregates and reprocess pending media.

### Privacy requirements

- Request customer GPS permission only when it improves nearby search or navigation; manual location selection remains available.
- Do not continuously track mobile vendors by default; require an explicit active sharing session, clear indicator, stop control and automatic expiry.
- Customer location is foreground-only by default. Do not request background-location permission for the initial release and do not retain raw customer movement history by default.
- Require automatic privacy processing and owner review before any 360° image is published. Use person segmentation plus face detection where feasible, provide manual correction and block publication if processing fails.
- Keep unblurred originals private with restricted access and documented retention/deletion. Public viewer images, thumbnails and tiles must come only from sanitized derivatives.
- Test automatic blur at panorama seams/poles, reflections, occlusion, low light and distant-person cases. Manual review remains mandatory; do not promise perfect anonymity.
- Explain how uploaded images are processed, whether Google or other AI services receive them, and how long originals/derivatives are retained.
- Avoid collecting or retaining personal information unnecessary for store discovery and app operation.

### Data freshness and trust

- Track listing status and `lastConfirmedAt` separately from `updatedAt`.
- Let owners quickly mark a product unavailable or update its stock information through authorized operations.
- Show price units clearly (for example, per kilo, per piece, per pack, per meter or per item).
- Distinguish an owner-listed product from a recently confirmed available product.
- Distinguish a fixed store pin from a mobile vendor's active or stale live location.
- Let customers report a wrong location, price or listing.
- Do not claim that a vendor has an item in stock if the system has no reliable recent confirmation.



## 12. Development Roadmap and Milestones

### Status reported by the previous project plan

The previous plan reports that the Flutter app already uses Firebase Authentication and a Firestore wrapper (`LocalSpotFirebaseApi`) for its current data flows. It also reports base catalog/search, map, owner inventory, tour/admin screens and 20 passing smoke tests. These are historical project-reported results; re-run the tests against the current repository before treating them as verified.

| **Area** | **Reported status** | **Required action for this Firebase-only plan** |
|---|---|---|
| Flutter + Firebase initialization | ✅ Reported complete | Re-verify Android Firebase configuration and environment separation. |
| Firebase Authentication | ✅ Reported complete | Harden providers, email verification, account disable/delete behavior and profile creation. |
| Firestore data layer | ✅ Reported complete | Audit all reads/writes and add production-safe access patterns. |
| Existing direct write paths | ⚠️ Must be reviewed | Move privileged mutations into callable Cloud Functions; do not assume current rules are safe. |
| Cloud Storage media | 🟡 Product/store and panorama uploads wired | Product photos publish after metadata stripping; store photos remain private until admin approval; panorama originals upload privately with progress/retry. Storage Rules and cleanup paths have Emulator Suite coverage; trusted panorama privacy processing remains. |
| Geohash nearby queries | 🟡 Partial | New store/listing writes and bounded nine-cell reads use precision-4 geohashes; guarded paginated backfill and status/geohash range query smoke both pass in the Emulator Suite; all declared composite indexes are deployed and READY. Opaque result cursors preserve sorted pages over the bounded snapshot, while continuation beyond source caps remains a ranking/cost design issue. |
| Cloud Functions | 🟡 Privileged workflows in progress | TypeScript Node.js 22, profile initialization, store/listing/promotion/report/vendor/account callables and public active-vendor-location listing are wired and covered by handler/transport emulator smoke tests; production deployment and trusted panorama privacy processing remain. |
| App Check | 🟡 Client and callable enforcement wired | Flutter uses debug/Play Integrity providers and callable Functions enforce App Check; Firebase Console registration, debug-token allowlisting and metrics review remain. |
| Search quality | 🟡 Partial | Keep MVP to Firestore indexed fields/aliases/categories; do not claim native semantic/vector search. Search supports stock availability and validated minimum/maximum price filters on Firebase results; price sorting is supported. The live project now has search prefixes/readiness metadata for all 12 products and geohashes for all 15 active listings; an indexed Firebase search query was verified. Permission/index gaps still retry through bounded public Firestore catalog scans, never production demo fixtures. The scan notice is hidden when the empty query intentionally browses the Firebase catalog; keyword queries still disclose a fallback if used. If the public scan is also denied, production shows an error with no seeded results. Flutter regression tests cover Firebase-only startup and filter behavior; all 32 tests pass. |
| Production operations | ⬜ Incomplete | Backups, restore test, billing alerts, crash reporting, function monitoring and CI. |

### Recommended implementation sequence

1. **Repository audit:** ✅ Initial audit recorded in `docs/FIREBASE_REPOSITORY_AUDIT.md`; inventories Flutter repositories/data sources, API wrappers, direct Firestore writes, Storage paths, rules/indexes, tests and legacy Laravel/Dio references. Recheck any newly added direct writes during code review.
2. **Firebase environment split:** create separate development, staging and production Firebase projects. Confirm which project is configured in each build flavor.
3. **Firestore schema and rules:** 🟡 Documented the current write surface and denied direct client mutations for store, product/listing, membership, stock-history, audit, feedback and report paths. Feedback/report submissions use authenticated callables with server attribution, bounded fields and per-account daily limits. Favorite target IDs must be positive integers and only the owning UID can read/delete its favorites; emulator coverage verifies valid/invalid target and cross-user denial. Review the full field-level access matrix and remaining low-risk direct operations.
4. **Cloud Functions foundation:** 🟡 TypeScript codebase scaffolded in `functions/` for Node.js 22 with `asia-southeast1`; Auth profile initializer, emulator ports and opt-in debug Flutter connections for Auth/Firestore/Functions/Storage are configured. Typecheck/build and Flutter analysis/widget tests pass. The full emulator smoke suite now passes after moving public active-session reads behind an App Check callable.
5. **Privileged workflow migration:** 🟡 Store application submission/review, staff directory listing (owner/admin-only), server-validated email invitations, staff grant updates/removal, listing/inventory, promotion moderation, report resolution, vendor location sessions, rate-limited feedback/report submission and account deletion are implemented and wired to Flutter. Account deletion removes UID-scoped rejected panorama objects indexed by media records and deletes owned tours in bounded pages. The production app entry point now opts out of bundled catalog fixtures; catalog arrays clear before Firebase reads, and read failures leave an empty catalog with a retry action. Demo fixtures are opt-in for tests. Production no longer displays seeded demo staff; the staff screen loads Firebase memberships with loading/error/retry states. Grant changes await the server, disable duplicate edits while pending, roll back on failure and surface an error. Emulator authorization smoke verifies authorization and cleanup paths. Search now keeps controls and results in one scroll view to fit short screens. Flutter analysis is clean and all 32 widget tests pass. Tour drafts are private and client publication is blocked pending the sanitized-media gate. Functions are not deployed yet.
6. **App Check:** 🟡 Flutter initializes Android debug App Check in debug builds and Play Integrity in release builds; all current callable Functions enforce App Check. Firebase Console registration, debug-token allowlisting, metrics monitoring and supported-product enforcement still require project configuration.
7. **Storage migration:** 🟡 Owner images use Firebase Storage quarantine, metadata-stripped derivatives, and private store image paths. Processing triggers retry transient failures; terminal failed uploads retain their quarantine path for scheduled cleanup. Panorama originals remain private and publication is blocked pending a trusted privacy processor. Added direct JPEG/PNG/WebP sanitizer regression fixtures to the CI smoke chain; replacement of legacy catalog URLs remains an explicit guarded migration.
8. **Location/search:** add geohash indexing and query tests. Keep the first release's search within Firestore structured query capabilities and clearly scope semantic/vector search as deferred.
9. **AI integration:** add Firebase AI Logic for product suggestions/query interpretation with App Check, rate limits, strict structured-output validation and owner confirmation. Keep manual entry when AI is unavailable.
10. **Tour privacy pipeline:** 🟡 Storage-triggered panorama validation retries transient failures and records only `awaiting-privacy-processing`; invalid originals are marked failed with a UID-scoped path and age-cleaned if immediate deletion fails. The publication gate stays closed without trusted sanitized derivatives and review. The common image metadata stripper now has crafted JPEG/PNG/WebP plus malformed/unsupported regression fixtures. Face/text detection, panorama transformation, worst-case processing/load tests, owner review persistence and end-to-end emulator coverage remain.
11. **Regression/security tests:** test all roles and negative cases in the Emulator Suite, Flutter integration tests and function tests. Include App Check failure, unauthorized resource IDs, replay/duplicate requests and upload spoofing.
12. **Production rehearsal:** deploy to staging, seed test accounts, run device tests, verify backup/restore, test billing alerts and rehearse rollback.
13. **Remove legacy server dependencies:** ✅ Removed the unused Laravel/PHP/Composer/Docker tree after checking Flutter, Firebase configuration, scripts, tests, and CI for references. Git history preserves the source; README and operations guidance now describe the Firebase-only runtime.
14. **Release:** build signed Android APK/AAB using production Firebase configuration, verify Play Integrity App Check, and monitor Firestore/Functions/Storage usage after rollout.

## 13. Enhanced Acceptance Checklist

### Functional and product requirements
- ☐ A vendor can register/sign in, submit a store application, receive approval and publish listings.
- ☐ The system supports all lawful retail product categories, including food, hardware, tools, electronics, technology, appliances, clothing, household goods, auto parts and other physical merchandise.
- ☐ Photo-assisted product entry returns AI/OCR/catalog suggestions and requires owner confirmation or manual encoding.
- ☐ Customers can search by exact name, known alias, broad category, indexed prefix, supported attributes or image-assisted category suggestion and see participating sellers near the selected location.
- ☐ Broad queries such as “food”, “tech” and “hardware” expand to the correct category descendants.
- ☐ Search limitations are transparent: no claim of native Firestore full-text or vector search.
- ☐ Customers can select a search radius and filter by business type, price, availability and relevant attributes.
- ☐ The in-app 2D map shows the correct registered store and provides an in-app route preview.
- ☐ Store-specific prices, units and availability timestamps are displayed accurately when provided.
- ☐ An owner can publish a connected 360° tour only after privacy processing and review; customers can navigate sanitized viewpoints.
- ☐ Every visible button, category chip, card, map pin, filter, camera control, form action and tour arrow triggers a tested behavior; no inert controls remain.
- ☐ Production screens load persisted Firebase data rather than hardcoded demo records; demo fixtures are limited to development/tests.
- ☐ Relevant screens show loading, empty, validation, permission-denied, stale-data, offline and recoverable-error states.

### Firebase identity, database, functions and media
- ☐ Firebase Authentication is the only primary customer/owner identity provider; no Laravel/Sanctum login flow remains.
- ☐ Firebase UID is the canonical account identifier and maps to `users/{uid}` in Firestore.
- ☐ New users receive least-privileged customer access; users cannot self-assign owner/admin roles.
- ☐ Role and store-membership changes can only be made by authorized Cloud Functions/admin workflows.
- ☐ `firestore.rules`, `firestore.indexes.json` and `storage.rules` are version-controlled and tested in the Emulator Suite.
- ☐ Direct client writes are limited to explicitly approved low-risk operations; sensitive changes go through callable Cloud Functions.
- 🟡 Privileged Cloud Functions validate Auth, App Check, ownership and grants for implemented flows; stock movement history uses an inventory-grant callable, store applications enforce one pending submission plus a three-per-day transactional cap, and promotion creation has a ten-per-day server rate limit. Emulator smoke coverage includes cross-store staff denial, grant/revocation, inventory history, promotion review, report resolution, vendor-session lifecycle/ownership/throttle behavior, account-deletion safeguards/cleanup, and submission limits. Additional function-specific edge cases and production deployment remain.
- ☐ Cloud Functions Admin SDK writes are protected by function-level authorization because Admin SDK bypasses Firestore Security Rules.
- ☐ No service-account keys or privileged provider secrets are embedded in Flutter, Git or public configuration.
- ☐ Firestore document sizes remain below the hard 1 MiB limit; image bytes are stored in Cloud Storage, not documents.
- 🟡 Nearby store/listing queries use bounded geohash ranges plus exact-distance filtering and declared composite indexes. A guarded paginated legacy backfill and geohash range query smoke pass in the Emulator Suite. All 13 declared/retained composite indexes in `capstone-project-561a2` are `READY`. Opaque result cursors continue through the stable globally sorted candidate snapshot; `Load more` stays within that snapshot and partial results are labeled with a lower-bound count. Fetching candidates beyond the caps remains a ranking/cost design issue.
- ☐ Storage originals are private; clients cannot write to processed/published paths; only approved sanitized derivatives are customer-readable.
- ☐ Public 360° assets are sanitized derivatives only; failed/uncertain privacy processing blocks publication.
- ☐ Firestore and Cloud Storage backup/recovery procedures are configured; a restore has been tested in a separate environment.

### App Check, testing and production readiness
- ☐ Android production builds use Play Integrity App Check; debug tokens/providers cannot ship in release builds.
- ☐ App Check is monitored before enforcement and then enforced for supported Firebase products and callable functions.
- ☐ Development, staging and production use separate Firebase projects and configuration.
- ☐ Firebase Emulator Suite tests cover Auth, Firestore Rules, Storage Rules and Cloud Functions.
- 🟡 CI checks Dart formatting and runs Flutter analysis/widget tests, TypeScript compilation, and Auth/Firestore/Storage/Functions emulator smoke checks. On 13 November 2026, Flutter analysis reported no issues, formatting passed, all 23 widget tests passed, Functions build/typecheck passed, the Android debug APK built successfully, and the full `smoke:ci` Emulator Suite passed with transport authorization, staff grants, vendor-session start/update/stop restrictions and throttling, admin promotion/report review, and account deletion cleanup coverage. The local Firestore emulator used a temporary config on `127.0.0.2:19101` because standard/earlier ports were occupied; smoke scripts accept `FIRESTORE_EMULATOR_HOST`. The local emulator host uses Node 24 rather than Functions Node 22, and its rules runtime emitted a shutdown warning after the successful suite exit. Callable App Check enforcement stays enabled outside the `demo-localspot` Functions Emulator; production App Check token rejection is not covered by this smoke. A GitHub Actions run remains unverified.
- ☐ Production APK/AAB is signed and contains the correct production Firebase options, package ID and no emulator configuration.
- 🟡 Android release builds require a private upload keystore and now fail unless an explicit production environment/project/app ID is supplied and the Gradle application ID, `google-services.json`, and Android `firebase_options.dart` registration match. The current `com.example.test_1` package is still a template; register the final package in the production Firebase project and build/sign the actual artifact. See `docs/ANDROID_RELEASE_SIGNING.md`.
- ☐ Firestore/Storage/Functions/AI usage and billing are monitored with budgets and alerts; alerts are understood not to be hard spending caps.
- 🟡 App Analytics and Crashlytics are wired in release builds with debug collection disabled; dependency lockfile resolution, production dashboards/alerts, privacy review and crash receipt verification remain.
- 🟡 A daily Asia/Manila Cloud Function expires unlinked failed/ready product and store uploads after 30 days, claims records transactionally, deletes only UID-scoped quarantine/unlinked derivative paths, and retries claimed cleanup on the next run. Listing/store creation refreshes media `updatedAt` when linking so retained catalog images leave the stale-candidate range. CI includes a cleanup emulator smoke script for stale, linked and recent records. Function logs now omit user/asset identifiers from routine media processing events; scheduler/index deployment, emulator execution, failure alerts and broader retry/idempotency review remain.
- ☐ There is a documented release, backup/restore and rollback procedure.
- ☐ No Laravel/PHP/PostgreSQL/Redis/Docker backend dependency is required to run the production app.

### Primary risks and mitigations
| **Risk** | **Mitigation** |
|---|---|
| Unauthorized role escalation | Deny client role writes; admin-controlled custom claims/memberships; Rules and Function authorization tests. |
| Cloud Functions Admin SDK bypasses Rules | Explicitly authenticate/authorize every privileged function; least privilege; test negative paths. |
| Firestore read/write cost growth | Bound/paginate queries, avoid listener fan-out, denormalize intentionally, monitor reads/writes and set budgets. |
| Firestore query limitations | Use indexed normalized fields, aliases, categories and geohashes; defer native full-text/vector promises or add an explicit external search exception later. |
| App Check false rejections | Monitor first, test supported production devices, stage enforcement and provide a controlled update path. |
| Cloud Storage overuse/exposure | Private quarantine, strict Storage Rules, image limits, lifecycle cleanup and storage/egress alerts. |
| AI misidentifies products | Present ranked suggestions only; owner confirms; manual creation always available. |
| Panorama blur misses people | Panorama-aware processing, manual review/masks, blocked publication on failure and no anonymity guarantee. |
| Duplicate/retried function execution | Idempotency keys, transaction guards, unique job IDs, retry limits and observable failure states. |
| Cloud Functions resource/time limits | Set upload/image-size limits, split work into bounded tasks, test worst cases and document when a specialized processing service would be required. |

## 14. Pilot Launch Strategy
1. Choose one pilot municipality or compact service area before attempting a nationwide launch.
2. Recruit a balanced set of sellers across product categories, including sari-sari stores, market stalls, hardware shops, electronics/technology retailers, household-goods stores and larger retailers.
3. Help sellers list their most commonly requested products first rather than demanding complete inventories.
4. Test real local product searches, alternate names, misspellings and units.
5. Test GPS permission granted/denied, approximate location, weak GPS, indoor/urban positioning, movement refresh, route preview and manual-location fallback on real target phones.
6. Validate 2D map and route coverage and confirm the selected providers' attribution, commercial-use terms, quotas and pricing. Test owner-created 360° tours on target devices.
7. Measure failed searches, stale listings, wrong-location reports, location-fix success, routing errors, app responsiveness and vendor live-session correctness.
8. Use pilot feedback to refine seller onboarding and then expand to nearby areas.

## 15. Firebase Development Environment

### Decision

Use Flutter on Windows and the Firebase Local Emulator Suite for local development. No Laravel/PHP server, PostgreSQL database, Docker Compose backend or VMware Linux server is required.

- Flutter runs natively on Windows/Android Studio.
- Firebase Auth, Firestore, Storage and Functions are emulated locally for development/CI where supported.
- Node.js and Java run the Firebase CLI and Emulator Suite.
- Real Firebase cloud projects are used only for controlled integration/staging/production tests.
- An Android emulator can reach the host machine's emulator endpoints using `10.0.2.2`. A physical Android device can use the laptop's LAN IP when both devices are on the same Wi-Fi and Windows Firewall allows the emulator ports. Do not expose emulator ports to the public internet.
- VMware is optional for unrelated Linux learning; it is not required for LocalSpot.

### Suggested repository layout

```text
LocalSpot/
├── mobile/                              # Flutter Android app
│   ├── lib/
│   └── firebase_options.dart            # Generated project identifiers; no server secrets
├── functions/                           # Firebase Cloud Functions (TypeScript)
│   ├── src/
│   │   ├── auth/
│   │   ├── stores/
│   │   ├── listings/
│   │   ├── promotions/
│   │   ├── vendorLocations/
│   │   ├── tours/
│   │   ├── media/
│   │   ├── admin/
│   │   └── maintenance/
│   ├── package.json
│   ├── tsconfig.json
│   └── eslint.config.js
├── firebase/
│   ├── firestore.rules
│   ├── firestore.indexes.json
│   ├── storage.rules
│   └── firebase.json
├── scripts/
│   ├── seed_firestore.js               # Development-only seeder
│   └── data-maintenance/               # Safe, documented admin scripts
└── tests/
    ├── rules/
    └── integration/
```

If the existing repository is not split into `mobile/` and `functions/`, Kiro should adapt paths to the actual repository rather than moving files unnecessarily.

### Required local tools

1. Flutter SDK and Android Studio/Android SDK.
2. Node.js 22 LTS (or another Node runtime currently supported by Firebase Functions; recheck before upgrades) and npm.
3. Java JDK version required by the installed Firebase Emulator Suite.
4. Firebase CLI (`firebase-tools`).
5. FlutterFire CLI (`flutterfire_cli`).
6. Git and a code editor such as VS Code or Android Studio.
7. Android device/emulator for physical-device and release testing.

Docker Desktop, WSL 2, PHP, Composer, Redis, MySQL, PostgreSQL and Google Cloud ADC are not required for the target architecture. A Cloud Function may use a managed Google service/API, but credentials must be bound through function configuration/Secret Manager, not shipped to Flutter.

### Flutter Firebase packages

Install the packages required by the selected features (verify current compatible versions before upgrading):

```powershell
flutter pub add firebase_core
flutter pub add firebase_auth
flutter pub add cloud_firestore
flutter pub add firebase_storage
flutter pub add cloud_functions
flutter pub add firebase_app_check
flutter pub add firebase_ai
```

- `firebase_core`: initializes Firebase.
- `firebase_auth`: sign-in, registration, logout and session management.
- `cloud_firestore`: rules-protected catalog/profile/favorites reads and explicitly permitted writes.
- `firebase_storage`: authenticated uploads to private quarantine paths and reads of approved assets.
- `cloud_functions`: invoke callable Cloud Functions for sensitive actions.
- `firebase_app_check`: production app attestation; Play Integrity for Android.
- `firebase_ai`: Firebase AI Logic for multimodal product suggestions/query understanding, protected by App Check and usage limits.

Other app packages already in use or required by product scope:

```powershell
flutter pub add geolocator
flutter pub add maplibre
flutter pub add image_picker
flutter pub add url_launcher
flutter pub add firebase_messaging
flutter pub add firebase_crashlytics
flutter pub add firebase_analytics
flutter pub add firebase_remote_config
```

Use only the actual maintained MapLibre Flutter package/API selected by the project; package names may change. Routing/map tile requests remain external provider integrations. Do not put privileged map/routing API secrets in the APK.

### Configure Firebase in Flutter

From the Flutter application directory:

```powershell
npm install -g firebase-tools
firebase login

dart pub global activate flutterfire_cli
flutterfire configure
```

Select the LocalSpot development Firebase project and register the Android app using the exact `applicationId` from the Android Gradle configuration. Select iOS only if it is actually in release scope. `flutterfire configure` generates `firebase_options.dart`. Initialize Firebase before `runApp`. Use build flavors/compile-time configuration to select dev, staging or production Firebase options; never select production only by a user-editable setting.

### Configure Firebase Functions

From the repository root or Firebase configuration directory:

```powershell
firebase init functions
```

Choose TypeScript and the currently supported Node runtime. Add linting, formatting, type checking and automated tests. Keep function code modular by domain. Install only required dependencies; avoid importing the entire Admin SDK into every module if smaller imports are available.

Deploy development functions only after local tests pass:

```powershell
firebase deploy --only functions
```

Set the Functions region explicitly in shared function options and configure Flutter's `FirebaseFunctions.instanceFor(region: ...)` to call the same region.

### Configure Firebase Local Emulator Suite

```powershell
firebase init
firebase init emulators
```

Select Authentication, Firestore, Storage and Functions emulators. Keep `firebase.json`, `firestore.rules`, `firestore.indexes.json` and `storage.rules` in source control.

Start local services:

```powershell
firebase emulators:start --only auth,firestore,storage,functions
```

Configure Flutter to connect to emulators only in debug/test builds. Android Emulator normally reaches the host via `10.0.2.2`; a physical Android phone uses the host laptop's LAN IP when on the same network. Add explicit debug-only App Check debug provider configuration. Release builds must never connect to emulator endpoints or use debug App Check tokens.

Use emulator import/export for repeatable test data. Emulator state is separate from production Firebase. Before destructive CLI commands, check the active project with `firebase use` and print/verify the project ID.

### Typical local workflow

```powershell
# Terminal 1: start Firebase emulators
firebase emulators:start --only auth,firestore,storage,functions

# Terminal 2: run Flutter against emulators
flutter run --dart-define=LOCALSPOT_ENV=development

# Run Flutter checks
flutter analyze
flutter test

# Run Cloud Functions checks from the functions directory
npm run lint
npm run build
npm test

# Deploy only after tests pass and the active Firebase project is verified
firebase deploy --only firestore:rules,firestore:indexes,storage,functions
```

For a physical phone, configure emulator host addresses to the Windows laptop's LAN IP and allow only the required development ports on the private LAN profile. Do not port-forward emulator services from the router or expose them publicly.

### Data persistence warning

Use Emulator Suite export/import for repeatable local test data. Emulator state is separate from production Firebase. Never run a production import/export, delete or cleanup command against the wrong project. Confirm the active Firebase project with `firebase use` and verify the project ID before running destructive operations.

## 16. Production Readiness and Deployment

### Recommended production deployment

Deploy Flutter as a signed Android APK/AAB. Firebase Authentication, Cloud Firestore, Cloud Storage and Cloud Functions are managed cloud services. Do not deploy the Emulator Suite. There is no application server VM to patch, keep running or expose. Cloud Functions scales based on triggered/callable workloads; configure concurrency, memory, timeout, min/max instances and region based on measured traffic and function behavior.

### Development, staging and production separation

| **Environment** | **Purpose** | **Configuration rules** |
|---|---|---|
| Development | Daily feature work | Separate Firebase dev project, Emulator Suite, test users/data, App Check debug provider and development-only AI configuration. |
| Staging | Rehearse releases and integrations | Separate Firebase project, production-like Rules/indexes/Functions, synthetic test data, Play Integrity test app registration and independent billing alerts. |
| Production | Real vendors and customers | Production Firebase project, enforced App Check, locked-down Rules/Storage, least-privilege function identity, backups/exports, monitoring, budget alerts and controlled releases. |

Use separate Firebase projects for development, staging and production. Do not use the same Firestore database with a client-side environment flag as the only separation. Do not copy production personal data into development by default.

### Firebase Authentication production requirements

- Enable only the sign-in providers actually supported by LocalSpot.
- Configure email verification, password policy, account recovery, abuse protections and sign-in rate limits as appropriate.
- Firebase Auth UID is the canonical identity. An Auth trigger creates a minimal customer profile; owner/admin status is granted only through protected workflows.
- Keep role assignment, store ownership and staff membership server-controlled. A Firebase Auth account alone does not grant a store-owner role.
- Require recent authentication for sensitive account actions where appropriate.
- Define a tested disabled-account and account-deletion cleanup strategy. Check current account status in sensitive Functions and Rules.

### Firestore production requirements

- Choose the Firestore location before creating the production database. `asia-southeast1` (Singapore) is a candidate for Philippine users; measure latency and compare pricing/features before provisioning. The database location cannot be changed later.
- Use Firestore Standard edition unless a documented feature/scale requirement justifies another option.
- Commit and deploy `firestore.rules` and `firestore.indexes.json`; test every direct client read/write in the Emulator Suite.
- Default-deny access. Permit public reads only for approved/published documents and safe fields. Protect private profile, membership, application, moderation and audit data.
- Permit client writes only to explicitly allowlisted fields and low-risk user-owned records. Route sensitive changes through Cloud Functions.
- Use bounded queries, pagination, denormalized query fields, geohashes and exact-distance filtering. Rules do not filter query results: design queries so every possible returned document satisfies the caller’s read permission. Avoid unbounded listeners and read amplification.
- Do not store binary images, panorama data or large embedding arrays in documents. Keep documents comfortably below Firestore's 1 MiB hard maximum.
- Add document schema versioning and safe migration scripts for evolving document shapes.
- Monitor reads, writes, deletes, stored bytes, index usage, outbound transfer and high-cost query patterns.

### Cloud Functions production requirements

- Use 2nd-generation Functions with TypeScript and a supported Node runtime (Node.js 22 is the selected baseline as of this plan; recheck runtime support during deployment).
- Explicitly set regions. Singapore (`asia-southeast1`) is supported for Cloud Functions and is a candidate for callable operations serving Philippine users. Align event-triggered Functions with the Firestore/Storage resource region where supported; region mismatch can add latency and network cost.
- Start callable functions with authentication required. Enable App Check enforcement in function options for privileged callable functions (`enforceAppCheck: true`).
- Validate input shape, ownership, role/membership grants, account status and business invariants inside each privileged Function.
- Remember that Admin SDK writes bypass Firestore Security Rules. Function-level checks are mandatory.
- Use transactions for related writes and idempotency guards for triggers/retries. Do not assume event triggers execute exactly once.
- Apply rate limits and quotas to AI, media, report and vendor-location operations. Use function max instances and concurrency controls where useful for cost/abuse containment.
- Configure function memory/CPU/timeouts to the real workload. Large panorama processing must be chunked/bounded and load-tested; do not assume unlimited runtime.
- Use Secret Manager/Functions secrets for external keys. Bind secrets only to the relevant function and rotate them.
- Configure structured logs, error reporting, failure alerts and a manual reprocessing mechanism for failed media jobs.

### Firebase App Check production requirements

- Register the Android production app with Play Integrity.
- Use the App Check debug provider only in debug/emulator builds; ensure release build configuration cannot enable it.
- Monitor App Check metrics before enforcement to avoid rejecting legitimate users.
- Enforce App Check for supported products used by LocalSpot: Firestore, Storage, callable Functions and Firebase AI Logic. For Firebase AI Logic, App Check enforcement is required under the current policy; verify the project shows enforcement before production use.
- For callable Functions, enforce token validation in the function runtime options as well as configuring the Firebase service.
- App Check does not replace Firebase Authentication, Firestore Rules, rate limits or business authorization.

### Cloud Storage production requirements

- Cloud Storage for Firebase requires the Blaze pay-as-you-go plan for new/default bucket provisioning and continued access under the current published policy. No-cost usage allowances may still apply, but usage above them is billable.
- Select a bucket location deliberately. Keep it near Firestore/Functions where supported and verify pricing/data-residency implications.
- Flutter uploads only to private UID-scoped quarantine paths through Firebase Storage SDK. Storage Rules restrict authenticated UID, accepted image content types and file sizes; client reads of raw originals and client writes to published/sanitized paths are denied.
- Cloud Functions verifies the uploaded object, owner/store relationship and metadata before processing. It writes sanitized derivatives to a separate processed/published path.
- Only sanitized 360° images and approved product/store images may be exposed to customers. Private originals must never be returned in public document fields or URLs.
- Set lifecycle/retention rules for originals, failed uploads and orphaned derivatives. Test deletion and restore procedures.
- Monitor storage GB-months, downloads, requests, egress and panorama-viewer bandwidth; optimize image sizes and create appropriate previews/tiles.

### AI and search production requirements

- Firebase AI Logic may be used for multimodal product suggestions and natural-language query interpretation. Its Flutter SDK can send image inputs; protect it with App Check and configure per-user rate limits/quotas.
- Use structured output schemas, input-size limits, timeouts and conservative error handling. Treat AI responses as untrusted and require owner confirmation for product/listing data.
- Do not expose provider API keys in Flutter. For services requiring secrets, call them from a Cloud Function with secrets bound to that function.
- Keep MVP product search within Firestore's indexed query model: normalized exact/prefix tokens, aliases, category descendants, typed attributes and geohashes.
- Firestore does not provide native general-purpose full-text/vector search. If product scale later requires semantic/vector/fuzzy search, add a dedicated external search service only after a documented architecture decision and cost/security review.

### CI/CD, backup and recovery

1. Run Flutter format, static analysis, unit/widget/integration tests and Android release build checks.
2. Run Cloud Functions lint, TypeScript build, unit tests and callable-function authorization tests.
3. Run Firebase Emulator Suite tests for Auth, Firestore Rules, query behavior, Storage Rules and Functions.
4. Validate indexes/rules and verify that development/staging/production project IDs are not mixed.
5. Deploy to staging, run smoke tests, verify Firebase Auth login, nearby search, callable mutations, uploads, AI flows and tour publication.
6. Configure Firestore backup/export and Cloud Storage object recovery according to budget and retention needs; verify current pricing and feature eligibility.
7. Test a restore into a separate non-production project and verify the app can read restored data and sanitized media.
8. Deploy versioned Firebase Rules, indexes and Functions with a documented rollback plan; use gradual rollout for the Android app.

### Cost and quota controls

- Firestore free quota is limited and usage beyond it is billed. Recheck current Standard-edition quotas/pricing for the chosen region at launch; do not hardcode assumed free allowances into the application.
- Cloud Functions has no-cost usage allowances, but deployment requires an eligible billing setup and usage above allowances is billable. Check current regional tier pricing.
- Cloud Storage for Firebase requires the Blaze plan for new/default buckets under the current policy; storage, operations and downloads can be charged even when some no-cost allowances apply.
- Firebase AI Logic/Gemini model usage may be billable depending on provider/model/tier and consumption. Set App Check, per-user quotas, rate limits and budget alerts before enabling public AI usage.
- Firebase budgets and alerts are monitoring tools, not guaranteed hard spending caps. Configure alerts at multiple thresholds and monitor all linked Google Cloud services.
- Track cost per active user, search, AI recognition, panorama upload and panorama view. Use pagination, limited listeners, image optimization, caching and throttling.

### Production launch gate

Do not call LocalSpot production-ready until Firebase Authentication, Firestore Rules/indexes, Cloud Functions authorization, App Check enforcement, Cloud Storage access controls, panorama privacy publication gate, backups/restores, billing alerts, monitoring, negative security tests and a documented rollback/recovery procedure have all passed.

## 17. Reference Documentation

Check current official documentation and pricing during implementation because Firebase products, supported runtimes, quotas and billing can change.

- **Firebase for Flutter setup:** https://firebase.google.com/docs/flutter/setup
- **Firebase Authentication for Flutter:** https://firebase.google.com/docs/auth/flutter/start
- **Cloud Firestore for Flutter:** https://firebase.google.com/docs/firestore/quickstart
- **Firestore security rules:** https://firebase.google.com/docs/firestore/security/get-started
- **Firestore query/index management:** https://firebase.google.com/docs/firestore/query-data/indexing
- **Firestore full-text search guidance:** https://firebase.google.com/docs/firestore/solutions/search
- **Firestore quotas and limits:** https://firebase.google.com/docs/firestore/quotas
- **Firestore pricing:** https://firebase.google.com/docs/firestore/pricing
- **Firestore locations:** https://firebase.google.com/docs/firestore/locations
- **Cloud Storage for Firebase:** https://firebase.google.com/docs/storage
- **Cloud Storage for Firebase billing requirements:** https://firebase.google.com/docs/storage/faqs-storage-changes-announced-sept-2024
- **Cloud Storage security rules:** https://firebase.google.com/docs/storage/security
- **Firebase Cloud Functions:** https://firebase.google.com/docs/functions
- **Cloud Functions callable functions:** https://firebase.google.com/docs/functions/callable
- **Cloud Functions locations:** https://firebase.google.com/docs/functions/locations
- **Cloud Functions supported runtimes/manage functions:** https://firebase.google.com/docs/functions/manage-functions
- **Cloud Functions task queue functions:** https://firebase.google.com/docs/functions/task-functions
- **Cloud Functions secrets:** https://firebase.google.com/docs/functions/config-env
- **Firebase App Check overview:** https://firebase.google.com/docs/app-check
- **App Check in Flutter:** https://firebase.google.com/docs/app-check/flutter/default-providers
- **App Check enforcement for callable Functions:** https://firebase.google.com/docs/app-check/cloud-functions
- **Firebase AI Logic:** https://firebase.google.com/docs/ai-logic
- **Firebase AI Logic image analysis:** https://firebase.google.com/docs/ai-logic/analyze-images
- **Firebase AI Logic App Check:** https://firebase.google.com/docs/ai-logic/app-check
- **Firebase Local Emulator Suite:** https://firebase.google.com/docs/emulator-suite
- **Emulator Suite install/configure:** https://firebase.google.com/docs/emulator-suite/install_and_configure
- **Firebase CLI reference:** https://firebase.google.com/docs/cli
- **FlutterFire CLI:** https://firebase.google.com/docs/flutter/setup
- **Firebase Cloud Messaging:** https://firebase.google.com/docs/cloud-messaging/flutter/client
- **Firebase Crashlytics for Flutter:** https://firebase.google.com/docs/crashlytics/flutter/get-started
- **Firebase Analytics for Flutter:** https://firebase.google.com/docs/analytics/get-started?platform=flutter
- **Firebase Remote Config for Flutter:** https://firebase.google.com/docs/remote-config/flutter/get-started
- **Flutter architecture guide:** https://docs.flutter.dev/app-architecture/guide
- **MapLibre for Flutter:** https://pub.dev/packages/maplibre
- **Flutter Geolocator:** https://pub.dev/packages/geolocator
- **OpenStreetMap tile usage policy:** https://operations.osmfoundation.org/policies/tiles/

## 18. Implementation Backlog — What to Build Next

Use this section as the working queue. Items marked ✅ are reported as present in the current Flutter/Firebase codebase; items marked ⬜ are not yet verified or remain to be implemented for the new target architecture. Re-run all tests before treating a reported item as complete.

### Already reported in the current Firebase Flutter codebase

| Area | Reported status | Notes |
|---|---|---|
| Firebase Authentication | ✅ | Email/Password sign-in, registration, logout and session persistence. |
| Firestore catalog reads | ✅ | Existing `LocalSpotFirebaseApi` reportedly reads stores, products, listings, promotions, tours, users, store members, favorites, reports, feedback, vendor sessions, stock movements and audit logs. |
| Firestore writes | ✅ | Existing flows reportedly write store registration, listings, promotions, tours, staff, vendor sessions, reports, feedback, favorites and audit logs. **Sensitive writes must be moved to Cloud Functions or secured by verified Rules before production.** |
| Firebase search | ✅ Partial | Keyword/category expansion, seller-type/radius filters and distance sorting are reported; search is not full-text/vector search. |
| Product recognition | ✅ Basic | Keyword/alias/barcode catalog scoring; owner confirmation required; no production multimodal AI pipeline verified. |
| Route preview | ✅ Basic | Correct Haversine distance and straight-line map geometry; no ETA is shown unless a routing provider supplies one. This is not road routing. |
| Firestore Rules/indexes | ✅ Existing baseline | Prior plan reports deployed rules/indexes; these must be audited and rewritten for least-privilege direct client access. |
| Demo seeder | ✅ | `scripts/seed_firestore.js` seeds demo users/stores/products/listings only with explicit opt-in, Auth and Firestore Emulator hosts, and a `GCLOUD_PROJECT` beginning `demo-`; it uses no service-account key. |
| Map and location | ✅ Basic | MapLibre, GPS permission, follow-my-location, nearby refresh and route drawing reported. Re-test on physical Android devices. |
| Owner inventory | ✅ UI/flow baseline | Photo suggestion, category attributes, archive and stock history reported; sensitive mutations need callable functions. |
| Store tours | ✅ UI/flow baseline | Draft/process/review/publish gate and manual blur UI reported; actual automated privacy processing is not verified. |
| Admin | ✅ UI/flow baseline | Review screens and audit log reported; admin operations must be server-controlled through Functions. |
| Smoke tests | ✅ Reported | 20 tests reported; rerun after the architecture refactor and add Emulator Suite tests. |

### Wave 1 — Security foundation and Cloud Functions (highest priority)

1. 🟡 Audit every direct Firestore write and mark its required authorization level. Initial write inventory and privilege gaps are documented; tours, remaining profile/admin-safe writes, Storage and a full field-level access matrix remain.
2. 🟡 Replace permissive rules with default-deny `firestore.rules` and explicit public/user/owner/staff/admin access. Store, tour, feedback and report mutations deny direct client writes; store changes use validated Functions, and tour draft creation/node/link changes use an owner/admin callable that rejects processing/review/publication fields. Feedback/report callables bind numeric IDs to the signed-in profile, validate fields and enforce daily per-account limits. Public store/promotion queries expose approved records only. Direct vendor-session collection listing is denied; an App Check callable filters active sessions at server time and returns only location/update fields. Emulator coverage includes direct-write denial and callable input/rate-limit cases.
3. 🟡 Initialize `functions/` using TypeScript and Cloud Functions 2nd gen. The scaffold, explicit region, emulator ports and debug-only Flutter emulator connections are present; typecheck/build pass. Emulator Rules/callable/Storage smoke checks pass; production deployment remains.
4. ✅ Implement Auth `onUserCreated` profile initialization with customer-only defaults using the 2nd gen Identity trigger.
5. 🟡 Implement `submitStoreApplication`, `approveStoreApplication` and `manageStoreMembership`. Server callables are wired for submission, review, staff invitation, grant updates and confirmed staff removal; handler and transport authorization/rate-limit emulator checks pass. Production deployment remains.
6. 🟡 Implement `createStoreListing`, `updateStoreListing`, `archiveStoreListing` and inventory audit writes. Server callables, Flutter wiring, query indexes and inventory-grant/access emulator checks are present. Production deployment remains.
7. 🟡 Implement promotion, reports/moderation, vendor-location session and tour-publication functions. Promotion submission/review, admin report resolution and vendor session start/update/stop are implemented and covered by handler checks; tour draft create/node/link mutations use `manageStoreTour` and owner-vs-other-user transport authorization is tested. Trusted panorama privacy processing, owner review and publication remain blocked until sanitized derivatives exist.
8. 🟡 Require App Check on callable Functions and test auth/role/ownership failure cases. Callables enforce App Check; the Flutter client selects debug/Play Integrity providers; Console registration/allowlisting remains. Emulator smoke checks cover unauthenticated rejection and customer/owner/cross-store authorization.
9. 🟡 Add TypeScript typecheck, lint, unit tests and Emulator Suite integration tests to CI. Typecheck/build, Dart analysis, format checks and all 23 Flutter widget tests pass locally. Auth-profile, Firestore Rules denial, callable-handler role/ownership, storage and cleanup smoke scripts run in `smoke:ci`; the full emulator suite passed after the vendor-session query authorization fix. The first GitHub Actions run and production App Check validation remain unverified.

10. 🟡 Implement `deleteUserAccount` with recent-authentication checks, ownership/admin protections and cleanup of personal data. Callable and Profile action are implemented; emulator coverage now verifies stale-auth/admin/store-owner denial, Auth and profile deletion, user-data and media cleanup, linked-media retention and audit retention. Product review of the retention policy remains.

### Wave 2 — Cloud Storage media

1. 🟡 Wire product image upload to Firebase Storage private quarantine paths. Add Product uploads a confirmed new product photo, waits for server validation/publication, and passes the ready asset to the listing callable; Storage access and cleanup behavior have Emulator Suite coverage, while full client-to-finalize media cases remain.
2. 🟡 Wire store image upload to Firebase Storage. Store applications upload a metadata-stripped image to private quarantine; it stays private until admin approval publishes the image and updates the store.
3. 🟡 Wire panorama upload to private Storage paths with upload progress and retry. The tour editor uploads selected panoramas to the signed-in UID's private originals path, reports transfer progress, and retries the same object path after upload or draft-save failures; publication remains blocked until server privacy processing exists.
4. 🟡 Write Storage Rules for UID/path/type/size restrictions and deny client writes to processed/public paths. UID-scoped product, store and panorama quarantine rules restrict image MIME types and file sizes, originals stay private, and clients cannot write public derivatives; Storage Rules emulator checks pass.
5. 🟡 Add Storage finalize trigger validation and Firestore media status tracking. Product and store image finalization validate declared MIME, byte signature, account and size, strip metadata and record media status; product derivative is public after validation, while store derivative is private until approval. Panorama processing and status tracking remain.
6. 🟡 Replace external Unsplash placeholder URLs in production data with real Storage uploads; keep placeholders only in development fixtures. Live Firebase catalog mapping now suppresses legacy Unsplash store, product and tour-node images, and the demo Firestore seeder refuses to run outside an explicitly enabled Emulator `demo-*` project. Added a project-confirmed dry-run/apply cleanup script for old catalog records; run and review its dry run against the intended project before clearing legacy URLs. Uploading replacement images remains an owner workflow.

### Wave 3 — App Check and nearby search

1. 🟡 Register Android production app with Play Integrity App Check. Release builds select Play Integrity in the client; Firebase Console app registration and production metrics review remain.
2. ✅ Add debug provider only to debug/emulator builds. Flutter selects the debug provider in debug builds and Play Integrity in release builds.
3. 🟡 Monitor App Check metrics and enforce for Firestore, Storage, callable Functions and AI Logic where supported. Deployed callable Functions enforce App Check; the isolated CI demo emulator disables only callable App Check middleware so transport Auth/ownership checks can run. Console metrics review and supported-product enforcement remain.
4. 🟡 Add geohash fields to store and listing documents; build bounded range queries and exact-distance filtering. New store/listing writes include precision-4 hashes; nearby stores and coordinate-based listing search read up to 250 candidates from each of nine neighboring prefixes, deduplicate, and apply exact-distance filters. Added a paginated dry-run-first backfill for legacy stores/listings; stage and execute it against the intended project after reviewing dry-run counts.
5. 🟡 Add/verify composite indexes and pagination. Composite `(status, geohash)` indexes are declared for stores/listings, `(status, numericId)` for batched search store joins, and `(ended_at, expiresAt)` for public live-session reads. Search honors relevance/distance/price/freshness sorting and returns page metadata with at most 50 results per response. Missing-index errors fall back to catalog reads with a visible notice. Search loads only matching approved stores. Geohash status/range queries pass emulator access tests, and reads fetch one extra document to detect per-prefix truncation; searches without coordinates now fetch at most 2,500 active listings plus one sentinel. The UI reports a lower bound, labels capped samples, and explains that `Load more` stays within the current snapshot. Opaque cursors page through the stable, locally sorted snapshot without repeating reads; all 13 deployed project indexes are `READY`, while continuation beyond candidate caps remains open.
6. 🟡 Normalize search phrases and category comparisons; match known aliases and category families; support exact structured attribute filters through `attribute.<key>=<value>` and label attribute-only matches. New products store bounded normalized `searchPrefixes`; search uses indexed `arrayContainsAny` candidates after backfill readiness and retains the legacy fallback until then or on missing index. Indexed and fallback product reads are capped at 2,500 with sentinel truncation reporting. Added CI emulator coverage for dry-run nonmutation, project confirmation, prefix/geohash writes, readiness and idempotency. The backfill smoke passed in the latest full Emulator Suite run; alias governance and load verification remain.
7. ✅ Document that full-text/vector/semantic search is not a native Firestore capability; advanced search is explicitly deferred or requires a separately approved external-service exception.

### Wave 4 — AI product assistance

1. 🟡 Integrate Firebase AI Logic image input for owner-side product suggestions. Add Product sends a bounded local image to the Gemini Developer API through Firebase AI Logic and falls back to catalog/manual entry on failure; Firebase Console provider/App Check configuration and device smoke checks remain.
2. 🟡 Add strict structured response schema and parse/validate every AI field. Responses are constrained to a JSON schema, max three valid items, known categories/attribute keys and field-length/type checks; base64 image size is checked before decoding and owner text is passed as untrusted JSON data. Offline tests cover input limits, malformed responses, invalid categories, attribute allowlists and result bounds; live model output tests remain.
3. ✅ Keep price, quantity, availability, compatibility and safety claims owner-confirmed or sourced from trusted data. AI output omits price, stock and safety fields; owners review/edit every suggestion before saving.
4. 🟡 Add AI rate limits, App Check, usage monitoring and manual-entry fallback. The owner suggestion route checks the signed-in profile for owner/admin or inventory-staff access; the client allows at most six requests per minute per running app process; App Check client providers are initialized; and manual entry remains available. Client checks/throttling are not abuse boundaries. Configure Firebase AI Logic App Check enforcement, project quotas and usage monitoring in Firebase Console.
5. 🟡 Add optional natural-language query interpretation into structured category/attribute filters. Search exposes an explicit “Interpret with AI” action; validated output can set an existing category family and one allowed brand/attribute filter, with a clear action to remove AI filters. Ordinary typing stays on standard search. Firebase provider/App Check/usage configuration, device smoke checks, representative intent accuracy review and tests remain.

### Wave 5 — 360° privacy pipeline

1. 🟡 Replace URL-based panorama placeholder with real private Cloud Storage upload. The online tour editor requires a selected JPEG/PNG/WebP under 50 MiB, uploads to the signed-in user's `tours/originals/{uid}/{tourId}/{assetId}` path with progress, and stores that private path in the draft. Unsplash sample controls are hidden in online mode and remain available only in demo mode. Repeated create calls reuse the owner's existing draft after a lost callable response. The editor can recover the owner's validated, not-yet-linked panorama from `mediaAssets` after restart and retry saving it to the tour. Emulator coverage remains.
2. 🟡 Implement Storage-triggered Cloud Function validation and a retryable processing task. A retry-enabled finalize trigger now validates panorama MIME, size and byte signature, deletes invalid originals, and records valid uploads as `awaiting-privacy-processing`. It never marks them sanitized; an actual detection/transform worker, emulator validation and failure/retry review remain.
3. ⬜ Integrate a suitable person/face detection/segmentation service and image transformation pipeline.
4. ⬜ Generate sanitized derivatives/previews only; never expose raw originals.
5. 🟡 Require owner review/manual correction and block publication if processing is failed or incomplete. Online clients can no longer mutate trusted tour fields directly or claim a panorama is processed/reviewed/published; persistent review and manual-mask flows remain pending the trusted processor.
6. ⬜ Test maximum supported image sizes, seams/poles, reflections, occlusion and function resource limits.

### Wave 6 — Production operations and Android release

1. ⬜ Create separate staging and production Firebase projects.
2. ⬜ Configure Firestore backups/exports and Cloud Storage media recovery.
3. ⬜ Test restore into a separate non-production project.
4. ⬜ Configure billing budget alerts, quotas, function max instances and AI usage controls.
5. ⬜ Add Firebase Crashlytics, Analytics and Cloud Logging/Monitoring.
6. ⬜ Test production Firebase configuration and Play Integrity App Check on real devices.
7. ⬜ Build signed APK/AAB; verify no emulator/debug settings or secrets are included.
8. ✅ Remove unused legacy server code and stale operational instructions after verifying the active app/build/CI dependency surface.

### Out of scope for the Firebase-only MVP

- Laravel REST API, Laravel Sanctum and PHP backend.
- MySQL or PostgreSQL as a second application database.
- Docker-hosted application backend, Redis server or VMware Linux server.
- Full native Firestore full-text search, vector nearest-neighbour index or guaranteed semantic search.
- Cart, checkout, payments, delivery and rider tracking.
- Third-party Street View / Mapillary / KartaView / Panoramax.
- Background tracking of customers.
- Nationwide coverage claims; participating sellers only.

## 19. Firebase Project Setup and Migration Checklist

This is the practical setup order for the Firebase-only architecture. Complete development setup first; create production resources only after region, security, cost and recovery design have been reviewed.

### A. Accounts and installations on the developer PC

1. Use a Google account with access to Firebase/Google Cloud billing and project administration.
2. Install Flutter SDK and Android Studio/Android SDK.
3. Install Node.js 22 LTS (or a Firebase-supported runtime version), npm and Java JDK required by the Emulator Suite.
4. Install Firebase CLI:
   ```powershell
   npm install -g firebase-tools
   firebase login
   firebase --version
   ```
5. Install FlutterFire CLI:
   ```powershell
   dart pub global activate flutterfire_cli
   ```
6. Keep Git repository secrets out of source control. Use a password manager/secret manager for administrative credentials.
7. Docker Desktop, WSL 2, XAMPP, PHP, Composer, PostgreSQL, MySQL and a VMware Linux server are not required by the target LocalSpot architecture.

### B. Create the Firebase development project

1. In Firebase Console, create `LocalSpot-Development` using a unique project ID.
2. Add the Android app with the exact package/application ID used by the Flutter project.
3. Enable Firebase Authentication and only the providers planned for the first release. Test account creation, email verification, sign-in, password reset, sign-out and account disable/delete behavior.
4. Create Cloud Firestore in Native mode and choose the region deliberately. `asia-southeast1` (Singapore) is a candidate for a Philippine pilot; verify current feature availability, latency and pricing before creation. Firestore database location cannot be changed later.
5. Create the Cloud Storage bucket. Current Firebase policy requires the Blaze pay-as-you-go plan to provision/use new/default Cloud Storage buckets; link a billing account and configure budget alerts before enabling uploads.
6. Select Storage location deliberately and check its relationship to Firestore and Cloud Functions regions.
7. Initialize Firestore Rules/indexes and Storage Rules with restrictive defaults. Do not use test-mode rules in staging/production.
8. Enable Cloud Functions and choose TypeScript/Node.js 22. Set the region explicitly in code and align it with Firestore/Storage where supported.
9. Enable Firebase App Check and register the Android app with Play Integrity for production; configure debug provider only for local builds.
10. Configure billing budgets/alerts, quotas and usage monitoring before enabling public uploads or AI features.

### C. Configure the Flutter app

From the Flutter app directory:

```powershell
flutter pub add firebase_core firebase_auth cloud_firestore firebase_storage cloud_functions firebase_app_check firebase_ai
flutterfire configure
```

Add feature packages as needed:

```powershell
flutter pub add firebase_messaging firebase_crashlytics firebase_analytics firebase_remote_config
```

Select the development Firebase project and register the Android app using its exact application ID. `flutterfire configure` generates `lib/firebase_options.dart`. Initialize Firebase before `runApp`. Configure separate dev/staging/prod build flavors/options. Release builds must use production Firebase configuration, Play Integrity App Check and no emulator endpoints/debug providers.

### D. Initialize Cloud Functions

From the repository root:

```powershell
firebase init functions
```

Choose TypeScript and Node.js 22 if it is listed as supported by the installed Firebase CLI. In `functions/`, implement modular source files, input schemas, common authorization helpers, structured logging, linting, type checking and tests.

Use callable Functions for sensitive client-invoked operations. Use Firestore/Storage event triggers for automation and scheduled Functions for expiry/cleanup. Configure the intended region explicitly. Use Functions secrets/Secret Manager for any external API keys. Do not place secrets in Flutter or Firestore.

### E. Configure the Firebase Local Emulator Suite

```powershell
firebase init emulators
firebase emulators:start --only auth,firestore,storage,functions
```

Select Authentication, Firestore, Storage and Functions emulators. Add emulator configuration to `firebase.json` and commit Rules/index files.

Configure Flutter to connect to emulators only in debug/test builds. Android Emulator normally reaches the host computer via `10.0.2.2`. A physical phone can connect over the same private Wi-Fi using the laptop's LAN IP; configure the emulator host binding for private-LAN development only and allow the ports only on the Windows private network profile. For USB-only testing, use ADB reverse for the emulator ports (commonly Auth 9099, Firestore 8080, Storage 9199 and Functions 5001):

```powershell
adb devices
adb reverse tcp:9099 tcp:9099
adb reverse tcp:8080 tcp:8080
adb reverse tcp:9199 tcp:9199
adb reverse tcp:5001 tcp:5001
```

Then point the debug Flutter build to the device-local forwarded endpoints. Never expose emulator ports to the public internet. Use the App Check debug provider for tests only; it must never be enabled in release builds.

Use emulator export/import for repeatable test data. Confirm `firebase use` and the project ID before every deploy or destructive data operation.

### F. Refactor existing Flutter data operations

1. Audit every method in the current `LocalSpotFirebaseApi` and map it to one of: public Firestore read, protected user-owned write, callable Function, Storage upload/read or external map/routing request.
2. Keep direct reads for approved public catalog/store/listing documents where Security Rules allow them.
3. Keep direct writes only for low-risk user-owned data whose complete validation can be enforced by Security Rules (for example, a user's own favorite records or an allowlisted profile field).
4. Move store approval, role/membership changes, owner/staff inventory mutations, promotion moderation, vendor live-location sessions, tour publication, audit writes and account deletion into callable Cloud Functions.
5. Replace UI code that assumes a privileged direct write succeeds with typed callable Function results, loading states, duplicate-submit protection and actionable error handling.
6. Make Security Rules match the new access matrix. Never loosen Rules to make an existing screen work; change the screen/workflow instead.
7. Add emulator tests for allowed and denied reads/writes and function tests for unauthenticated, wrong-role, wrong-store, invalid-input, replay and App Check failure cases.

### G. Media and AI configuration

1. Create private Storage quarantine paths for product, store and panorama images.
2. Enforce UID/path/type/size limits in Storage Rules. Deny client access to raw originals and all client writes to processed/published paths.
3. Add Storage finalize triggers to validate uploads and set Firestore processing states.
4. Configure Firebase AI Logic for the selected Gemini provider/model. Require App Check, set per-user limits, define strict structured output and keep owner confirmation/manual entry.
5. If an external AI/vision API is required, call it only from a Cloud Function using a secret; include data-sharing, privacy, cost and retention review.
6. Do not publish 360° tours until every panorama has a sanitized derivative and owner review. Failed or uncertain processing must fail closed.

### H. Legacy Laravel/backend cleanup

1. ✅ Searched Flutter, Firebase configuration, scripts, tests, and CI for backend dependencies and found no active use of the legacy server tree.
2. ✅ Removed the unused legacy server directory; Git history retains prior source.
3. ✅ Replaced stale README and operations guidance and removed obsolete gateway token compatibility shims.

### I. Before production launch

- Confirm Firestore and Storage locations, and explicit Cloud Functions region.
- Confirm billing account, budget alerts, quotas and service costs; remember budget alerts are not guaranteed hard caps.
- Verify Firebase Auth providers, email verification, recovery, disabled-account and account-deletion behavior.
- Verify Rules deny unauthorized reads/writes and role escalation.
- Verify each privileged Function performs Auth, App Check, role/membership, resource ownership, input and rate-limit checks.
- Verify Storage quarantine, private originals, sanitized derivatives and publication-only customer access.
- Verify App Check Play Integrity on real supported Android devices and ensure debug mode cannot ship.
- Verify indexes, geohash queries, pagination and search limitations.
- Verify backups/exports, restore test, media recovery, monitoring and rollback/release procedure.
- Run load, security, regression and physical-device tests, then build and sign the production APK/AAB.

## Final Architecture Decision

Use **Flutter + Firebase Authentication + Cloud Firestore + Cloud Storage + Firebase Cloud Functions + Firebase App Check**.

- Flutter is the Android client. It uses Firebase SDKs directly for authentication, approved catalog reads, realtime listeners and limited safe user-owned operations.
- Firebase Authentication is the only account identity system. Firebase UID is the canonical user ID.
- Cloud Firestore is the only primary application-record database. Do not add PostgreSQL, MySQL or a parallel authoritative database.
- Cloud Functions 2nd gen (Node.js + TypeScript) is the trusted backend for store applications/approval, roles/memberships, inventory invariants, promotions, moderation, vendor-location sessions, audit records, account deletion, media processing orchestration and scheduled cleanup.
- Firestore Security Rules protect direct client SDK access. Cloud Functions must perform explicit authorization because Admin SDK writes bypass Rules.
- Firebase App Check with Play Integrity protects supported production Android requests and must be enforced for callable Functions and supported Firebase products after monitoring/testing.
- Cloud Storage stores product/store images and 360° media. Original panoramas remain private; only privacy-processed and owner-reviewed derivatives can be published.
- Firebase AI Logic may provide multimodal product suggestions and structured search-intent interpretation. AI results are suggestions only; owners confirm product identity and store-specific values.
- The Firebase-only MVP uses Firestore indexed exact/prefix/alias/category/attribute/geohash queries. Firestore does not provide native full-text/vector search; advanced search is deferred or requires a separately approved external-service exception.
- Firebase Local Emulator Suite is used for local Authentication, Firestore, Storage and Functions development/testing. No Laravel API server, PostgreSQL instance, Docker backend or VMware Linux server is required.
- Map tiles and routing remain separate provider integrations because Firebase does not provide map rendering/road-routing data. Keep privileged map/routing credentials out of the APK.
- Select Firestore/Storage locations and the Cloud Functions region deliberately, with Singapore (`asia-southeast1`) as a candidate for a Philippine launch. Verify regional support, latency and pricing before provisioning.

The previous project plan reports that the Flutter app already has Firebase Authentication and a Firestore data layer, but this Firebase-only architecture change is complete only after privileged direct writes are moved to Cloud Functions, Firestore/Storage Rules and App Check are hardened, and regression/security tests pass.

The app must remain fully functional, not static: every visible control performs a tested action and production screens use persisted Firebase results with loading, empty, validation, permission, offline and error states. Search supports all lawful physical-product categories using indexed query fields, category expansion, aliases, attributes and geohashes. Do not overstate full-text/vector search capabilities. AI outputs remain suggestions until confirmed.

The owner's 360° store tour remains app-owned. Original panoramas remain private while retryable Cloud Functions processing detects/blurs people where feasible, produces sanitized derivatives, and blocks publication on failure or uncertainty. Owners review sanitized results and may add manual masks. Do not promise perfect anonymity.

For production, configure Firebase Authentication, Firestore Rules/indexes, Cloud Functions authorization and region, App Check Play Integrity, Storage access controls, billing alerts, backups/exports, restore tests, monitoring, privacy review, security tests and controlled Android releases. Production readiness depends on security, testing, recovery and operations—not on choosing Firebase alone.
