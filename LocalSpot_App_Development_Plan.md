# LocalSpot — App Development Plan

**Philippine Local Store & Product Locator**

*Firebase-first Flutter app · Version 1.8 · Updated 4 November 2026*

**Platform:** Flutter mobile app · Firebase Authentication · Cloud Firestore · Cloud Storage  
**Development environment:** Flutter SDK + Firebase CLI + FlutterFire CLI  
**Working product name:** LocalSpot (renameable)  
**Revision focus:** The Flutter app has been fully migrated to Firebase (Authentication + Firestore + Cloud Storage). The Laravel REST API in `backend/` is retained as a reference/legacy codebase but is **no longer used by the Flutter app**. All reads and writes go directly from Flutter through `LocalSpotFirebaseApi` → Firestore Security Rules. This document reflects the completed Firebase-first Flutter architecture and the remaining production hardening items.

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
10. [Suggested API Endpoints](#10-suggested-api-endpoints)
11. [Security, Privacy and Data Quality](#11-security-privacy-and-data-quality)
12. [Development Roadmap and Milestones](#12-development-roadmap-and-milestones)
13. [Enhanced Acceptance Checklist](#13-enhanced-acceptance-checklist)
14. [Pilot Launch Strategy](#14-pilot-launch-strategy)
15. [Firebase and Docker Development Environment](#15-firebase-and-docker-development-environment)
16. [Production Readiness and Deployment](#16-production-readiness-and-deployment)
17. [Reference Documentation](#17-reference-documentation)
18. [Implementation Backlog — What to Build Next](#18-implementation-backlog--what-to-build-next)
19. [Firebase Project Setup and Migration Checklist](#19-firebase-project-setup-and-migration-checklist)

---

## 1. Executive Summary
LocalSpot is a location-based product discovery platform for the Philippines. It connects searches for products with participating physical stores and vendors near the customer. The app is for browsing, store discovery, advertising and navigation—not online ordering or delivery. The selected target architecture uses Flutter, a Laravel REST API, Firebase Authentication, Cloud Firestore and Cloud Storage.

The core audience includes sari-sari stores, market stalls, mobile street vendors, hardware stores, electronics and technology shops, appliance retailers, clothing and footwear stores, bookstores, auto-parts sellers, general-merchandise shops, supermarkets and other physical retailers. LocalSpot supports any lawful product category with a monetary value that is offered by a participating physical seller—not just food. Sellers can publish products with photos, AI-assisted suggestions and manual confirmation. Customers can search by text or picture and find participating sellers around their current location.

This revision adds a functional-completion standard: LocalSpot must be a working application, not a static visual prototype. Every visible control must trigger an action, update real app state, and call the API when necessary; relevant screens must show loading, success, empty, validation, permission and error states. The embedded 2D map, current-location marker, nearby-store pins, route preview and owner-created 360° tour remain inside LocalSpot. Third-party Street View and street-level imagery remain out of scope. Search must cover all lawful product categories sold by participating physical stores, and AI outputs remain suggestions until confirmed.

### Product goals
- Help customers find participating stores listing a product near their current or manually selected search location.
- Automatically determine the customer’s current location after permission is granted, and update the on-screen location while the map or navigation experience is active.
- Keep the map, store markers, route preview and store-tour viewer inside LocalSpot.
- Let local vendors list items without a barcode, formal inventory system or large catalog.
- Use a multi-signal AI product pipeline combining visual detection/embeddings, OCR, optional barcode lookup and catalog matching; require owner confirmation or manual encoding.
- Support fixed business locations and optional, seller-controlled live public locations for mobile vendors.
- Show prices, units and reported availability with a last-confirmed timestamp.
- Provide an embedded, owner-created 360° store tour with automatic people-privacy processing, manual blur correction and a publication gate that prevents raw/unprocessed panoramas from becoming public.

### Explicit non-goals
- No shopping cart, checkout, online payment, delivery dispatch or rider tracking.
- No assumption that every physical seller or product is included; search participating and approved listings.
- No assumption that AI knows a seller's actual price or live stock without owner input.
- No background tracking of customers by default and no continuous public tracking of vendors without an explicit, active sharing session.
- No third-party Street View or street-imagery integration in this release. The owner-created 360° store tour is the only immersive-view feature in scope.

#### Current project status
The Flutter app has been **fully migrated to Firebase**. Firebase Authentication handles all sign-in/registration. Cloud Firestore is the sole database — all stores, products, listings, promotions, tours, favorites, reports, feedback, vendor sessions and audit logs are read from and written to Firestore. The Laravel backend in `backend/` is **not used** by the Flutter app; it is retained as a legacy reference. The remaining work is production hardening: proper Firestore Security Rules refinement, geohash-based nearby queries, Cloud Storage for media, a dedicated search index for semantic/vector retrieval, and the full production operations checklist.

#### PRIMARY ENHANCEMENT GOAL
A customer can search using a product name, broad category, natural-language description or product photo, then discover relevant listings near their current or selected location. Owners can identify products with AI assistance, confirm or correct details, and publish store tours only after privacy processing and review. Every screen and interactive control must be connected to actual data and behavior; static pictures or nonfunctional buttons do not count as completed features.

## 2. Feature Scope and Priorities
This table describes the current product direction for the enhancement release. Existing functionality should be regression-tested; new items are not considered complete until their acceptance criteria pass.

| **Feature** | **Current target** | **Implementation notes** |
|---|---|---|
| Accounts and roles | Migrate identity to Firebase Authentication; retain customer, owner, staff and admin roles | Laravel validates Firebase ID tokens and reads authoritative roles from Firestore; never trust client-supplied roles. |
| Store directory and products | Store all primary application records in Cloud Firestore | Seller records in Firestore remain the source of product-location results; do not limit the catalog to food or groceries. |
| Product text search | Retain and improve current search | Support aliases, misspellings, local names and category fallback. |
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
| Semantic/category search | **Required** | Queries such as “food near me”, “tech” and “hardware” return relevant category families and nearby listings, not just literal text matches. |
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

Access control must be enforced in Laravel policies or equivalent backend authorization checks. Hiding a button in Flutter is not sufficient security.

### Store types and location modes
Support sari-sari stores, fruit and vegetable vendors, public-market stalls, street/mobile vendors, hardware stores, construction-supply shops, electronics/technology stores, appliance retailers, clothing and footwear stores, bookstores, auto/motorcycle-parts shops, general-merchandise stores, convenience stores, supermarkets and other physical sellers. Allow landmarks and barangay/city information where formal street addresses are incomplete. Product categories must cover lawful retail goods across these businesses, not food only.

- **Fixed location:** default for sari-sari stores, shops and market stalls. The owner can correct the registered pin.
- **Regular selling area:** suitable for vendors who work at a known area or on a schedule.
- **Live public location session:** an optional mode for mobile vendors. The owner explicitly starts sharing, sees that sharing is active, and can stop it. Updates stop and the public live location expires when the session ends or times out.
- **Customer location:** used on-device for map centering and passed to a backend query only when needed for nearby results or route calculation. Do not create a customer movement history by default.

## 4. Screen Inventory and Navigation
### Customer screens
| **Screen** | **Required content / action** |
|---|---|
| Home | Location-aware search, product text/camera search, categories, nearby products and sponsored placements. |
| Search results | Exact, category, semantic and visually similar product matches; distance; price/unit where supplied; availability freshness; filters/sorting; clear empty/error states. |
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
- Owner edits to products, prices, availability, promotions and tours must persist through the API and refresh affected screens after success.
- Test actual user journeys with Flutter widget/integration tests and Firestore rules/emulator tests. A clickable mockup is not a completed implementation.

Use a feature-based Flutter architecture with one consistent state-management approach (for example, Riverpod or Bloc), repositories for data access, typed request/response models and separated UI/controller logic.

## 5. Core Workflows

### A. Account registration and authentication

1. Customer/owner creates an account or signs in using Firebase Authentication from Flutter.
2. Firebase Auth returns the signed-in user and a short-lived ID token; the Firebase SDK refreshes tokens when needed.
3. Flutter sends the ID token to Laravel as a Bearer token over HTTPS.
4. Laravel verifies the token signature and claims, extracts the Firebase UID, and loads the authoritative user profile and role from Firestore.
5. If the profile does not exist, Laravel creates a minimal `users/{uid}` profile with the least-privileged default role (customer). Store-owner privileges are granted only after the store registration/verification workflow.
6. Laravel returns the LocalSpot profile, permissions and onboarding status. It does not issue a competing Sanctum token.
7. Logout signs out through Firebase Auth on the client and applies the configured server-side revocation/session policy where required.

### B. Owner registration and store publishing
1. Create an account and select the store-owner role.
2. Enter store details and select a business category.
3. Use the device location as a suggestion if permission is granted, or pin the location manually.
4. Enter barangay/city, street address where available, landmark and operating schedule.
5. Submit verification details required by the platform.
6. Publish the approved store profile and add products.

### C. AI-assisted product entry
1. Open Add Product and take a clear photo, choose an existing image, or use the optional barcode scanner.
2. If multiple objects are visible, detect/crop candidate items or ask the owner to select the product to identify.
3. Run image classification/object detection, OCR, optional barcode lookup and visual-embedding similarity search against the product catalog.
4. Combine the signals into ranked candidates. Show the suggested name, category, brand/model where supported by evidence, likely attributes, confidence or match strength, and unknown fields.
5. Let the owner choose a match, correct suggestions or manually create a product. Do not invent a brand, model, dimensions, compatibility or price when evidence is missing.
6. Display category-appropriate fields (for example apparel size/material; electronics model/capacity/compatibility; hardware dimensions/material/voltage; produce variety/selling unit).
7. Owner confirms the store-specific price, selling unit, stock/availability and listing photo.
8. Save through the API, show success or actionable errors, and refresh the catalog using persisted data.

**Important data rule:** AI suggestions are not confirmed inventory. The owner confirms product identity and store-specific values. Low-confidence or unknown matches must always have a usable manual-entry path.

### D. Customer search, discovery and navigation
1. Customer types a specific item (“Makita drill”), a broad category (“food”, “tech”, “hardware”), a need (“USB-C charger for Samsung phone”), or uses photo search.
2. The search service classifies the intent as exact product, broad category, attributes/compatibility or visual discovery. It searches product names, identifiers, aliases, category hierarchy, attributes, semantic text and visual similarity as applicable.
3. Request foreground location permission when nearby search or the map needs it. If permission is denied, use a selected map point or manually entered area.
4. Filter listings by selected radius and store status; rank by query relevance and distance, with optional price/freshness sorting.
5. Broad category queries expand the category tree: “food” includes grocery, produce, drinks and other food subcategories; “tech” includes electronics, computers, phones, peripherals and accessories; “hardware” includes tools, fasteners, plumbing/electrical supplies and building materials. Display filter chips to narrow results.
6. Show real product/store cards and map pins with category, store type, distance, supplied price/unit and last availability confirmation. Empty results provide practical alternatives such as increasing radius, clearing filters or viewing the parent category.
7. Tapping a card opens real details. Tapping Navigate opens a route preview inside LocalSpot; it does not launch another map app by default.
8. Opening a published store tour launches the interactive viewer using privacy-processed images. Third-party Street View remains out of scope.

### E. Store-tour publishing
1. Owner creates a tour for an approved store.
2. Capture or upload compatible 360° panoramas at the entrance and selected interior points.
3. Position each viewpoint on a simple tour path or store layout, then connect viewpoints with navigation arrows.
4. Preview transitions on a normal phone and correct images or links.
5. Publish after checking image privacy and content. The customer opens the tour inside LocalSpot.

### F. Customer real-time location behavior
1. Check whether device location services are enabled and request permission with a clear explanation.
2. Get an initial position and show the user-location marker on the embedded map.
3. Subscribe to location updates only while the map-follow or navigation feature is active in the foreground.
4. Keep the map centered only while the user has enabled Follow My Location; allow normal map panning without repeatedly snapping back.
5. Refresh nearby results only after a meaningful movement threshold or a deliberate refresh, with debounce/throttling to reduce battery and API usage.
6. Stop location subscriptions when the relevant screen/mode ends. If permission is denied, show a manual-location option without blocking the app.

### G. Optional live location for mobile vendors
1. An authorized owner/staff member explicitly starts a public location session.
2. The app displays a clear active-sharing indicator and the time the position was last updated.
3. During the session, send location updates at a reasonable interval or movement threshold to the authorized API.
4. Owner can stop sharing at any time. The session must also expire automatically after a configured timeout.
5. Customer map displays the reported position only while the session is active and fresh; otherwise show the regular selling area or last known location clearly labelled as stale.

### H. 360° store-tour privacy processing and publication gate
1. Owner uploads/captures the original panorama into a private, non-public staging area with status `pending_privacy_processing`.
2. A background job validates file type/size/dimensions and orientation, strips unnecessary EXIF/location metadata from public derivatives, and converts the equirectangular panorama into overlapping perspective crops or cubemap faces for detection. This reduces distortion-related misses at seams and poles.
3. Run person detection/segmentation to identify the full visible person where supported, plus face detection as an additional pass. Optionally detect license plates, documents, screens and other configured sensitive regions. Project masks back onto the source panorama and add a small safety margin before blurring/pixelating.
4. Recheck seams and poles and generate all public previews, thumbnails and viewer tiles only from the sanitized derivative. Never serve the unblurred original from a public URL.
5. Save processing status, model/version, timestamp, flags and errors. If processing fails or uncertainty is high, keep the tour unpublished and route it to manual review.
6. Let the owner inspect the sanitized preview and add manual blur regions for missed people, faces, license plates, paperwork, screens or private areas. The published version must not have a control that restores an unblurred area.
7. Publish only after required processing and review succeed. Keep originals privately restricted or delete them after a documented retention period; any replaced image must pass through the full pipeline again.

**Privacy caveat:** Automated detection is imperfect. Whole-person segmentation plus face detection is more protective than face-only blur, but still needs testing for crowded shops, people behind shelves/glass, mirrors, motion blur, distant people and panorama seams. Manual review is required before publication; never promise that AI processing guarantees anonymity.

## 6. AI Product Identification and Intelligent Search Design

LocalSpot supports **any lawful product category sold by participating physical stores**, not just food or packaged groceries. Search must understand exact products, broad categories, natural-language needs, category attributes, and image similarity. Exact text matching alone is insufficient.

### A. Owner-side photo identification pipeline

Use a staged, provider-independent workflow. A specialist retail product recognizer can be evaluated, but always retain manual entry and catalog matching if an AI provider is unavailable or cannot identify an item.

1. **Image quality and object selection:** validate image format/resolution and flag blur or poor lighting. If a photo contains multiple products, detect/crop candidate objects or ask the owner which item to identify.
2. **Visual classification/detection:** suggest the broad object or category and visible attributes (for example, drill, phone, shoe, bag of rice, pipe fitting). Treat predictions as candidates, not confirmed facts.
3. **OCR and label parsing:** extract visible brand, model number, part number, size, capacity, ingredients, product codes or other printed text.
4. **Barcode lookup where available:** use barcode identity as a strong signal but never require a barcode.
5. **Visual similarity:** create an embedding for the image/crop and compare it with reference images for products in LocalSpot's catalog. Return the closest candidates.
6. **Candidate fusion/ranking:** combine exact identifier, OCR, category, visual similarity, catalog metadata and text relevance. A clear model/part number should outrank generic visual guesses.
7. **Structured attribute suggestions:** populate only fields supported by image evidence or a trusted catalog. Unknown information remains empty or “needs confirmation”; never fabricate specifications, compatibility, safety ratings, price or stock.
8. **Owner confirmation:** owner chooses/corrects a match, fills category-specific fields, and confirms store-specific price, selling unit and availability before saving.

Exact SKU/model identification requires relevant reference data, quality images and sometimes manufacturer/barcode records. General vision AI cannot reliably identify every unbranded, locally made or visually similar item.

### B. Customer image search

Customer photo search is distinct from owner registration. It suggests one or more likely products/categories, matches them against catalog text and image embeddings, and then finds participating store listings near the customer's current or manually selected location. If the photo contains multiple items, ask the user which item to search for. Show likely/visually similar matches when uncertain rather than falsely claiming exact identity.

### C. Hybrid semantic and category search

Combine these retrieval signals:
- **Exact/keyword:** product name, brand, model, SKU/part number, barcode, aliases and category-specific fields.
- **Synonym/local-language expansion:** alternate spellings, plurals, Filipino/English names and reviewed local terms.
- **Hierarchical categories:** broad queries include descendants of a selected category.
- **Semantic text retrieval:** embeddings or a compatible semantic index match meaning when query wording differs from listing text.
- **Visual similarity:** compare customer images to catalog image embeddings.
- **Attributes/compatibility:** apply filters for size, material, capacity, voltage, device compatibility, model, condition, price and other category-specific attributes.
- **Geospatial filtering:** limit results to stores within the selected radius from the permission-granted current position or manually selected point.
- **Ranking:** combine exact identifier strength, keyword/category/semantic relevance, visual similarity, distance and listing freshness. Sponsored listings must be clearly labelled and must not masquerade as organic relevance.

Use Firestore structured queries for exact identifiers, category IDs and bounded filters. Use a dedicated derived search index for full-text, semantic/vector and visual similarity retrieval behind a `SearchProvider` interface. Firestore remains the source of truth; the search index must be rebuildable and synchronized through retryable jobs. Select the search provider based on deployment compatibility, cost and scale; do not hardwire the whole app to one AI vendor.

### D. Required query behavior

| Query | Expected behavior |
|---|---|
| `food near me` | Expand into food, grocery, drinks, fresh produce and other food subcategories; return matching participating stores within the chosen radius. |
| `tech` | Include electronics, computers, phones, peripherals and technology accessories; show useful subcategory filters. |
| `hardware` | Include hand/power tools, fasteners, plumbing/electrical supplies and building materials. |
| `USB-C charger for Samsung phone` | Prefer compatible listings only where confirmed product attributes or trustworthy catalog data support compatibility. |
| Exact model or part number | Rank exact identifier matches ahead of broad semantic/visual matches. |
| Photo of a drill | Suggest the tool category, read visible brand/model text, compare catalog images and show nearby sellers listing likely matches. |
| Photo of fruit or vegetables | Suggest produce/category matches and let the owner define variety and selling unit on listing creation. |

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
- A broad query must not only match literal words: “food” traverses food-category descendants; “tech” traverses technology categories.
- Empty results offer actions to widen radius, clear filters, select a parent category or try a suggested search.
- Label results as exact, category-based or visually similar when that distinction affects user expectations.

### G. Location-aware results and source of truth

Use `geolocator` or an equivalent maintained Flutter plugin for the initial position and foreground movement updates. Request permission when needed; allow manual area selection if denied. Keep customer coordinates transient for nearby queries by default and do not store a location-history trail.

Filter by distance, refresh only after a configured distance/time threshold or user action, and avoid sending an API request for every GPS update. LocalSpot's participating store listings are the source of product availability: recognition/search can suggest what an item is, but cannot independently know current physical stock.

### H. Evaluation and improvement loop

Build a manually reviewed test set across product categories, price-unit formats, local naming and low-quality images. Measure top-1/top-5 identification, category precision/recall, search relevance, exact model/part-number accuracy, latency, cost and failure rate. Review user/owner corrections before adding aliases or reference images. Do not silently use uploaded photos to train models without a documented lawful basis and privacy notice.

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
2. Dispatch a Laravel queued job and expose real progress states to the owner: uploading, processing, needs review, ready to publish or failed/retry.
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

### Target architecture: Flutter + Laravel + Firebase

| **Layer** | **Recommended technology** | **Responsibilities** |
|---|---|---|
| Mobile client | Flutter + Dart | Customer UI, owner UI, camera, map, GPS, 360° tours and API client. |
| Identity provider | Firebase Authentication | Account creation/sign-in, credential management, password reset and ID-token issuance. |
| Trusted backend | Laravel REST API in Docker | Verifies Firebase ID tokens; enforces roles/store ownership; owns business rules, product search coordination, inventory writes, AI workflows, moderation and publication. |
| Primary application database | Cloud Firestore (Standard edition unless requirements dictate otherwise) | All primary application records: users/profiles, roles, stores, categories, products, store listings, promotions, tour metadata, recognition jobs, location sessions and audit records. |
| Media/object storage | Cloud Storage for Firebase | Product photos, store images, private original panoramas, sanitized panorama derivatives and generated previews. Firestore stores metadata and object paths, not image bytes. |
| Search index | Dedicated search service behind a `SearchProvider` interface | Derived index for full-text, semantic and visual retrieval. Firestore remains the source of truth; index updates are asynchronous and rebuildable. |
| Image/AI services | Server-side image-understanding model, OCR, embeddings and panorama person/face detection | Product candidates, visual search embeddings and privacy-processed 360° derivatives. Secrets remain server-side. |
| Map rendering and data | MapLibre Flutter + a commercially suitable tile/style provider | In-app 2D map, store pins and route rendering. |
| Location services | Flutter `geolocator` or equivalent maintained plugin | Initial location and foreground position stream; permission handling and map-follow state. |
| Routing services | Compatible hosted or self-managed routing engine/API | In-app route geometry and ETA where supported. |
| Background jobs | Laravel queue worker + Redis/managed queue or an explicitly selected Google Cloud task/queue service | Image recognition, 360° privacy processing, search-index updates, notifications and cleanup. Do not use Laravel's database queue driver because there is no SQL database in this target architecture. |
| Deployment | Production Laravel container on Cloud Run or a secured container host | Runs Laravel API and workers with service identity and least-privilege access to Firebase/Google Cloud services. |
| CI and release checks | Git-based CI pipeline | Flutter tests, Laravel tests, Firestore rules/index checks, security checks and production image builds. |

### Request and trust boundaries

1. Flutter signs the user in through Firebase Authentication. Firebase issues an ID token.
2. Flutter sends that ID token as `Authorization: Bearer <Firebase-ID-Token>` to Laravel over HTTPS.
3. Laravel verifies the token signature and required claims, resolves the Firebase `uid`, loads the authoritative user/role record from Firestore, then authorizes the requested operation.
4. Laravel reads and writes Firestore through the Google Cloud Firestore PHP server client using IAM/Application Default Credentials.
5. Firestore is not accessed directly by Flutter for business records in this design. This avoids bypassing Laravel policies and prevents client-side role escalation.
6. For media uploads, Flutter first obtains an upload intent from Laravel, then uses Firebase Storage SDK to upload into the returned private `quarantine/{uid}/...` path under restrictive Storage Rules (authenticated UID, allowed image content types and configured size limits). Laravel verifies the Firebase ID token, the matching upload intent, store ownership and object metadata before processing. Laravel controls all processing, review and publication. Customers never receive access to raw quarantine objects.
7. Search results are generated from Firestore-backed data and a derived search index. The index is not the authoritative record store.

### Important PHP/Firebase integration decision

Google provides an official PHP client library for Cloud Firestore (`google/cloud-firestore`), and it requires the PHP gRPC extension. Install and enable that extension in the Laravel Docker image. Google does **not** list PHP among the Firebase Admin SDK's supported languages. For Firebase Authentication ID-token verification in Laravel, follow Firebase's documented third-party JWT-verification procedure with a maintained PHP JWT library: validate RS256 signature against Google's published Secure Token public keys, `kid`, `aud`, `iss`, `sub`, `exp`, `iat` and `auth_time`; cache signing keys according to their cache headers. Do not decode a JWT without verifying its signature. If full Firebase Auth user administration is later required, use the supported Identity Toolkit/Admin APIs or a small separately maintained service using an official Firebase Admin SDK, rather than pretending a PHP Admin SDK exists.

### Architecture principles

- Firestore is the single source of truth for application records. Do not keep parallel MySQL tables or duplicate authoritative records in a second database.
- Use Firebase Authentication as the sole account identity provider in the target architecture. Remove Laravel Sanctum as the mobile login/token issuer after migration; do not run two independent login systems.
- Use the Firebase Auth `uid` as the stable account identifier and the document ID for `users/{uid}`. Role and store-membership data must be written only by trusted backend/admin operations.
- Laravel remains the policy enforcement and business-logic layer. Firebase Authentication proves identity; it does not decide whether a user owns a store or may edit inventory.
- Use the official Google Cloud Firestore PHP client (`google/cloud-firestore`) with gRPC enabled. Server client libraries authenticate with Application Default Credentials (ADC) and IAM.
- Firestore server client libraries bypass Firestore Security Rules. Therefore, give the Laravel runtime a narrowly scoped service identity, keep direct client Firestore access denied unless a future feature explicitly requires it, and enforce authorization in Laravel for every request.
- Use Cloud Storage for media bytes. Keep original 360° uploads private; publish only sanitized derivatives after privacy processing and owner review.
- Use short-lived signed download URLs or another deliberately secured media-delivery method. Do not expose long-lived public URLs for private originals.
- Keep production secrets and service-account credentials out of Git, container images, Flutter assets and logs. Prefer attached service identities/workload identity in production instead of long-lived JSON keys.
- Use Firestore document schemas with explicit `schemaVersion`, timestamps, bounded document size and clear ownership. A Firestore document has a 1 MiB maximum size; never store image bytes or an entire store inventory in one document.
- Design for Firestore query limitations: denormalize fields needed for common queries, store geohash plus latitude/longitude for nearby lookup, create composite indexes, and use a search service for full-text/semantic retrieval.
- Use idempotent asynchronous jobs with retry limits, dead-letter/failed-job handling and status documents for AI processing, panorama privacy processing and search-index synchronization.
- Keep development, staging and production Firebase projects separate. Never point a development app at production data.
- Do not claim production readiness until Firebase rules, IAM, authentication verification, backups/exports, restore tests, billing alerts and service monitoring are verified.

### Deployment approach

Use Docker for Laravel and queue workers, not for the Firebase database. Local development can run the Firebase Local Emulator Suite for Authentication, Firestore and Storage, while Flutter runs natively and Laravel runs in Docker. In production, Firestore, Firebase Authentication and Cloud Storage are managed services; deploy the Laravel container with a service identity and no embedded service-account key. A managed container platform such as Cloud Run is a natural option, but a secured container host with workload identity or carefully managed credentials is also possible. Kubernetes is not required for the MVP.

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
| `searchOutbox/{eventId}` | Optional durable events for asynchronous search-index updates and retry status. Not a user-facing source of truth. |

### Firestore query and modeling rules

- Do not embed an entire inventory array in `stores/{storeId}`. Keep each listing independently queryable in `storeListings/{listingId}`.
- Store a stable `storeId`, `productId`, category IDs/ancestor IDs, geohash, latitude and longitude on each listing when this makes nearby product queries practical.
- For nearby queries, query geohash ranges, then calculate exact distance and discard false positives. Keep the result set bounded and paginated.
- Store money as integer minor units (for PHP, centavos) plus an explicit currency code; do not use binary floating point for prices.
- Use timestamps consistently (server timestamps for authoritative changes) and record `lastConfirmedAt` separately from `updatedAt`.
- Use subcollections for store memberships, stock movements and tour nodes/connections where parent ownership is meaningful. Remember that deleting a parent document does not automatically delete its subcollections; implement explicit recursive cleanup.
- Create and commit `firestore.indexes.json` and `firestore.rules` to source control. Deploy indexes/rules through CI or a documented release step.
- Define document contracts and a `schemaVersion` for records that may evolve. Use idempotent scripts/Cloud Tasks for large document migrations; do not treat Firestore as a schemaless free-for-all.
- Keep image bytes, embedding arrays of large size, and panorama derivatives out of regular profile/listing documents. Store media in Cloud Storage and store only paths/metadata in Firestore.
- The external search index is a derived copy for retrieval only. Firestore remains the source of truth; provide retry and full re-index operations.

### Data model rule

One shared product can appear in many stores. Each `storeListings` document owns its own price, selling unit, reported stock, condition and freshness timestamp. This avoids duplicating the canonical product identity for every seller while keeping store listings searchable by product and location.

## 10. Suggested API Endpoints

These are proposed route patterns for planning, not proof that routes already exist. Flutter uses Firebase Authentication to sign in and obtains a Firebase ID token. It sends that token in the HTTPS `Authorization: Bearer` header to Laravel. Laravel verifies the token, resolves the Firebase UID, loads the user's profile/roles from Firestore, and authorizes each request. Laravel then performs Firestore reads/writes with its server identity. Do not expose Firestore service credentials or privileged Cloud Storage credentials to Flutter.

| **Area** | **Example endpoint** | **Purpose** |
|---|---|---|
| Auth | `GET /api/v1/me` | Verify Firebase ID token middleware and return profile/authoritative roles from Firestore. |
| Auth | `POST /api/v1/auth/refresh-profile` | Optional endpoint to refresh account/profile state; Firebase client SDK handles ID-token refresh. |
| Auth | `POST /api/v1/auth/logout` | Revoke/record session or refresh-token revocation according to the selected Firebase Auth policy; client also signs out using Firebase Auth. |
| Stores | `POST /api/v1/stores` | Register a store after verifying Firebase UID and owner permissions. |
| Stores | `GET /api/v1/stores/nearby?lat=...&lng=...&radius_km=...` | Find nearby participating stores using Firestore geohash queries and exact-distance filtering. |
| Stores | `GET /api/v1/stores/{id}` | Get public store details. |
| Routes | `POST /api/v1/routes/preview` | Request route geometry and supported distance/ETA from the configured routing provider. |
| Vendor location | `POST /api/v1/stores/{id}/location-sessions` | Start an explicitly authorized public location-sharing session. |
| Vendor location | `PATCH /api/v1/stores/{id}/location-sessions/current` | Update the active session position; apply auth, rate limits and expiry rules. |
| Vendor location | `DELETE /api/v1/stores/{id}/location-sessions/current` | Stop the session and stop displaying the live location. |
| Products | `GET /api/v1/products/search?q=...` | Search canonical products and aliases through the configured search provider. |
| Listings | `GET /api/v1/store-listings/search?product_id=...&lat=...&lng=...` | Find nearby store listings for a product. |
| Listings | `POST /api/v1/stores/{id}/listings` | Create a store-specific listing. |
| Listings | `PATCH /api/v1/store-listings/{id}` | Update authorized price/availability details. |
| Recognition | `POST /api/v1/product-recognition/suggest` | Accept an image and return ranked vision/OCR/barcode/catalog candidates. |
| Recognition | `GET /api/v1/product-recognition/jobs/{id}` | Poll asynchronous recognition status and results. |
| Recognition | `POST /api/v1/product-recognition/{id}/confirm` | Save the owner-selected match and confirmed attributes. |
| Categories | `GET /api/v1/categories?parent_id=...` | Return taxonomy tree/children and category synonyms. |
| Search | `GET /api/v1/search?q=...&lat=...&lng=...&radius_km=...&category_id=...` | Hybrid text/category search with geospatial filtering, ranking, filters and pagination. |
| Search | `POST /api/v1/search/by-image` | Return likely/visually similar products from a customer photo. |
| Media | `POST /api/v1/media/upload-intent` | Authenticate/authorize the owner and create a Firestore upload-intent record and return a UID-scoped private quarantine path plus allowed content types/size; Flutter uploads with Firebase Storage SDK. |
| Media | `POST /api/v1/media/{id}/finalize` | Verify uploaded object metadata and enqueue recognition or privacy processing. |
| Promotions | `POST /api/v1/stores/{id}/promotions` | Create a promotion for review. |
| Tours | `POST /api/v1/stores/{id}/tours` | Create a tour. |
| Tours | `POST /api/v1/tours/{id}/media` | Create private panorama upload intent and queue privacy processing. |
| Tours | `GET /api/v1/tour-media/{id}/status` | Get upload, processing, review and publication status. |
| Tours | `POST /api/v1/tour-media/{id}/manual-blurs` | Add approved manual blur regions before publishing. |
| Tours | `POST /api/v1/tours/{id}/publish` | Publish only if all required assets have approved sanitized derivatives. |
| Tours | `POST /api/v1/tours/{id}/nodes` and `POST /api/v1/tours/{id}/connections` | Add viewpoints and connect tour nodes. |
| Moderation | `GET /api/v1/admin/reports` | Review reported content; admin only. |

### Authentication implementation note

Firebase ID tokens are short-lived and refreshed by the Firebase client SDK. Laravel must verify every presented token; it must not trust a decoded-but-unverified JWT. On sensitive actions, consider revocation/disabled-account checks and recent-authentication requirements. Use the Firebase UID as the canonical user key. Do not create a second Sanctum token system unless a separate documented client/API requirement appears.

## 11. Security, Privacy and Data Quality

### Application, identity and API security

- Use Firebase Authentication as the identity provider for the Flutter app. Laravel remains responsible for application authorization, store ownership, staff grants and business rules.
- Flutter obtains a Firebase ID token from the Firebase Auth SDK and sends it to Laravel only over HTTPS. Laravel verifies the signature and all required claims before accepting the request.
- Because Firebase's official Admin SDK does not list PHP as a supported language, implement Firebase ID-token verification in Laravel using a maintained PHP JWT library and Firebase's documented public-key/claim verification procedure, or deploy a small isolated verifier using an officially supported Admin SDK. Do not use unsigned tokens, decode-only validation or unmaintained authentication shortcuts.
- Verify `alg=RS256`, key ID (`kid`), signature, `aud` equal to the Firebase project ID, `iss` equal to `https://securetoken.google.com/<projectId>`, non-empty `sub`, `exp`, `iat` and `auth_time`. Cache Google's public signing keys according to their cache headers.
- Define an account-disabled/revocation strategy. Basic signature validation alone does not automatically detect every revoked token. For privileged actions, check the user's current Firestore status and, where required, token revocation/recent-authentication state.
- Use Firebase Auth `uid` as the stable identity key. Store roles and store memberships in Firestore and make role grants server-controlled. Never let a customer change their role by editing a client profile document.
- Firestore server client libraries authenticate with Google IAM and bypass Firestore Security Rules. Therefore, restrict the Laravel service identity to only required project resources, enforce all document-level authorization in Laravel, and deny direct Firestore reads/writes from Flutter unless a specific future feature is explicitly approved.
- Use Firebase Storage SDK uploads only into a private UID-scoped quarantine path after Laravel creates an authorized upload intent. Storage Rules enforce UID/path/type/size limits; Laravel separately verifies store ownership and object metadata before processing. Keep original panoramas private; serve approved derivatives using short-lived signed download URLs or another controlled delivery method.
- Validate coordinates, price minor units, currency, units, category IDs, URLs, query parameters, image size/type, panorama dimensions and model attributes on the server.
- Treat AI output as untrusted suggestions. Do not accept AI-generated price, stock, model compatibility, safety ratings or specifications without owner confirmation or a trusted verified catalog source.
- Apply rate limits to login-sensitive endpoints, search, image-recognition, upload-intent, media-finalize and vendor-location endpoints.
- Keep service-account keys, search keys, AI credentials and signing credentials out of Flutter, Git, container images and logs. Use workload identity/attached service accounts in production where supported; if a non-Google host requires a key, store it in a secret manager and rotate it.
- Use App Check where supported to help protect direct Firebase client services, but do not treat App Check as a replacement for authentication or Laravel authorization.
- Keep administrators and service identities least-privileged; audit sensitive account, store, promotion, inventory and media publication changes.

### Firestore rules and IAM

- Commit `firestore.rules`, `firestore.indexes.json` and `storage.rules` to version control.
- Storage Rules should permit only authenticated users to create uploads under their own `quarantine/{uid}/...` path; restrict file size and accepted image MIME types, deny reads of raw originals, and deny writes to published/sanitized paths from clients.
- In the selected architecture, normal business reads/writes go through Laravel's server client. Begin with restrictive Firestore Security Rules that deny direct client data access; do not open rules just to make the Flutter app work.
- Understand that server-side PHP Firestore client requests are authorized by Google Cloud IAM and bypass Firestore Security Rules. Use a dedicated runtime service account and grant only the required Firestore and Storage permissions.
- Separate development, staging and production Firebase projects. Never use production credentials or real customer records in the local emulator environment.
- Test role/ownership authorization in Laravel independently of Firestore Security Rules.

### Data protection, backups and recovery

- Use Firestore exports/backups and Cloud Storage object lifecycle/versioning policies appropriate to the project. Configure retention, access controls and encryption according to provider capabilities.
- Enable scheduled Firestore backups or exports where budget permits; backup, restore, point-in-time recovery and export operations may have separate charges.
- Test restoring an export into a separate non-production Firebase project. A configured backup that has never been restored is not a verified recovery plan.
- Keep Firestore in the selected region close to the Laravel runtime and primary users where practical. The Firestore database location cannot be changed after creation, so choose it deliberately before provisioning.
- Store product images and tour media in Cloud Storage, not Firestore documents. Strip unnecessary EXIF GPS metadata from public derivatives.
- Preserve private originals only for the documented retention period, then purge them through a tested scheduled job. Do not delete the only copy needed for a pending review or support case.
- Define recovery objectives: acceptable data loss and restoration time. Include re-indexing the derived search service after a restore.

### Docker and runtime security

- Use Docker Compose for local Laravel/API/worker services and Firebase Local Emulator Suite for local Firebase testing. The Emulator Suite is for development and CI, not production hosting.
- Build and test a production-specific Laravel image; do not deploy development tooling or debug settings unchanged.
- Use `.dockerignore`, multi-stage builds, pinned maintained base images, non-root runtime where supported and dependency/image vulnerability scans.
- Install and enable the PHP gRPC extension required by the official Firestore PHP client in the Laravel image.
- Do not put a service-account JSON key in the image or repository. Use ADC locally and an attached service identity/workload identity in production where possible.
- Keep application code immutable in production; do not bind-mount the source tree.
- Expose only the HTTPS API ingress publicly. Firestore and Cloud Storage are reached through Google APIs using IAM/signed URLs; do not expose an unnecessary database port.
- Configure health checks, restart behavior, resource limits, log collection and safe shutdown. Run Laravel queue workers as separate processes/services.
- Do not store application data in an unbacked container filesystem. Firebase managed services hold persistent records/media.

### Privacy requirements

- Request customer GPS permission only when it improves nearby search or navigation; manual location selection remains available.
- Do not continuously track mobile vendors by default; require an explicit active sharing session, clear indicator, stop control and automatic expiry.
- Customer location is foreground-only by default. Do not request background-location permission for the initial release and do not retain raw customer movement history by default.
- Require automatic privacy processing and owner review before any 360° image is published. Use person segmentation plus face detection where feasible, provide manual correction and block publication if processing fails.
- Keep unblurred originals private with restricted access and documented retention/deletion. Public viewer images, thumbnails and tiles must come only from sanitized derivatives.
- Test automatic blur at panorama seams/poles, reflections, occlusion, low light and distant-person cases. Manual review remains mandatory; do not promise perfect anonymity.
- Explain how uploaded images are processed, whether external AI services receive them, and how long originals/derivatives are retained.
- Avoid collecting or retaining personal information unnecessary for store discovery and app operation.

### Data freshness and trust

- Track listing status and `lastConfirmedAt`.
- Let owners quickly mark a product unavailable or update its stock information.
- Show price units clearly (for example, per kilo, per piece, per pack, per meter or per item).
- Distinguish an owner-listed product from a recently confirmed available product.
- Distinguish a fixed store pin from a mobile vendor's active or stale live location.
- Let customers report a wrong location, price or listing.
- Do not claim that a vendor has an item in stock if the system has no reliable recent confirmation.

## 12. Development Roadmap and Milestones

### Status of the original six phases

The original six phases are complete on the Firebase-first Flutter architecture. The Firebase migration of the Flutter app is **done** — all API calls go through `LocalSpotFirebaseApi` and Firestore. Remaining work is production hardening.

| **Status** | **Scope** | **Action** |
|---|---|---|
| ✅ Phases 1–6 | Foundation, locator, inventory/photo scan, advertising/tours, search, pilot baseline | Complete on Firebase architecture. |
| ✅ Firebase migration 1 | Firebase project, Authentication, Firestore, Security Rules | Done — `capstone-project-561a2` configured; rules deployed; seeder script run. |
| ✅ Firebase migration 2 | Flutter uses Firebase directly | `LocalSpotFirebaseApi` handles all 39 API paths. No Laravel dependency in Flutter. |
| ✅ Firebase migration 3 | Demo data seeded to Firestore | `scripts/seed_firestore.js` seeds 7 stores, 12 products, 15 listings, 7 auth accounts. |
| ⬜ Firebase migration 4 | Cloud Storage for media | Product photos and panoramas still use external URLs. Upload-to-Storage not yet wired. |
| ⬜ Firebase migration 5 | Geohash nearby queries + search index | Currently uses in-app Haversine distance filter. No geohash index or vector search yet. |
| ⬜ Firebase migration 6 | Production ops | Rules hardening, backups, monitoring, CI full pass, billing alerts. |

### Recommended migration sequence

1. Inventory the existing MySQL schema, Laravel models, queries, migrations, Sanctum authentication, file paths, jobs and tests. Freeze schema changes during the migration window.
2. Create a Firebase development project and configure Auth, Firestore, Storage and Emulator Suite. Do not start with production data.
3. Finalize Firestore collection/document design, query/index requirements, Security Rules and IAM roles before importing records.
4. Add the Firestore PHP client and gRPC extension to Laravel's container. Implement repository interfaces so the rest of the business logic is not tightly coupled to raw Firestore calls.
5. Integrate Firebase Authentication: Flutter signs in with Firebase; Laravel verifies ID tokens and resolves the UID; remove Sanctum as the primary identity flow only after end-to-end tests pass.
6. Write idempotent export/transform/import scripts for stores, products, listings, categories, roles, promotions, tours, reports and audit records. Validate counts, references, amounts, coordinates and ownership.
7. Plan account migration separately. Do not assume existing Laravel password hashes can be imported unchanged. Confirm whether the current hash algorithm is supported by Firebase Auth import; otherwise use a secure staged reauthentication/password-reset process.
8. Migrate media to Cloud Storage using private staging paths. Verify original/sanitized relationships, signed access, metadata stripping, privacy-processing status and retention jobs.
9. Replace SQL full-text and geospatial queries. Use Firestore geohashes for bounded nearby lookup and an external derived search index for full-text/semantic/visual retrieval.
10. Configure queue/cache infrastructure without a SQL database driver. Test image jobs, privacy jobs, search-index retries and scheduled cleanup.
11. Run parity tests against the old and new backends with a controlled dataset. Check category search, product search, nearby listings, ownership policies, inventory writes, promotion moderation and tour publication.
12. Run a staging cutover rehearsal and restore drill. Keep the old MySQL database read-only and backed up until the rollback window has closed.
13. Cut over production only after a documented approval. Monitor errors, read/write costs, storage traffic, search latency and failed jobs closely.

## 13. Enhanced Acceptance Checklist

### Functional and product requirements
- ☐ A vendor can register/sign in, register a store, set a location and publish approved listings.
- ☐ The system supports all lawful retail product categories, including food, hardware, tools, electronics, technology, appliances, clothing, household goods, auto parts and other physical merchandise.
- ☐ Photo-assisted product entry returns AI/OCR/catalog suggestions and requires owner confirmation or manual encoding.
- ☐ Customers can search by exact name, broad category, natural-language need or image and see participating sellers near the selected location.
- ☐ Broad queries such as “food”, “tech” and “hardware” expand to the correct category descendants.
- ☐ Customers can select a search radius and filter by business type, price, availability and relevant attributes.
- ☐ The in-app 2D map shows the correct registered store and provides an in-app route preview.
- ☐ Store-specific prices, units and availability timestamps are displayed accurately when provided.
- ☐ An owner can publish a connected 360° tour only after privacy processing and review; customers can navigate sanitized viewpoints.
- ☐ Every visible button, category chip, card, map pin, filter, camera control, form action and tour arrow triggers a tested behavior; no inert controls remain.
- ☐ Production screens load persisted API data rather than hardcoded demo records; demo fixtures are limited to development/tests.
- ☐ Relevant screens show loading, empty, validation, permission-denied, stale-data and recoverable-error states.

### Firebase identity, database and media
- ☐ Firebase Authentication is the only primary customer/owner identity provider; no duplicate Sanctum login flow remains.
- ☐ Flutter sends Firebase ID tokens to Laravel over HTTPS; Laravel verifies signature and required claims before handling protected requests.
- ☐ Firebase UID is the canonical account identifier and maps to `users/{uid}` in Firestore.
- ☐ Store roles and memberships are server-managed; clients cannot self-assign owner/admin permissions.
- ☐ Laravel reads/writes Firestore through IAM using the PHP Firestore client; service credentials are not embedded in Flutter or Docker images.
- ☐ Firestore client access is denied by default when Flutter is not intended to access business documents directly.
- ☐ Firestore document sizes remain below the hard 1 MiB limit; image bytes are stored in Cloud Storage, not documents.
- ☐ `firestore.rules`, `firestore.indexes.json` and document schema contracts are version-controlled and deployed/tested.
- ☐ Nearby queries use bounded geohash ranges plus exact-distance filtering; pagination and composite indexes are tested.
- ☐ Search indexes are derived/rebuildable; Firestore is the source of truth and failed index updates can be retried.
- ☐ Cloud Storage originals are private; Laravel authorizes upload intents, Storage Rules restrict quarantine uploads, and only approved sanitized derivatives receive controlled download access.
- ☐ Public 360° assets are sanitized derivatives only; failed/uncertain privacy processing blocks publication.
- ☐ Firestore exports/backups and Cloud Storage recovery procedures are configured; a restore has been tested in a separate environment.

### Docker, operations and production readiness
- ☐ Docker runs Laravel and queue/cache services without a MySQL container in the target Firebase architecture.
- ☐ Laravel's production image includes a supported PHP gRPC extension and the required Google Cloud PHP client dependencies.
- ☐ Development uses Firebase Local Emulator Suite; production never points to emulator endpoints.
- ☐ Separate development, staging and production Firebase projects/credentials are configured.
- ☐ CI runs Flutter format/analyze/tests, Laravel tests, token-verification tests, Firestore rules/index tests and container build checks.
- ☐ Production is served over HTTPS; Firebase service identities use least privilege; secrets are outside source control and images.
- ☐ Firestore/Storage usage, search service, AI inference, outbound traffic and billing are monitored with budgets/alerts.
- ☐ Queue workers, failed-job alerts, health checks, logs and error reporting are configured.
- ☐ There is a documented release, backup/restore and rollback procedure for the MySQL-to-Firestore cutover.
- ☐ The old MySQL database is retained read-only and backed up until migration verification and rollback period are complete.

### Primary risks and mitigations
| **Risk** | **Mitigation** |
|---|---|
| MySQL-to-Firestore data mismatch | Idempotent conversion, stable IDs, count/reference checks, dual-run comparison in staging and rollback backup. |
| Existing passwords cannot be imported directly | Verify hash compatibility; otherwise use staged reauthentication/password reset. |
| Firestore read/write cost growth | Bound query results, paginate, avoid listener fan-out, denormalize intentionally, monitor operation counts and set billing alerts. |
| Firestore query limitations | Create composite indexes, geohash queries and a dedicated derived search index for advanced text/semantic search. |
| Laravel token verification bug | Follow Firebase's documented JWT verification claims/key rotation; test invalid, expired, wrong-project and revoked/disabled accounts. |
| Excessive server privileges | Dedicated service account, least-privilege IAM, audit logs and no service-account key in source/images. |
| Cloud Storage overuse or exposure | Private staging, short-lived signed URLs, image limits, lifecycle rules and storage/bandwidth alerts. |
| AI misidentifies products | Present ranked suggestions only; owner confirms; retain manual creation and category fallbacks. |
| Panorama blur misses people | Panorama-aware segmentation, manual review/masks, blocked publication on failure and no anonymity guarantee. |
| Queue outage or delayed processing | Durable queue, idempotency, bounded retries, failed-job monitoring and reprocessing tools. |

## 14. Pilot Launch Strategy
1. Choose one pilot municipality or compact service area before attempting a nationwide launch.
2. Recruit a balanced set of sellers across product categories, including sari-sari stores, market stalls, hardware shops, electronics/technology retailers, household-goods stores and larger retailers.
3. Help sellers list their most commonly requested products first rather than demanding complete inventories.
4. Test real local product searches, alternate names, misspellings and units.
5. Test GPS permission granted/denied, approximate location, weak GPS, indoor/urban positioning, movement refresh, route preview and manual-location fallback on real target phones.
6. Validate 2D map and route coverage and confirm the selected providers' attribution, commercial-use terms, quotas and pricing. Test owner-created 360° tours on target devices.
7. Measure failed searches, stale listings, wrong-location reports, location-fix success, routing errors, app responsiveness and vendor live-session correctness.
8. Use pilot feedback to refine seller onboarding and then expand to nearby areas.

## 15. Firebase and Docker Development Environment

### Decision

Use Firebase for managed identity, records and media; use Docker for the Laravel API and background workers. XAMPP and MySQL are not required by the target architecture.

- Flutter runs natively on Windows/Android Studio.
- Laravel runs in Docker Desktop with WSL 2.
- Firebase Authentication, Firestore and Storage run as managed cloud services in development/staging/production.
- Firebase Local Emulator Suite provides local test endpoints for Authentication, Firestore and Storage.
- The Laravel container needs the PHP gRPC extension and Composer packages for Firestore/Storage clients.
- Do not include a MySQL service in the target Docker Compose file unless a temporary migration tool or unrelated project specifically needs it.

### Suggested repository layout

```text
LocalSpot/
├── mobile/                         # Flutter app
│   ├── lib/
│   └── firebase_options.dart       # Generated Firebase identifiers; no server secrets
├── backend/                        # Laravel REST API/admin
│   ├── app/
│   ├── routes/
│   ├── config/
│   ├── tests/
│   ├── compose.yaml                # Laravel API + worker + Redis if selected
│   ├── .env                        # Local settings; never commit
│   └── .env.example                # Safe template
├── firebase/
│   ├── firestore.rules
│   ├── firestore.indexes.json
│   ├── storage.rules               # Strict UID-scoped quarantine upload rules
│   └── firebase.json
└── scripts/
    └── mysql-to-firestore/         # Temporary, idempotent migration/import tools
```

### Required local tools

1. Flutter SDK and Android Studio/Android SDK.
2. Docker Desktop for Windows with WSL 2 backend.
3. Node.js LTS and npm for Firebase CLI and Emulator Suite.
4. Java JDK 21 or the version required by the current Emulator Suite release.
5. Firebase CLI (`firebase-tools`).
6. FlutterFire CLI (`flutterfire_cli`).
7. Google Cloud CLI (`gcloud`) for local Application Default Credentials when Laravel's PHP Firestore client needs server credentials.
8. Composer dependencies in Laravel: `google/cloud-firestore` (official PHP client; requires gRPC) and `google/cloud-storage` for server-side object processing/short-lived signed download URLs.
9. A maintained PHP JWT library for Firebase ID-token verification. Implement Firebase's published verification procedure; do not assume an official Firebase Admin SDK for PHP exists.

### Flutter packages

The app currently uses direct Firebase SDK packages — no `dio` or HTTP client for a backend API:

```powershell
flutter pub add firebase_core
flutter pub add firebase_auth
flutter pub add cloud_firestore
flutter pub add firebase_storage
```

- `firebase_core`: initializes Firebase.
- `firebase_auth`: user sign-in, registration, logout and ID-token management.
- `cloud_firestore`: all application reads and writes go directly from Flutter to Firestore.
- `firebase_storage`: authenticated uploads into private Storage paths (to be wired in Wave 1).

Additional packages already in use:
```powershell
flutter pub add geolocator
flutter pub add maplibre_gl
flutter pub add image_picker
flutter pub add url_launcher
```

Optional future integrations:
```powershell
flutter pub add firebase_messaging
flutter pub add firebase_crashlytics
flutter pub add firebase_analytics
```
Use these only if push notifications, crash reporting and analytics are in scope.

### Configure Firebase in Flutter

From the Flutter app directory:

```powershell
npm install -g firebase-tools
firebase login

dart pub global activate flutterfire_cli

flutter pub add firebase_core firebase_auth firebase_storage
flutterfire configure
```

Select the LocalSpot Firebase development project and register the Android app using the exact `applicationId` from `android/app/build.gradle` or `build.gradle.kts`. Select iOS only when its bundle identifier is ready. `flutterfire configure` generates `lib/firebase_options.dart`. Initialize Firebase before `runApp` in `main.dart`. Re-run `flutterfire configure` when adding platforms or Firebase products that require configuration updates.

### Configure Firebase Local Emulator Suite

From the repository/Firebase configuration directory:

```powershell
firebase init
firebase init emulators
```

Select Authentication, Firestore and Storage emulators (and Functions only if used). Keep `firebase.json`, `firestore.rules`, `firestore.indexes.json` and Storage rules in source control.

Start emulators for local work:

```powershell
firebase emulators:start --only auth,firestore,storage
```

The Emulator Suite uses local Node/Java processes and is for development/CI only; it is not a production database or a self-hosted Firebase replacement. Configure Flutter and Laravel separately to use emulator hosts. On an Android emulator, the host computer is normally reached through `10.0.2.2`; inside a Docker container, use a reachable host/service name such as `host.docker.internal` where supported, not the container's own `127.0.0.1`. The Flutter Firebase Storage SDK can use the Storage emulator; for Laravel's Google Cloud Storage PHP client, confirm emulator API compatibility or use a separate isolated development bucket with test data. Keep emulator flags and unsigned test-token acceptance strictly limited to local/test environments.

### Laravel Firebase dependencies and credentials

In the Laravel backend (inside the container build environment):

```bash
composer require google/cloud-firestore
composer require google/cloud-storage
```

Install and enable the PHP `grpc` extension in the Laravel image before using the Firestore PHP client. Use Composer and the official Google Cloud PHP libraries. For local development, configure Application Default Credentials (`gcloud auth application-default login`) or a dedicated development service account; never commit the JSON credential file. In production, prefer an attached service account/workload identity and least-privilege IAM rather than a long-lived downloaded key.

Example local environment variables (names are illustrative; use config/services.php and the actual deployment environment):

```dotenv
FIREBASE_PROJECT_ID=your-localspot-dev-project
FIRESTORE_EMULATOR_HOST=host.docker.internal:8080
FIREBASE_AUTH_EMULATOR_HOST=host.docker.internal:9099
FIREBASE_STORAGE_EMULATOR_HOST=host.docker.internal:9199
GOOGLE_CLOUD_PROJECT=your-localspot-dev-project
```

Do not put a service-account private key or JSON contents in `.env`, Git, Flutter assets or a Docker image. If a local client library requires a credential file, store it outside the repository and reference it through ADC/environment configuration. Production must not set emulator host variables.

### Typical local workflow

```bash
# Start Firebase emulators in a separate terminal
firebase emulators:start --only auth,firestore,storage

# Start Laravel API and its worker(s) from the WSL/Linux terminal
docker compose up -d --build

# Run Laravel checks inside the API container (adjust service name)
docker compose exec app php artisan test

# View Laravel logs
docker compose logs -f app worker

# Stop the Laravel containers without deleting persistent emulator/export data
docker compose stop
```

Laravel may use Redis for cache and queue jobs; if so, add a Redis service locally and use managed Redis or another durable queue provider in production. Do not configure Laravel's database queue/cache/session drivers to depend on MySQL after the migration. Keep the API stateless where practical; store operational cache/queue state in the selected service.

### Data persistence warning

Use Emulator Suite export/import for repeatable local test data. Emulator state is separate from production Firebase. Never run a production import/export, delete or cleanup command against the wrong project. Confirm the active Firebase project with `firebase use` and verify the project ID before running destructive operations.

## 16. Production Readiness and Deployment

### Recommended production deployment

Deploy the Laravel API and queue workers as production containers (Cloud Run is a natural Google Cloud option; a secured container host is also possible). Use managed Firebase Authentication, Cloud Firestore and Cloud Storage. Do not deploy Emulator Suite as a production service. Kubernetes and microservices are not required for the initial release.

### Development, staging and production separation

| **Environment** | **Purpose** | **Configuration rules** |
|---|---|---|
| Development | Daily feature work | Separate Firebase dev project, Emulator Suite, test users/data, local ADC and development AI/search keys. |
| Staging | Rehearse imports, releases and integrations | Separate Firebase project, production-like rules/indexes, test data, restricted service identity and independent billing alerts. |
| Production | Real vendors and customers | Production Firebase project, HTTPS, locked-down rules/IAM, service identity, backups/exports, monitoring, budget alerts and controlled releases. |

Use separate Firebase projects for development, staging and production. Do not use the same Firestore database with a client-side environment flag as the only separation. Do not copy production personal data into development by default.

### Firebase Authentication production requirements

- Enable only the sign-in providers actually supported by LocalSpot (for example email/password first; add phone/Google only after product and abuse requirements are decided).
- Configure password policy, email verification where required, account recovery, abuse protection and appropriate sign-in rate limits.
- Firebase Auth UID is the canonical identity. Create/update `users/{uid}` through trusted backend workflows.
- Flutter obtains ID tokens using Firebase Auth SDK and passes them to Laravel over HTTPS. Laravel validates signature and claims and then checks the account status/roles in Firestore.
- Define how disabled/deleted users and revoked refresh tokens are recognized. For high-risk endpoints, require recent sign-in and current account status.
- Keep role assignment, store ownership and staff membership server-controlled. A Firebase Auth account alone does not grant a store-owner role.
- Do not retain Laravel Sanctum tokens as a parallel app login scheme after Firebase Auth cutover unless a separate technical requirement has been documented.

### Firestore production requirements

- Choose the Firestore location before creating the production database. The location cannot be changed later. Evaluate `asia-southeast1` (Singapore) for Philippine users and place the Laravel runtime and related Google Cloud resources near the database where practical; confirm latency, feature availability and price before provisioning.
- Use the Standard edition unless a documented feature/scale requirement justifies another edition.
- Commit and deploy `firestore.rules` and `firestore.indexes.json`; test rules and every important query in the Emulator Suite.
- Give the Laravel runtime service account only the Firestore permissions it needs. Firestore server client libraries bypass Security Rules, so authorization in Laravel is mandatory.
- Use bounded queries, pagination, denormalized query fields, geohashes and exact-distance filtering. Avoid unbounded listeners and read amplification.
- Do not store binary images, panorama data or huge embedding arrays in documents. Keep documents comfortably below Firestore's 1 MiB hard maximum.
- Add document schema versioning and idempotent scripts for evolving document shapes.
- Monitor reads, writes, deletes, stored bytes, index usage, outbound transfer and high-cost query patterns.

### Cloud Storage production requirements

- Cloud Storage for Firebase requires the Blaze pay-as-you-go plan for new/default bucket provisioning and continued access under the current published policy. No-cost allowances may still apply, but usage above them is billable.
- Select a bucket location deliberately and keep it close to Firestore/Laravel where practical. Confirm the pricing region and data-residency requirements.
- Flutter uploads only to private UID-scoped quarantine paths through Firebase Storage SDK. Storage Rules restrict authenticated UID, allowed image MIME types and file sizes; client reads of originals and client writes to published/sanitized paths are denied.
- Laravel verifies the authorized upload intent, object path, owner/store association and uploaded metadata before processing. It creates sanitized derivatives and may issue short-lived signed download URLs only for approved public derivatives.
- Only sanitized 360° images and approved product images may be exposed to customers. Private originals must never be returned in public API responses.
- Set storage lifecycle and retention rules for originals, failed uploads and orphaned derivatives. Test deletion and restore procedures.
- Monitor storage GB-months, downloads, requests, egress and panorama-viewer bandwidth; optimize image sizes and create appropriate previews/tiles.

### Search and background processing

- Firestore is the source of truth; an external search engine is a derived index. Use reliable asynchronous updates, retries, periodic reconciliation and full re-index tooling.
- Choose the search provider based on full-text, semantic/vector, visual search, Philippine-region latency, price, scale and operational support. Keep it behind a `SearchProvider` interface.
- Use a durable queue/worker system for recognition, panorama privacy processing, search indexing and scheduled cleanup. Do not use Laravel's SQL database queue driver.
- Jobs must be idempotent, observable, retry-bounded and safely resumable. Failed privacy jobs must never publish raw originals.
- Keep model/provider credentials server-side and implement timeouts, rate limits, quotas and cost controls.

### Production container and identity requirements

- Build a production-specific Laravel image with multi-stage build, maintained/pinned base images, `.dockerignore`, dependency scanning and non-root runtime where supported.
- Include the required PHP gRPC extension and Google Cloud PHP libraries in the runtime image.
- Do not include `.env`, local Firebase emulator data, credentials or service-account JSON in image layers.
- Prefer Cloud Run service identity or another workload-identity mechanism. If the host is outside Google Cloud and cannot use federation, store a narrowly scoped service-account key in a secret manager, rotate it and never commit it.
- Set `APP_ENV=production`, `APP_DEBUG=false`, trusted HTTPS/proxy settings and secure CORS/origin policies.
- Expose only the HTTPS API ingress. Firestore and Cloud Storage uploads should use restricted client quarantine rules and server IAM; sanitized downloads may use signed URLs; do not expose emulator ports or local admin consoles.
- Configure health checks, resource limits, graceful shutdown, structured logs, uptime monitoring and error alerts.
- Run controlled release steps; do not perform destructive data import or cleanup automatically on every container startup.

### CI/CD, backup and recovery

1. Run Flutter formatting, static analysis and unit/widget/integration tests.
2. Run Laravel unit/feature/authorization/token-verification/Firestore-repository tests.
3. Run Firebase Emulator Suite tests for Auth, Firestore rules, query behavior and Storage rules/flows.
4. Validate Firestore indexes/rules and build/scan the production image.
5. Deploy to staging, run smoke tests, verify Firebase Auth login, nearby search, uploads, AI jobs and tour publication.
6. Back up/export Firestore and relevant Cloud Storage objects before risky data changes/cutover.
7. Deploy a versioned Laravel image and perform health checks; keep a rollback path and a verified restore procedure.

Configure scheduled Firestore backups/exports as appropriate. Firestore backup, restore, PITR and export operations may have separate charges; verify current pricing. Test restoring data into a separate Firebase project. Also preserve object-storage recovery/versioning for media.

### Cost and quota controls

- Firestore free quota is limited and usage beyond it is billed. Current published Standard-edition free quota for one database per project is 1 GiB stored data, 50,000 document reads/day, 20,000 writes/day, 20,000 deletes/day and 10 GiB/month outbound transfer. Recheck current regional pricing before launch.
- Firestore charges depend on document reads/writes/deletes, index-entry reads, storage and network bandwidth. A broad category or nearby search that reads too many documents can become expensive.
- Cloud Storage for Firebase requires the Blaze plan for new/default buckets under the current policy; storage, operations and downloads are billed under the selected bucket's pricing.
- Firebase budgets and alerts are monitoring tools, not guaranteed hard spend caps. Set quotas where available and monitor all linked Google Cloud services.
- Track cost per active user, search, AI recognition, panorama upload and panorama view; use pagination, caching, image optimization and request throttling.

### Production launch gate

Do not call LocalSpot production-ready until Firebase Authentication verification, Firestore IAM/rules/indexes, Cloud Storage access controls, search-index recovery, panorama privacy publication gate, backups/restores, billing alerts, queue monitoring, security tests and a documented rollback/cutover have all passed.

## 17. Reference Documentation

Check current official documentation and pricing during implementation because Firebase products, quotas and billing can change.

- **Firebase for Flutter setup:** https://firebase.google.com/docs/flutter/setup
- **Firebase Authentication for Flutter:** https://firebase.google.com/docs/auth/flutter/start
- **Firebase Authentication — verify ID tokens:** https://firebase.google.com/docs/auth/admin/verify-id-tokens
- **Firebase Admin SDK supported languages:** https://firebase.google.com/docs/admin/setup
- **Cloud Firestore PHP client:** https://docs.cloud.google.com/php/docs/reference/cloud-firestore/latest
- **Firestore server-client quickstart (PHP, gRPC, ADC):** https://firebase.google.com/docs/firestore/quickstart-server
- **Firestore quotas and limits:** https://firebase.google.com/docs/firestore/quotas
- **Firestore pricing:** https://firebase.google.com/docs/firestore/pricing
- **Firestore locations:** https://firebase.google.com/docs/firestore/locations
- **Firestore security rules:** https://firebase.google.com/docs/firestore/security/get-started
- **Firestore index management:** https://firebase.google.com/docs/firestore/query-data/indexing
- **Cloud Storage for Firebase:** https://firebase.google.com/docs/storage
- **Cloud Storage for Firebase billing requirements:** https://firebase.google.com/docs/storage/faqs-storage-changes-announced-sept-2024
- **Cloud Storage signed URLs and access:** https://cloud.google.com/storage/docs/access-control/signed-urls
- **Firebase Local Emulator Suite:** https://firebase.google.com/docs/emulator-suite
- **Emulator Suite install/configure:** https://firebase.google.com/docs/emulator-suite/install_and_configure
- **Firebase CLI reference:** https://firebase.google.com/docs/cli
- **FlutterFire CLI:** https://firebase.google.com/docs/flutter/setup
- **Google Cloud Application Default Credentials:** https://cloud.google.com/docs/authentication/application-default-credentials
- **Google Cloud PHP authentication:** https://docs.cloud.google.com/php/docs/reference/help/authentication
- **Firebase Cloud Messaging:** https://firebase.google.com/docs/cloud-messaging/flutter/client
- **Firebase Crashlytics for Flutter:** https://firebase.google.com/docs/crashlytics/flutter/get-started
- **Firebase Analytics for Flutter:** https://firebase.google.com/docs/analytics/get-started?platform=flutter
- **Firebase App Check:** https://firebase.google.com/docs/app-check
- **Laravel documentation:** https://laravel.com/docs
- **Laravel queues:** https://laravel.com/docs/queues
- **Docker Compose in production:** https://docs.docker.com/compose/how-tos/production/
- **Docker build best practices:** https://docs.docker.com/build/building/best-practices/
- **Docker Desktop for Windows:** https://docs.docker.com/desktop/setup/install/windows-install/
- **Flutter architecture guide:** https://docs.flutter.dev/app-architecture/guide
- **MapLibre for Flutter:** https://pub.dev/packages/maplibre
- **Flutter Geolocator:** https://pub.dev/packages/geolocator
- **OpenStreetMap tile usage policy:** https://operations.osmfoundation.org/policies/tiles/

## 18. Implementation Backlog — What to Build Next
## 18. Implementation Backlog — What to Build Next

Use this section as the working queue. Items marked ✅ are complete in the current Flutter codebase. Items marked ⬜ are next priorities.

### Already complete in the current Firebase Flutter codebase

| Area | Status | Notes |
|---|---|---|
| Firebase Authentication | ✅ | Email/Password sign-in, register, logout, session persistence. |
| Firestore catalog reads | ✅ | All 13 collections: stores, products, listings, promotions, tours, users, storeMembers, favorites, reports, feedback, vendorSessions, stockMovements, auditLogs. |
| Firestore writes | ✅ | Store register, listing add/edit/archive, promotion, tour, staff invite, vendor session, report, feedback, favorites, audit log. |
| Firebase search | ✅ | Keyword + category expansion (food/tech/hardware), seller-type filter, radius filter, sort by match-type then distance. |
| Product recognition | ✅ | Keyword/alias/barcode catalog scoring; owner confirmation required; no external vision API. |
| Route preview | ✅ | Straight-line Haversine fallback; handled in-app. |
| Firestore Security Rules | ✅ | Public read for catalog collections; authenticated writes; deployed. |
| Firestore indexes | ✅ | Composite indexes for listings, storeMembers, stockMovements, favorites, vendorSessions deployed. |
| Demo seeder | ✅ | `scripts/seed_firestore.js` — 7 auth accounts (password: `demo1234`), 7 stores, 12 products, 15 listings. |
| Android back navigation | ✅ | `PopScope` with overlay/tab/exit logic. |
| Roles and access control | ✅ | Customer, owner, staff, admin; inventory/promotion/location grants enforced. |
| Catalog and search UI | ✅ | Category chips, search retry, overflow fix, load more, debounce, cancel stale. |
| Map and location | ✅ | MapLibre in-app, GPS permission, follow-my-location, nearby refresh, route drawn on map. |
| Owner inventory | ✅ | Photo suggestion, confirm, category attributes, archive, stock history writes to Firestore. |
| Tours | ✅ | Process → review → publish gate; private originals; manual blur; Firestore-persisted. |
| Admin | ✅ | Store/promo/report/feedback review; audit log; Firestore writes. |
| Smoke tests | ✅ | 20 tests pass in CI. |

### Wave 1 — Cloud Storage for media (next priority)

1. ⬜ Wire `Add Product` photo upload to Firebase Storage (`products/{productId}/image.jpg`).
2. ⬜ Wire tour panorama upload to private Storage path (`tours/originals/{uid}/{nodeId}.jpg`).
3. ⬜ Wire store image upload for store registration and profile editing.
4. ⬜ Add upload-intent flow in `firebase_api.dart` — return a Storage path; upload using `firebase_storage` SDK; show progress.
5. ⬜ Replace external Unsplash placeholder URLs in seeder with real Storage uploads for production data.

### Wave 2 — Search quality and geohash

1. ⬜ Add `geohash` field to store and listing documents; update seeder and store-register write.
2. ⬜ Replace Haversine in-app filter with Firestore geohash range query in search and nearby endpoints.
3. ⬜ Evaluate a dedicated full-text search service (Algolia/Typesense via Firebase Extension or Cloud Function) as catalog grows.

### Wave 3 — 360° privacy processing (required before public tours)

1. ⬜ Replace URL-based panorama placeholder with real Cloud Storage upload + processing job.
2. ⬜ Implement actual person/face detection via a server-side worker (Cloud Function or external API).
3. ⬜ Write sanitized derivative to a public Storage path and update the Firestore node document.
4. ⬜ Block publication if processing has not succeeded — the gate exists in code; the ML pipeline is not yet wired.

### Wave 4 — Production operations

1. ⬜ Create separate staging and production Firebase projects.
2. ⬜ Configure Firestore scheduled backups/exports.
3. ⬜ Set Firebase billing budget alerts.
4. ⬜ Add Firebase Crashlytics and Analytics.
5. ⬜ Harden Firestore Security Rules — restrict direct Flutter writes to sensitive collections.
6. ⬜ CI: add Firestore rules emulator test step.
7. ⬜ Documented rollback and recovery procedure.

### Out of scope (do not implement)

- Cart, checkout, payments, delivery and rider tracking.
- Third-party Street View / Mapillary / KartaView / Panoramax.
- Laravel Sanctum as a login system (removed).
- MySQL as a production database (removed).
- Background tracking of customers.
- Nationwide coverage claims; participating sellers only.

## 19. Firebase Project Setup and Migration Checklist

This section is the practical setup order. Complete development project setup first; create production resources only after region, security, cost and migration design have been reviewed.

### A. Accounts and installations on the developer PC

1. Use a Google account with access to Google Cloud/Firebase.
2. Create a Firebase project in the Firebase Console: https://console.firebase.google.com/
3. Install Node.js LTS and npm.
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
6. Install Google Cloud CLI and configure local Application Default Credentials:
   ```powershell
   gcloud auth application-default login
   ```
7. Keep Docker Desktop + WSL 2 for Laravel. No XAMPP or local MySQL server is required by the target Firebase architecture.

### B. Create the Firebase development project

1. In Firebase Console, create `LocalSpot-Development` (use a unique project ID).
2. Add the Android app using the exact Android `applicationId`; add iOS later using its exact bundle identifier if needed.
3. Enable Firebase Authentication and initially configure only the chosen providers (for example Email/Password). Test account creation, email verification, sign-in, password reset and sign-out.
4. Create Cloud Firestore in **Native mode** and choose the region deliberately. `asia-southeast1` (Singapore) is a candidate for a Philippine pilot; verify supported features, latency and price before creation. A Firestore database's location cannot be changed later.
5. Create the Cloud Storage bucket. Current Firebase policy requires the Blaze pay-as-you-go plan to provision/use new/default Cloud Storage buckets; link a billing account and configure budget alerts before enabling uploads.
6. Choose bucket location close to the Firestore/Laravel deployment where practical; confirm data-residency and pricing requirements.
7. Set up `firestore.rules`, `firestore.indexes.json` and Storage access policy. Start with restrictive defaults; do not publish test-mode rules.
8. Enable/prepare billing and quota monitoring for Firestore, Storage, AI/search and any other Google Cloud services.

### C. Configure the Flutter app

From the existing Flutter app directory:

```powershell
flutter pub add firebase_core
flutter pub add firebase_auth
flutter pub add firebase_storage
flutter pub add dio

firebase login
dart pub global activate flutterfire_cli
flutterfire configure
```

Select the development Firebase project and the platforms actually supported. This generates `lib/firebase_options.dart`. Initialize Firebase before `runApp`. Use Firebase Auth for account sign-in, retrieve the current ID token, and attach it to Laravel API requests as `Authorization: Bearer <token>`.

Do not install the `cloud_firestore` Flutter plugin in the default architecture because business reads/writes go through Laravel. Add it only if a specific future feature needs direct, rules-protected client listeners. Use `firebase_storage` for authenticated uploads into private quarantine paths and `dio` for Laravel API calls/finalization. Laravel can issue short-lived signed download URLs for approved sanitized derivatives.

Optional packages if included in the scope:

```powershell
flutter pub add firebase_messaging
flutter pub add firebase_crashlytics
flutter pub add firebase_analytics
```

### D. Configure Laravel and Docker

Inside the Laravel backend/container build:

```bash
composer require google/cloud-firestore
composer require google/cloud-storage
```

Ensure the Laravel Docker image installs/enables the PHP `grpc` extension required by `google/cloud-firestore`. Add and test a maintained PHP JWT library for Firebase ID-token verification. Firebase's official Admin SDK does not list PHP as a supported Admin SDK language; follow the official third-party JWT verification procedure or isolate an official Node/Java/Python Admin SDK service if full Admin operations are required.

Configure Laravel with:
- Firebase project ID and expected token issuer/audience;
- Google Application Default Credentials;
- Firestore repository configuration;
- Cloud Storage bucket name and signed URL settings;
- selected search provider and queue/worker connection;
- separate development/staging/production settings.

Do not copy service-account JSON keys into the repository, Flutter project, Docker image or logs. Use local ADC for development. In production, attach a least-privilege service account/workload identity to the runtime where supported; if the hosting provider requires a key, use a secret manager and rotation.

### E. Configure Firebase Emulator Suite

In the repository's Firebase configuration directory:

```powershell
firebase init
firebase init emulators
```

Select Authentication, Firestore and Storage emulators. Add the emulator ports/settings to `firebase.json`, commit rule/index files, then start:

```powershell
firebase emulators:start --only auth,firestore,storage
```

Configure Flutter to use emulator endpoints only in debug/test builds. Android Emulator uses `10.0.2.2` to reach services on the host computer; a Dockerized Laravel service should use a reachable host/service name such as `host.docker.internal` or the configured Compose network. Do not use `127.0.0.1` inside a container to refer to the Windows host. Test-token/emulator bypasses must be impossible in production.

### F. Data migration from MySQL to Firestore

1. Make a verified backup/export of the existing MySQL database and media.
2. Create an entity mapping document from each old table to the Firestore collections in Section 9.
3. Preserve stable record IDs where practical; map old user IDs to Firebase Auth UIDs and update all owner/member references consistently.
4. Import users and credentials through a tested account migration plan. If password hashes are incompatible, require account reset/reauthentication.
5. Import parent/category/product/store records before dependent listing/tour/promotion records.
6. Migrate image files to Cloud Storage and update document paths. Preserve private originals and sanitized derivatives separately.
7. Verify counts, relationships, query results, authorization, media access, geohash coverage and search-index consistency.
8. Run a staging cutover rehearsal; keep MySQL read-only and available for rollback until verification is complete.
9. Only then cut over production and remove old SQL dependencies.

### G. Before production launch

- Confirm Firestore region and Storage bucket location.
- Confirm billing account, budget alerts, quotas and service costs.
- Verify Firebase Auth token validation and account revocation/disabled-user behavior.
- Verify Firestore rules deny unauthorized direct client access and IAM grants Laravel only the required access.
- Verify Storage upload/download signing, private originals and sanitized-only public media.
- Verify index/rules deployment, backup/export, restore, search re-indexing and queue recovery.
- Run load, security, regression and device tests.
- Document rollback and support procedures.

## Final Architecture Decision

Use **Flutter + Laravel REST API + Firebase Authentication + Cloud Firestore + Cloud Storage + a dedicated search service**.

- Flutter is the mobile client. Firebase Authentication handles account identity and issues ID tokens.
- Laravel is the trusted backend. It verifies Firebase ID tokens, loads authoritative user roles from Firestore, enforces store ownership/permissions and performs all privileged business operations.
- Cloud Firestore is the only primary application-record database after migration. It stores users/profiles, roles, stores, categories, products, store listings, promotions, vendor sessions, tour metadata, recognition jobs and audit records.
- Cloud Storage stores product images and 360° media. Original panoramas stay private; only privacy-processed and owner-reviewed derivatives can be published.
- A dedicated search index provides full-text, semantic and visual retrieval. It is derived from Firestore and can be rebuilt; Firestore remains the source of truth.
- Docker remains for Laravel API/worker development and production images. It no longer needs to run MySQL. Use Firebase Local Emulator Suite for local Auth/Firestore/Storage testing.
- Do not use Laravel Sanctum as a second primary identity system after Firebase Auth cutover. Laravel must validate Firebase ID tokens on every protected API request.
- Use Google IAM/ADC for server access. Firestore server clients bypass Security Rules, so Laravel authorization and least-privilege IAM are mandatory.

The original six phases are reported by the project owner as complete on the previous MySQL/Sanctum baseline. The Firebase conversion is a separate migration and is not complete until data, accounts, media, search, rules, indexes, tests, costs, backups and rollback have been verified.

The app must remain fully functional, not static: every visible control performs a tested action and production screens use persisted API results with loading, empty, validation, permission and error states. Search supports all lawful physical-product categories and combines exact identifiers, category expansion, aliases, semantic text retrieval, attributes and visual similarity. AI outputs remain suggestions until confirmed.

The owner's 360° store tour remains app-owned. Original panoramas remain private while queued processing detects/blurs people where feasible, produces sanitized derivatives, and blocks publication on failure or uncertainty. Owners review sanitized results and may add manual masks. Do not promise perfect anonymity.

For production, select the Firestore and Storage regions deliberately, configure IAM, token verification, billing alerts, backups/exports, restore tests, queue monitoring and controlled releases. Production readiness depends on security, testing, recovery and operations—not on choosing Firebase alone.
