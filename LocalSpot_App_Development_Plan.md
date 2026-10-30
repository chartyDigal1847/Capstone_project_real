# LocalSpot — App Development Plan

**Philippine Local Store & Product Locator**

*Enhancement blueprint · Version 1.7 · Prepared 27 October 2026*

**Platform:** Flutter mobile app · Laravel REST API · MySQL · Docker Compose  
**Development environment:** Docker Desktop + WSL 2 + Laravel Sail (backend)  
**Working product name:** LocalSpot (renameable)  
**Revision focus:** Fully functional API-connected UI, stronger AI product identification, semantic/category search across all lawful retail categories, and automatic people-privacy blurring for owner-created 360° store tours. Section 18 is the ordered build list for remaining work.

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
9. [Core Data Model](#9-core-data-model)
10. [Suggested API Endpoints](#10-suggested-api-endpoints)
11. [Security, Privacy and Data Quality](#11-security-privacy-and-data-quality)
12. [Development Roadmap and Milestones](#12-development-roadmap-and-milestones)
13. [Enhanced Acceptance Checklist](#13-enhanced-acceptance-checklist)
14. [Pilot Launch Strategy](#14-pilot-launch-strategy)
15. [Docker and Development Environment](#15-docker-and-development-environment)
16. [Production Readiness and Deployment](#16-production-readiness-and-deployment)
17. [Reference Documentation](#17-reference-documentation)
18. [Implementation backlog — what to build next](#18-implementation-backlog--what-to-build-next)

---

## 1. Executive Summary
LocalSpot is a location-based product discovery platform for the Philippines. It connects searches for products with participating physical stores and vendors near the customer. The app is for browsing, store discovery, advertising and navigation—not online ordering or delivery.

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
The project owner reports that the original six development phases have been technically completed. This version therefore focuses on the **next enhancement release**, not restarting the original roadmap. The completed status should still be verified against the repository, tests and running app before any production-readiness claim.

#### PRIMARY ENHANCEMENT GOAL
A customer can search using a product name, broad category, natural-language description or product photo, then discover relevant listings near their current or selected location. Owners can identify products with AI assistance, confirm or correct details, and publish store tours only after privacy processing and review. Every screen and interactive control must be connected to actual data and behavior; static pictures or nonfunctional buttons do not count as completed features.

## 2. Feature Scope and Priorities
This table describes the current product direction for the enhancement release. Existing functionality should be regression-tested; new items are not considered complete until their acceptance criteria pass.

| **Feature** | **Current target** | **Implementation notes** |
|---|---|---|
| Accounts and roles | Retain existing customer, owner, staff and admin roles | Continue enforcing permissions on the Laravel API. |
| Store directory and products | Retain existing listings and local business categories; support all lawful product categories sold by participating physical stores | Seller records remain the source of product-location results; do not limit the catalog to food or groceries. |
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
- Wire every control to a callback/state transition, navigation route, repository call or authorized API endpoint. Remove controls that do nothing; if a future feature is not implemented, label it unavailable instead of making it appear functional.
- Use persisted Laravel API data in normal app flows. Hardcoded or seeded demo records are allowed only in clearly identified development/test environments.
- Represent loading/progress, success, empty results, validation errors, permission denial, stale information, offline/network failure, server errors and retry/cancel behavior where relevant.
- Validate forms, display field-level errors, avoid duplicate submissions, preserve safe input after recoverable errors, and confirm destructive changes.
- Debounce text search, cancel stale requests, paginate large result sets, and preserve filters when returning to search results.
- Map controls must actually recenter/follow the user, toggle follow mode, filter stores, open selected-store details, request route previews and support manual area selection.
- The 360° viewer must support panorama drag/look, supported zoom gestures, connected viewpoint navigation, progress/loading indicators, privacy status and failed-image recovery.
- Owner edits to products, prices, availability, promotions and tours must persist through the API and refresh affected screens after success.
- Test actual user journeys with Flutter widget/integration tests and Laravel feature/authorization tests. A clickable mockup is not a completed implementation.

Use a feature-based Flutter architecture with one consistent state-management approach (for example, Riverpod or Bloc), repositories for data access, typed request/response models and separated UI/controller logic.

## 5. Core Workflows
### A. Owner registration and store publishing
1. Create an account and select the store-owner role.
2. Enter store details and select a business category.
3. Use the device location as a suggestion if permission is granted, or pin the location manually.
4. Enter barangay/city, street address where available, landmark and operating schedule.
5. Submit verification details required by the platform.
6. Publish the approved store profile and add products.

### B. AI-assisted product entry
1. Open Add Product and take a clear photo, choose an existing image, or use the optional barcode scanner.
2. If multiple objects are visible, detect/crop candidate items or ask the owner to select the product to identify.
3. Run image classification/object detection, OCR, optional barcode lookup and visual-embedding similarity search against the product catalog.
4. Combine the signals into ranked candidates. Show the suggested name, category, brand/model where supported by evidence, likely attributes, confidence or match strength, and unknown fields.
5. Let the owner choose a match, correct suggestions or manually create a product. Do not invent a brand, model, dimensions, compatibility or price when evidence is missing.
6. Display category-appropriate fields (for example apparel size/material; electronics model/capacity/compatibility; hardware dimensions/material/voltage; produce variety/selling unit).
7. Owner confirms the store-specific price, selling unit, stock/availability and listing photo.
8. Save through the API, show success or actionable errors, and refresh the catalog using persisted data.

**Important data rule:** AI suggestions are not confirmed inventory. The owner confirms product identity and store-specific values. Low-confidence or unknown matches must always have a usable manual-entry path.

### C. Customer search, discovery and navigation
1. Customer types a specific item (“Makita drill”), a broad category (“food”, “tech”, “hardware”), a need (“USB-C charger for Samsung phone”), or uses photo search.
2. The search service classifies the intent as exact product, broad category, attributes/compatibility or visual discovery. It searches product names, identifiers, aliases, category hierarchy, attributes, semantic text and visual similarity as applicable.
3. Request foreground location permission when nearby search or the map needs it. If permission is denied, use a selected map point or manually entered area.
4. Filter listings by selected radius and store status; rank by query relevance and distance, with optional price/freshness sorting.
5. Broad category queries expand the category tree: “food” includes grocery, produce, drinks and other food subcategories; “tech” includes electronics, computers, phones, peripherals and accessories; “hardware” includes tools, fasteners, plumbing/electrical supplies and building materials. Display filter chips to narrow results.
6. Show real product/store cards and map pins with category, store type, distance, supplied price/unit and last availability confirmation. Empty results provide practical alternatives such as increasing radius, clearing filters or viewing the parent category.
7. Tapping a card opens real details. Tapping Navigate opens a route preview inside LocalSpot; it does not launch another map app by default.
8. Opening a published store tour launches the interactive viewer using privacy-processed images. Third-party Street View remains out of scope.

### D. Store-tour publishing
1. Owner creates a tour for an approved store.
2. Capture or upload compatible 360° panoramas at the entrance and selected interior points.
3. Position each viewpoint on a simple tour path or store layout, then connect viewpoints with navigation arrows.
4. Preview transitions on a normal phone and correct images or links.
5. Publish after checking image privacy and content. The customer opens the tour inside LocalSpot.

### E. Customer real-time location behavior
1. Check whether device location services are enabled and request permission with a clear explanation.
2. Get an initial position and show the user-location marker on the embedded map.
3. Subscribe to location updates only while the map-follow or navigation feature is active in the foreground.
4. Keep the map centered only while the user has enabled Follow My Location; allow normal map panning without repeatedly snapping back.
5. Refresh nearby results only after a meaningful movement threshold or a deliberate refresh, with debounce/throttling to reduce battery and API usage.
6. Stop location subscriptions when the relevant screen/mode ends. If permission is denied, show a manual-location option without blocking the app.

### F. Optional live location for mobile vendors
1. An authorized owner/staff member explicitly starts a public location session.
2. The app displays a clear active-sharing indicator and the time the position was last updated.
3. During the session, send location updates at a reasonable interval or movement threshold to the authorized API.
4. Owner can stop sharing at any time. The session must also expire automatically after a configured timeout.
5. Customer map displays the reported position only while the session is active and fresh; otherwise show the regular selling area or last known location clearly labelled as stale.

### G. 360° store-tour privacy processing and publication gate
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

Start with MySQL full-text search, a hierarchical taxonomy, aliases and geospatial filtering. Add vector/embedding retrieval behind a `SearchProvider` interface after measuring baseline quality. Select the vector engine/provider based on deployment compatibility, cost and scale; do not hardwire the whole app to one AI vendor.

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

|**Layer**|**Recommended technology**|**Responsibilities**|
|---|---|---|
|Mobile client|Flutter + Dart, run natively during development|Customer UI, owner UI, camera, navigation, map views, tour viewer and API client|
|Backend API|Laravel REST API, containerized with Docker|Authentication, authorization, store/product workflows, search, promotions, tour metadata and moderation|
|Mobile API authentication|Laravel Sanctum token authentication|Issue and revoke mobile bearer tokens; authorize protected API requests|
|Database|MySQL|Users, roles, stores, product catalog, listings, coordinates, availability, promotions and tour records|
|Local development runtime|Docker Desktop + WSL 2 + Laravel Sail / Docker Compose|Reproducible PHP, web-server and MySQL services without requiring XAMPP|
|Production runtime|Production-built Docker image on a managed container platform or secured VPS|Run immutable application releases with production environment settings|
|Image storage|Cloud object storage|Product photos, store photos and panoramas; database stores file references and metadata|
|Recognition services|Image-understanding model/API + OCR + optional barcode lookup + image embeddings|Suggest matches across product categories; fuse visual, OCR and catalog signals; owner confirms details; credentials remain server-side|
|Map rendering and data|MapLibre Flutter + a commercially suitable tile/style provider|In-app 2D map, store markers, camera/follow behavior and route rendering; provider terms must permit commercial product discovery and advertising|
|Location services|Flutter `geolocator` or equivalent maintained plugin|Initial location and foreground position stream; permission handling and map-follow state|
|Routing services|Compatible hosted or self-managed routing engine/API|In-app route geometry and ETA where supported; validate terms, coverage, commercial use, quotas and cost|
|360° tour viewer|Embedded panorama viewer using LocalSpot-owned sanitized tour files and metadata|Connected viewpoints, meaningful loading/error/error-retry states, and publication restricted to sanitized media|
|Media privacy processing|Laravel queued image-processing job + person/face detection/segmentation pipeline|Private staging, panorama-aware masking, sanitized derivatives, manual review and block-on-failure gate|
|Search service|MySQL full-text + taxonomy/aliases initially; vector/embedding search behind an interface when needed|Exact, category, semantic and visual similarity retrieval with geospatial filtering and quality evaluation|
|Admin web app|Laravel web dashboard|Verification, reports, content moderation and operational oversight|
|Background processing|Laravel queue worker, run as a separate service/container when needed|Image processing, asynchronous recognition, moderation tasks and maintenance jobs|
|CI and release checks|Git-based CI pipeline|Run tests and static checks; build and verify container images before deployment|

### Architecture principles
- Start with a modular Laravel application rather than multiple microservices. Keep store management, product catalog, inventory, discovery, promotions, image recognition and tours separated into clear modules within one codebase.
- Use versioned API routes (for example, `/api/v1/...`) and validate all request data on the backend.
- Use Laravel Sanctum for the initial Flutter mobile app’s first-party bearer-token authentication. Define token expiration and revocation behavior explicitly. Use Passport only if the project later needs a full OAuth2 authorization server for third-party clients or grant flows that require it.
- Keep Flutter separate from MySQL. The mobile app communicates only with the Laravel API; Laravel enforces authentication, authorization and business rules before reading or writing data.
- Keep production secrets and privileged third-party credentials out of Git, container images, client bundles and logs. Use environment-specific configuration or a deployment secret manager.
- Use object storage for image bytes; do not store large panorama files directly in MySQL. Keep original tour uploads in private staging and expose only sanitized derivatives.
- Run panorama privacy processing and slow image-recognition requests through Laravel queues with observable job state, bounded retries, failure handling and manual review.
- Use a shared image-analysis interface for owner recognition, customer visual search and catalog indexing; all provider credentials remain server-side.
- Use hybrid search: exact identifiers/keywords and category rules are first-class; semantic/visual similarity adds recall but must not replace exact matching.
- Store category definitions and product-attribute schemas as data so the catalogue can expand without hardcoding every product type into Flutter.
- Render the map and route preview inside Flutter; do not use external-map launching as the default product flow.
- Keep customer location streaming on-device while the relevant foreground feature is active. Send coordinates to the API only when a nearby-search or route request needs them.
- Make mobile-vendor location sharing explicit, authorized, time-limited and easy to stop.
- Use database indexes for store coordinates, product identifiers, category, store status and common search fields. Review actual query plans as the catalog grows.
- Plan for background jobs when image recognition or file processing could make a request slow. Apply retry limits, timeouts and failure handling.
- Add automated unit, feature/API, authorization and migration tests before expanding to advanced features.
- Keep development, staging and production configuration separate. Never assume that a working local Docker setup is automatically production-ready.

### Deployment approach
Use Docker Compose and Laravel Sail for local backend development on Windows with Docker Desktop and WSL 2. Run Flutter natively on Windows or with the Android emulator/physical phone as appropriate. XAMPP is optional and is not required for this project if Laravel and MySQL are provided by containers.

For production, do **not** deploy the default Sail development environment unchanged. Build a production-specific image, run it with production settings, disable development/debug features, avoid bind-mounting source code into the running container, and expose only the required HTTPS entry point. Keep MySQL on a private network or use a managed database. A single properly secured VPS running Docker Compose can be sufficient for an initial pilot; a managed container platform is also suitable. Kubernetes and microservices are not required for the MVP.

## 9. Core Data Model
|**Table**|**Purpose / important fields**|
|---|---|
|users|Account profile, credentials/identity provider, account status and timestamps|
|roles / permissions|Customer, owner, staff and admin roles; permissions assigned explicitly|
|stores|Owner, name, store type, status, latitude/longitude, address/landmark, schedule, fixed/mobile status|
|store_members|User, store, membership role and granted permissions|
|categories|Hierarchical store/product taxonomy: name, slug, parent category, status and display order|
|products|Shared product identity: name, brand, category, model/variant, optional barcode/GTIN, general attributes and status|
|product_aliases|Alternate spellings, brand/model variations, Filipino/English/local names and equivalent search terms|
|category_synonyms|Broad phrases mapped to categories/subtrees (for example, “tech” to electronics/computers/mobile accessories)|
|product_attribute_definitions|Category-specific searchable attributes, types, units, validation and display rules|
|product_attribute_values|Confirmed values such as model, dimensions, material, capacity, compatibility or condition|
|store_products|Store-specific listing: product, price, unit, quantity/availability, condition where applicable, listing status and last-confirmed time|
|stock_movements|Optional history of additions, removals and adjustments|
|product_images|Private/source and public/sanitized image references, role, processing/blur status, metadata-stripped flag and moderation status|
|product_image_embeddings (optional)|Image vector/reference, model version and search-index status for visual similarity|
|product_recognition_jobs|Input image reference, processing steps, candidates, model/version, status, error and owner decision|
|tour_media_assets|Private original, sanitized derivative, privacy status, manual-review status, model version, retention deadline and publication state|
|store_locations|Fixed/regular store coordinates, location mode, public visibility and last-updated metadata|
|vendor_location_sessions|Owner-started mobile-vendor sharing session, start/end/expiry times, active state and last update; use for explicitly shared live coordinates only|

|**Table**|**Purpose / important fields**|
|---|---|
|promotions|Store, offer, dates, sponsored status, approval and limits|
|store_tours|Store, title, tour status and publication details|
|tour_nodes|Tour viewpoint image reference, position/order, orientation and metadata|
|tour_connections|From-node, to-node, arrow/hotspot position and connection metadata|
|favorites|Customer references to saved products/stores|
|reports / audit_logs|Reported listings, moderation actions and important owner/admin changes|

### Data Model Rule
One shared product can appear in many stores. Each store listing owns its own price, selling unit, reported stock and freshness timestamp. This avoids duplicating the global product identity for every seller.

## 10. Suggested API Endpoints
These are proposed route patterns for planning, not proof that the routes already exist. Version the API and standardize JSON responses, validation errors, pagination and rate limits. Every write route must check authentication, permissions and store membership/ownership. For Flutter, use expiring/revocable Sanctum tokens as configured, platform-secure storage and token revocation on logout. Do not place bearer tokens in URLs or ordinary unencrypted preferences. Customer coordinates should be transient request data rather than a stored movement history by default.

|**Area**|**Example endpoint**|**Purpose**|
|---|---|---|
|Auth|POST /api/v1/auth/register; POST /api/v1/auth/login|Register and authenticate accounts; return a Sanctum bearer token for mobile use|
|Auth|GET /api/v1/me; DELETE /api/v1/auth/logout|Return the authenticated profile; revoke the current token on logout|
|Stores|POST /api/v1/stores|Register a store|
|Stores|GET /api/v1/stores/nearby?lat=...&lng=...&radius_km=...|Find nearby participating stores|
|Stores|GET /api/v1/stores/{id}|Get public store details|
|Routes|POST /api/v1/routes/preview|Request route geometry and supported distance/ETA from the configured provider; do not return provider secrets|
|Vendor location|POST /api/v1/stores/{id}/location-sessions|Start an explicitly authorized public location-sharing session|
|Vendor location|PATCH /api/v1/stores/{id}/location-sessions/current|Update the active session position; apply auth, rate limits and expiry rules|
|Vendor location|DELETE /api/v1/stores/{id}/location-sessions/current|Stop the session and stop displaying the live location|
|Products|GET /api/v1/products/search?q=...|Search product catalog and aliases|
|Listings|GET /api/v1/store-products/search?product_id=...&lat=...&lng=...|Find nearby store listings for a product|
|Listings|POST /api/v1/stores/{id}/products|Create a store-specific listing|
|Listings|PATCH /api/v1/store-products/{id}|Update authorized price/availability details|
|Recognition|POST /api/v1/product-recognition/suggest|Accept an image and return ranked vision/OCR/barcode/catalog candidates; mark uncertain fields|
|Recognition|GET /api/v1/product-recognition/jobs/{id}|Poll asynchronous recognition status and results|
|Recognition|POST /api/v1/product-recognition/{id}/confirm|Save the owner-selected match, corrections and confirmed attributes|
|Categories|GET /api/v1/categories?parent_id=...|Return taxonomy tree/children and category synonyms|
|Search|GET /api/v1/search?q=...&lat=...&lng=...&radius_km=...&category_id=...|Hybrid text/category search with geospatial filtering, ranking, filters and pagination|
|Search|POST /api/v1/search/by-image|Return likely/visually similar products from a customer photo|
|Promotions|POST /api/v1/stores/{id}/promotions|Create a promotion for review|
|Tours|POST /api/v1/stores/{id}/tours|Create a tour|
|Tours|POST /api/v1/tours/{id}/media|Upload panorama to private staging and queue privacy processing|
|Tours|GET /api/v1/tour-media/{id}/status|Get upload, processing, review and publication status|
|Tours|POST /api/v1/tour-media/{id}/manual-blurs|Add approved manual blur regions before publishing|
|Tours|POST /api/v1/tours/{id}/publish|Publish only if all required assets have approved sanitized derivatives|
|Tours|POST /api/v1/tours/{id}/nodes POST /api/v1/tours/{id}/connections|Add viewpoints and connect tour nodes|
|Moderation|GET /api/v1/admin/reports|Review reported content; admin only|

## 11. Security, Privacy and Data Quality

### Application and API security
- Enforce authentication and authorization on the Laravel API for every protected operation. Use policies/gates and verify store membership on every request involving a store or listing ID.
- Use Laravel Sanctum for Flutter’s first-party mobile bearer-token flow unless a documented OAuth2 requirement justifies Passport. Define token expiry, revocation and logout behavior; keep tokens in platform-secure storage on the device.
- Validate and normalize store coordinates, URLs, prices, units, category IDs, query parameters and image uploads. Use server-side validation for all client-supplied data.
- Restrict uploads by accepted file type, size and processing rules. Generate safe storage names; do not trust client-provided filenames or content types. Scan/moderate uploads as appropriate.
- Treat AI outputs as untrusted suggestions. Validate confirmed values server-side and do not accept AI-generated price, inventory, safety ratings or compatibility claims without owner confirmation or a trusted data source.
- Use HTTPS for deployed services, secure password handling, rate limits on login/search/recognition endpoints, and audit logs for sensitive operations.
- Keep privileged AI, storage and mapping credentials on the server. Public mobile mapping keys must be restricted by application/platform and the minimum required APIs. Never ship server secrets in Flutter.
- Apply least privilege to database users, staff permissions, administrators, service accounts and deployment credentials.
- Never expose MySQL directly to the public internet. In production, the database should be reachable only from the application network or approved administrative paths.
- Keep `.env` files and secrets out of version control and Docker build context; commit a sanitized `.env.example` instead. Use a secret manager or platform secret configuration in production.
- Production images should use trusted, maintained base images, a minimal runtime, a non-root application user where supported, updated dependencies, and vulnerability/dependency scanning. Do not include development tools or debug settings unnecessarily.
- Keep `APP_DEBUG=false` and `APP_ENV=production` in production. Do not expose detailed exception traces or credentials in API responses or logs.
- Limit administrator access, require appropriate authentication, and record moderation and other high-impact actions.
- Provide account and listing suspension/report workflows.

### Docker and runtime security
- Use Docker Compose/Laravel Sail for development only. Build and test a production-specific image and configuration for release; do not deploy the default development container unchanged.
- Use `.dockerignore` to prevent secrets, local caches, dependencies not needed for the build, and unrelated files from entering the build context.
- Prefer multi-stage builds and pinned, maintained base-image versions. Rebuild regularly to receive security updates and scan images/dependencies before release.
- Do not bind-mount the source tree into production containers. Use immutable versioned images and explicit environment configuration.
- Expose only the reverse proxy or HTTPS entry point publicly. Keep the database and internal worker services on private container/network paths. Do not publish MySQL’s port to the internet.
- Configure container restart behavior, health checks, resource limits where supported, log collection and safe shutdown handling. Run queue workers as separate processes/services when asynchronous work is introduced.
- Do not delete persistent database volumes as part of normal updates. Back up data and verify restore procedures.

### Privacy requirements
- Request customer GPS permission only when it improves nearby search or navigation.
- Provide manual location selection when GPS is denied.
- Do not continuously track mobile vendors by default; require an explicit active sharing session, clear indicator, stop control and automatic expiry.
- Customer location is foreground-only by default. Do not request background-location permission for the initial release. Stop the position stream when map-follow/navigation ends.
- Do not retain raw customer location history by default. Use coordinates only for map positioning, nearby queries and route requests that require them.
- If vendor live coordinates are exposed publicly, show a last-updated timestamp, stop serving expired sessions, and let the vendor stop sharing at any time.
- Require automatic privacy processing and owner review before any 360° image is published. Use person segmentation plus face detection where feasible, provide manual blur correction and block publication if processing fails.
- Keep unblurred originals private with restricted access and documented retention/deletion. Only sanitized derivatives may be served publicly; generate thumbnails/tiles from them and strip EXIF location metadata.
- Test automatic blur for seams, poles, reflections, occlusion, low light and distant people; owners must be able to manually blur missed people/sensitive regions.
- Explain how images are used for product recognition, whether an external service processes them, and how long uploads are retained.
- Avoid collecting or retaining personal data that is unnecessary for store discovery and app operation.

### Data freshness and trust
- Track listing status and last confirmation time.
- Let owners quickly mark a product unavailable or update its stock information.
- Show price units clearly (for example, per kilo, per piece, or per pack).
- Distinguish an owner-listed product from a recently confirmed available product.
- Distinguish a fixed store pin from a mobile vendor's active or stale live location.
- Let customers report a wrong location, price or listing.
- Do not claim that a vendor has an item in stock if the system has no reliable recent confirmation.

## 12. Development Roadmap and Milestones
### Status of the original six phases
The project owner reports that the original six phases have been technically completed. This plan therefore moves to a **post-baseline enhancement roadmap**. This document does not independently verify repository state; run the tests and acceptance checks below against the current code before release.

| **Status** | **Scope** | **Action in this revision** |
|---|---|---|
| Original Phases 1–6 | Foundation, locator, inventory/photo scan, advertising/tours, advanced mapping/visual search, pilot/launch | Treat as baseline-complete according to project status; regression-test existing flows while adding the changes below. |
| Enhancement 7 | Provider and embedded 2D map | Choose an appropriately licensed provider and keep the map inside Flutter. |
| Enhancement 8 | Automatic current location | Add foreground location permission, first fix, live position stream, follow/recenter and manual fallback. |
| Enhancement 9 | In-app product search and route preview | Update nearby results based on movement thresholds and draw a route on the embedded map. |
| Enhancement 10 | Optional mobile-vendor location | Add owner-controlled start/stop, session expiry and fresh/stale public-location states. |
| Enhancement 11 | Owner-created 360° store tours | Keep the tour fully inside LocalSpot; remove third-party Street View and street-imagery providers from the current scope. |
| Enhancement 12 | Functional UI/API completion | Wire every control, remove inert UI, add loading/empty/error/validation states and end-to-end tests. |
| Enhancement 13 | Hybrid category and semantic search | Implement taxonomy expansion, aliases, exact search, semantic text/image similarity and location ranking for “food”, “tech”, “hardware” and specific items. |
| Enhancement 14 | AI product identification v2 | Combine image detection, OCR, barcode lookup, catalog embeddings, attribute suggestions and owner confirmation across product families. |
| Enhancement 15 | Automatic 360° privacy blur | Private staging, person/face detection, panorama-aware masking, sanitized derivatives, manual correction, review/publish gate and retention. |
| Enhancement 16 | Regression, privacy and production verification | Test interactive behavior, AI quality, image privacy, access controls, device performance, backup/restore and monitoring. |

### Recommended implementation sequence
1. **Select the map stack:** prototype MapLibre Flutter with a commercial-appropriate tile provider and verify attribution, commercial listing/advertising permission and service limits.
2. **Finish embedded 2D map:** store pins, selection cards, zoom/pan and a selected-store detail panel.
3. **Add foreground live location:** permission prompts, current marker, follow/recenter toggle, permission-denied fallback and throttled nearby-search refresh.
4. **Add route preview:** route geometry and supported distance/ETA, all drawn inside LocalSpot. Keep “open in external maps” only as a fallback action.
5. **Add vendor location sessions:** explicit opt-in, visible sharing state, controlled updates, expiry and stop-sharing behavior.
6. **Make the tour privacy-safe:** add queued panorama processing, automatic people blur, sanitized previews, manual correction and a publication gate.
7. **Improve AI product identification:** add OCR, visual embeddings, catalog candidate ranking and structured category attributes.
8. **Build hybrid search:** test broad category queries (“food”, “tech”, “hardware”), exact model/part-number searches, image search, filters and geographic ranking.
9. **Run the enhanced acceptance checklist:** verify all controls in real API-backed journeys and fix regressions before calling the release ready.


## 13. Enhanced Acceptance Checklist
- ☐ A vendor can create an account, register a store, set a map location and publish approved listings.

- ☐ The system supports small local vendors as well as larger stores and does not require a barcode.

- ☐ A photo-assisted product entry returns suggestions and requires owner confirmation or manual encoding.

- ☐ Customers can search by product name and see participating sellers that list a match.

- ☐ Customers can select a search radius and filter by business type.

- ☐ The map opens the correct registered store and provides an in-app route-preview action.

- ☐ Store-specific prices, units and availability timestamps are displayed accurately when provided.

- ☐ An owner can publish a basic connected 360° tour and a customer can navigate the viewpoints.

- ☐ Admins can verify stores, moderate promotions and respond to reports.

- ☐ Users cannot alter another store’s inventory by changing an API request or identifier.

- ☐ The app offers manual area selection when location permission is denied.

- ☐ Third-party API usage, privacy and map attribution requirements are addressed.
- ☐ Flutter communicates only with the Laravel API; database credentials are never embedded in the mobile app.
- ☐ Production authentication tokens can expire and be revoked, and logout revokes the current token.
- ☐ Automated tests cover authentication, role/ownership authorization, product search, store-distance filtering and core write endpoints.
- ☐ CI runs formatting/static checks and relevant tests before a release image can be published.
- ☐ A production-specific Docker image is used; development bind mounts, debug mode and development-only tools are not enabled in production.
- ☐ Production is served over HTTPS; the MySQL service is not publicly exposed; secrets are managed outside source control and images.
- ☐ Database backups are automated, and at least one restore test has been completed successfully.
- ☐ Health checks, logs, error reporting, usage quotas and budget alerts are configured.
- ☐ There is a documented release and rollback procedure, including how to handle database migrations safely.
- ☐ The 2D map is rendered inside LocalSpot; tapping a store or Navigate does not automatically launch Google Maps or another external app.
- ☐ After permission is granted, the app gets a current-position fix and updates the location marker while map-follow/navigation is active.
- ☐ Follow My Location can be switched on/off; normal map panning does not force the camera back to the user unexpectedly.
- ☐ Nearby results refresh only after a configured movement/time threshold or deliberate request, avoiding an API call on every GPS event.
- ☐ If location permission is denied, disabled or approximate, the user receives a usable explanation and can select an area manually.
- ☐ Route geometry and preview are visible on the in-app map; an external mapping app is optional fallback only.
- ☐ Mobile-vendor public location requires an owner-authorized active session, shows last update, can be stopped and expires automatically.
- ☐ Customer movement is not stored as a continuous history by default, and background location permission is not requested for the initial release.
- ☐ The selected 2D map and routing providers are permitted for LocalSpot's product-directory and advertising use, with required attribution displayed.
- ☐ Third-party Street View, Mapillary, KartaView and Panoramax are not required or integrated in this release.
- ☐ The owner-created 360° tour works inside LocalSpot and has a clear fallback to ordinary store photos if no tour has been published.
- ☐ Product search and owner listing forms support non-food goods such as hardware, electronics, tools, appliances, clothing, household items and vehicle parts.
- ☐ Every visible button, category chip, card, map pin, filter, camera control, form action and tour arrow triggers a tested behavior; no inert controls remain.
- ☐ Production screens load persisted API data rather than hardcoded demo records; demo fixtures are limited to development/tests.
- ☐ Relevant screens show loading, empty, validation, permission-denied, stale-data and recoverable-error states.
- ☐ Searching “food near me” returns appropriate food-category descendants and nearby listings, not only products whose literal name contains “food”.
- ☐ Searching “tech” returns electronics/computing/mobile/accessory categories; “hardware” returns tools, fasteners, building, plumbing and electrical supply categories.
- ☐ Exact identifiers/model numbers rank above weak semantic or visual matches; broad queries use category expansion and semantic retrieval.
- ☐ AI product identification combines visual analysis, OCR, catalog matching and owner confirmation; barcode is optional.
- ☐ AI never silently invents price, stock, model specifications, safety ratings or compatibility where evidence is missing.
- ☐ Customer photo search returns candidates/visually similar items and communicates uncertainty.
- ☐ Tour originals remain private; public thumbnails/viewer tiles come only from privacy-processed derivatives.
- ☐ Automatic people blur is tested on 360° seams/poles and common difficult conditions; manual correction is available.
- ☐ Failed or uncertain privacy processing blocks publication or requires review and never falls back to publishing the original.
- ☐ Owners can add blur masks for missed people and sensitive areas; published content cannot be switched back to an unblurred original.
- ☐ Original asset access, retention and deletion behavior are documented and tested.
- ☐ Automated tests cover category expansion/ranking, recognition job states, tour privacy publication gates, upload permissions and API authorization.
- ☐ Appropriate map attribution, quota/cost alerts and fallback behavior are tested.

### Primary risks and mitigations
|**Risk**|**Mitigation**|
|---|---|
|Stale product availability|Show last-confirmed time, provide quick owner updates and user reporting|
|AI misidentifies product|Present suggestions only; require owner confirmation; support manual creation|
|Incomplete vendor coverage|Onboard sellers in geographic clusters and allow simple store registration|
|No third-party Street View in current scope|Keep the embedded 2D map and owner-created 360° store tour; do not block launch on external street imagery|
|Map and AI service costs|Use quotas, restricted keys, cache appropriately, monitor usage and set budget alerts|
|Poor indoor distance estimation|Start with manual viewpoint placement; add sensor-assisted guidance only after testing|
|Incorrect or misleading advertising|Require approval, clear sponsored labels, campaign dates and reporting mechanisms|

## 14. Pilot Launch Strategy
1. Choose one pilot municipality or compact service area before attempting a nationwide launch.
2. Recruit a balanced set of sellers across product categories, including sari-sari stores, market stalls, hardware shops, electronics/technology retailers, household-goods stores and larger retailers.
3. Help sellers list their most commonly requested products first rather than demanding complete inventories.
4. Test real local product searches, alternate names, misspellings and units.
5. Test GPS permission granted/denied, approximate location, weak GPS, indoor/urban positioning, movement refresh, route preview and manual-location fallback on real target phones.
6. Validate 2D map and route coverage and confirm the selected providers' attribution, commercial-use terms, quotas and pricing. Test owner-created 360° tours on target devices.
7. Measure failed searches, stale listings, wrong-location reports, location-fix success, routing errors, app responsiveness and vendor live-session correctness.
8. Use pilot feedback to refine seller onboarding and then expand to nearby areas.

## 15. Docker and Development Environment

### Decision
Use **Docker Desktop + WSL 2 + Laravel Sail** for local Laravel/MySQL development on Windows. This is the recommended setup for LocalSpot because it makes the backend environment reproducible and reduces dependence on globally installed PHP/MySQL versions. XAMPP is optional; do not run a second MySQL instance on the same port unless you intentionally configure the ports.

Docker runs the backend services, not the Flutter mobile app. During development, Flutter can run natively on Windows or on an Android emulator/physical device, while Laravel and MySQL run in containers.

### Suggested repository layout

```text
LocalSpot/
├── mobile/                       # Flutter app
└── backend/                      # Laravel REST API and admin dashboard
    ├── app/
    ├── routes/
    ├── database/
    ├── compose.yaml              # Local Sail / Docker Compose configuration
    ├── .env                      # Local secrets; never commit
    └── .env.example              # Safe template; no real secrets
```

The actual Sail-generated file layout may vary with the Laravel version and selected services. Keep the backend's Docker configuration close to the Laravel project and document any deviations.

### Local setup sequence
1. Install Docker Desktop for Windows and enable its WSL 2 backend. Keep the Docker engine updated.
2. Install/use a WSL 2 Linux distribution and open the backend project from the WSL filesystem for the smoothest Linux-container workflow.
3. Create the Laravel backend, install Laravel Sail as a development dependency, and publish/configure the Sail services for the required PHP runtime and MySQL version.
4. Configure `.env` for local service names, for example `DB_HOST=mysql` when the Laravel application runs inside the Compose network. Use the actual service names and ports generated by the project.
5. Start the backend services and run migrations and tests inside the container environment.
6. Keep Flutter on its own normal development toolchain and point its API base URL at the host port exposed by Docker.

Typical Sail commands, run from a WSL/Linux terminal in the Laravel backend directory:

```bash
# Start development containers
./vendor/bin/sail up -d

# Run database migrations
./vendor/bin/sail artisan migrate

# Run automated tests
./vendor/bin/sail artisan test

# Stop containers without deleting persisted database data
./vendor/bin/sail stop
```

These commands assume Sail has already been installed and its Compose configuration generated. Check the project's actual published ports before configuring Flutter.

### Flutter-to-API development URLs

|**Flutter runtime**|**Typical API host pattern**|**Important note**|
|---|---|---|
|Windows app/browser on the same PC|`http://localhost:<published-port>/api/v1`|The port must match the Compose port mapping.|
|Standard Android emulator|`http://10.0.2.2:<published-port>/api/v1`|`10.0.2.2` routes from the emulator to the host machine.|
|Physical Android phone on the same Wi-Fi|`http://<PC-LAN-IP>:<published-port>/api/v1`|Allow the port through the development firewall and keep the phone and PC on a trusted network.|
|Production mobile app|`https://<production-api-domain>/api/v1`|Use valid TLS and production credentials.|

Do not embed database hostnames, passwords or MySQL connection details in Flutter. The mobile client communicates with Laravel only.

### Data persistence warning

Use a named Docker volume for the local MySQL data. Stopping containers does not normally delete the volume, but commands such as `docker compose down -v` can remove volumes and permanently delete local database data. Do not use volume-deleting commands unless you intentionally want a clean database and have a backup if needed.

### Why not XAMPP?

XAMPP is not required if Docker supplies the PHP/Laravel runtime and MySQL database. Keep XAMPP for unrelated projects if useful, but avoid running multiple database or web-server services that compete for the same ports. Docker is a development and deployment tool; it does not remove the need to design, test and secure the application.

## 16. Production Readiness and Deployment

### Recommended first production deployment

For the first pilot, use either a managed container platform or a properly secured VPS with Docker Compose. A single-server Compose deployment can be appropriate at this scale; Kubernetes and microservices are not required. Consider managed MySQL and managed object storage when budget permits, because they reduce the operational burden of backups, storage durability and upgrades.

### Development, staging and production separation

|**Environment**|**Purpose**|**Configuration rules**|
|---|---|---|
|Development|Daily feature work|Laravel Sail, local/test data, development credentials, debug tools only locally|
|Staging|Rehearse releases and test integrations|Production-like image and topology, separate database and API keys, non-production test data|
|Production|Real vendors and customers|HTTPS, debug disabled, protected secrets, restricted network access, monitoring, backups and controlled releases|

Use separate credentials, databases/storage buckets and mapping/AI service restrictions for each environment. Do not copy production personal data into development by default.

### Production container requirements
- Build a production-specific image; do not deploy Sail's development image or its development server configuration unchanged.
- Prefer multi-stage builds, maintained base images with pinned versions, a minimal runtime and a non-root application user where supported.
- Add a `.dockerignore`; never include `.env`, access tokens, local database files, private keys or unnecessary development artifacts in the build context.
- Install only required production dependencies and run dependency/image vulnerability checks. Establish a routine for rebuilding and redeploying patched base images.
- Use immutable/versioned image tags or digests for releases. Do not depend on mutable `latest` tags as the only release identifier.
- Do not bind-mount the source code into production. Application code should come from the built image, not from writable host files.
- Configure production environment values explicitly, including `APP_ENV=production`, `APP_DEBUG=false`, correct trusted proxy/HTTPS settings and secure cookie/token settings where relevant.
- Use a reverse proxy or managed ingress for HTTPS. Publish only required application ports; keep MySQL and internal queue/worker services private.
- Add health checks, a restart policy, log collection, and resource limits where supported by the hosting platform. Avoid logging passwords, bearer tokens, secret headers or uploaded sensitive data.
- Run Laravel optimization/cache commands appropriate to the actual Laravel release as part of image or release preparation, following the official deployment guide.
- Run database migrations as a controlled release step, not independently and unpredictably from every replica's startup. Review migration compatibility before rolling out code changes.
- Run queue workers as a distinct process/service when asynchronous image recognition or media processing is enabled, with timeouts, bounded retries and failed-job monitoring.

### Database, storage and recovery
- Use a private database network or a managed database with network restrictions, least-privilege database users and encrypted connections where supported.
- Store product photos and 360° panorama files in object storage; configure access controls, upload limits, lifecycle/retention rules and backups appropriate to the data.
- Configure automated database backups, define a retention period, and test restoring a backup into a separate environment. A backup that has never been restored is not a verified recovery plan.
- Preserve persistent volumes during routine deployments. Test database migrations and back up important data before risky schema changes.
- Define a basic recovery objective: how much data loss is acceptable and how quickly the app must be restored. Adjust backup frequency and hosting design to the actual pilot needs.

### CI/CD and release workflow
1. Commit code and configuration templates to Git; keep secrets in the CI/hosting secret store.
2. Run code formatting/linting, static checks, unit tests, API/feature tests and authorization tests.
3. Build the production image and scan dependencies/image layers.
4. Deploy the image to staging and run smoke tests, migration checks and key product-search workflows.
5. Approve the release, back up production data when required, run the migration step and deploy the specific image version.
6. Run health checks and monitor logs/errors. If the deployment fails, follow a tested rollback plan; database changes may require a forward fix rather than simply reverting the image.

### Observability and cost control
- Configure uptime and health monitoring, application error reporting, structured logs and alerts for database, queue and storage failures.
- Monitor response time for nearby-product searches and image-recognition workflows.
- Set usage limits/alerts for the selected map-tile/routing provider, AI recognition and object storage; restrict keys to the minimum required services and platforms.
- Track failed searches, stale listings, wrong-location reports and vendor updates so operational quality can be measured after launch.

### Authentication decision for the initial Flutter app
Use Laravel Sanctum for first-party Flutter bearer-token authentication if the app only needs to authenticate to its own API. Store tokens using platform-secure storage, define expiration and revocation behavior, and revoke the current token on logout. Use Passport only if later requirements genuinely need a full OAuth2 authorization server or third-party client grants. Recheck the official Laravel authentication documentation when implementation begins because supported framework versions and configuration details can change.

### Production launch gate
Do not label the release production-ready until the relevant items in Section 13 pass, including backend authorization tests, image/configuration checks, HTTPS, protected database access, confirmed backups and restore testing, monitoring, and a documented release/rollback procedure.

## 17. Reference Documentation
The following official documentation should be checked during implementation because API capabilities, pricing, coverage and usage policies can change.

- **Google Cloud Vision documentation (OCR, labels and face detection):** <u>https://cloud.google.com/vision/docs</u>

- **Google Cloud Vision AI Product Recognizer:** <u>https://cloud.google.com/vision-ai/docs/product-recognizer</u>

- **Hybrid keyword + semantic search concept (OpenSearch):** <u>https://docs.opensearch.org/latest/vector-search/ai-search/hybrid-search/</u>

- **Laravel queues for background image processing:** <u>https://laravel.com/docs/queues</u>

- **MapLibre for Flutter:** <u>https://pub.dev/packages/maplibre</u>

- **Flutter Geolocator:** <u>https://pub.dev/packages/geolocator</u>

- **OpenStreetMap tile usage policy:** <u>https://operations.osmfoundation.org/policies/tiles/</u>

- **Laravel documentation:** <u>https://laravel.com/docs</u>

- **Laravel Sail (Docker development environment):** <u>https://laravel.com/docs/sail</u>

- **Laravel Sanctum (API token authentication):** <u>https://laravel.com/docs/sanctum</u>

- **Laravel deployment guidance:** <u>https://laravel.com/docs/deployment</u>

- **Docker Compose in production:** <u>https://docs.docker.com/compose/how-tos/production/</u>

- **Docker build best practices:** <u>https://docs.docker.com/build/building/best-practices/</u>

- **Docker Desktop for Windows:** <u>https://docs.docker.com/desktop/setup/install/windows-install/</u>

- **Flutter architecture guide:** <u>https://docs.flutter.dev/app-architecture/guide</u>

- **Flutter documentation:** <u>https://docs.flutter.dev/</u>

## 18. Implementation backlog — what to build next

Use this section as the working queue. Check items off in the repository when they are implemented **and** covered by Flutter and/or Laravel tests. Do not mark production ops complete from local demo data alone.

### Already in the codebase (keep regression-testing)

| Area | Present now | Notes |
|---|---|---|
| Roles and policies | Customer, owner, staff, admin; Laravel policies on store writes | Hiding a Flutter button is not authorization. |
| Catalog and search | Aliases, typos, food/tech/hardware expansion, sort, category chips, photo search | Server pagination exists; UI load-more is Wave A. |
| Map and location | In-app MapLibre map, recenter, foreground GPS, manual area, route preview | Turn-by-turn voice is later. |
| Owner inventory | Photo suggest, confirm, attributes, archive, stock history | Recognition ranks catalog from hint/barcode/image tokens, not a vision model. |
| Tours | Process → review → publish gate; originals not returned on public catalog | Private original keys + `/storage/tours/{id}/sanitized.jpg` derivatives. Gate, not ML person blur. |
| Admin | Store/promo/report/feedback review; audit log list | |
| CI | `php artisan test`, `flutter analyze`, `flutter test`, production Dockerfile build | |

### Wave A — finish the current app (do these first)

1. ~~Search: cancel stale requests; **Load more** using `meta.current_page` / `last_page`.~~ Done (filters still reset if the Search tab is rebuilt).
2. ~~Taxonomy: `categories.parent_id` and `GET /api/v1/categories?parent_id=…`.~~ Done.
3. ~~Hide Sign-in **demo account list** in release builds; keep it for debug/tests.~~ Done.
4. ~~Field-level validation on remaining forms (register, promotions, staff invite) instead of snackbars only.~~ Done.
5. ~~Staff grants: persist which staff may edit inventory vs start live location vs promotions; enforce in policies.~~ Done.
6. ~~Cancel in-flight recognition/search when the user changes the query or leaves the screen.~~ Done.

### Wave B — search and identification quality

1. ~~Replace hint-only “AI” with a server-side pipeline: image upload → OCR + optional barcode → catalog rank; keep unknown fields and owner confirm.~~ Pipeline accepts an image payload, extracts digit barcodes and hint/filename tokens, then ranks the catalog. **Not** a vision/OCR model; originals of recognition photos are not stored.
2. ~~Queue recognition jobs (`pending` → worker → `ready`/`failed`) instead of completing in the HTTP request.~~ Done (`ProcessRecognitionJob`; still catalog/hint/barcode rank, not a vision model). Queue workers must be running in production (`queue:work` or the scheduled catch-up command).
3. ~~Semantic/vector retrieval for natural-language needs (for example “USB-C charger for Samsung”) after exact/alias/category ranking.~~ Token-overlap semantic rank after identifier/exact/alias; **not** embeddings/vector search.
4. ~~Customer photo search: multiple-object picker when the photo contains more than one item.~~ Splits `mango and oil` / comma lists into objects the customer can pick. Does not detect objects inside pixels.
5. ~~Search UI pagination, empty-parent-category shortcuts, and identifier/model-number boost.~~ Load more, family shortcuts on empty search, barcode/model identifier boost.

### Wave C — 360° privacy (required before calling tours production-safe)

1. ~~Private object-storage upload for panoramas; never expose `original_image` on public APIs.~~ Originals are stored on the private disk as `tours/originals/{id}.txt` and omitted from public JSON. Not a commercial object-storage bucket.
2. ~~Background job: person segmentation + face detection, panorama-aware masks, sanitized derivative files (not a URL fragment).~~ `ProcessTourNodeJob` writes a separate public derivative path. **Not** person/face ML; failed titles/URLs containing `fail` stay unpublished.
3. ~~Owner preview of sanitized vs blocked failed processing; manual blur regions as geometry, not only a boolean.~~ Normalized `x,y,w,h` regions plus owner preview of the public derivative only.
4. ~~Retention/deletion of originals; documented and tested.~~ `original_expires_at` (default 30 days) and `localspot:purge-tour-originals`. Sanitized public files are kept.
5. ~~Tests for failed processing never publishing the original.~~ Failed nodes keep an empty public `image`; catalog JSON has no `original_image`.

### Wave D — architecture and UX

1. ~~Split `AppState` into repositories + one state library (Riverpod or Bloc).~~ `AuthRepository` and `CatalogRepository` wrap the API. UI state stays `ChangeNotifier` / `AppScope` (not Riverpod or Bloc).
2. ~~Typed API client; map validation errors (`errors` object) onto form fields.~~ `ApiException.fieldErrors` from Laravel `errors`; register/login show field messages.
3. ~~Remove or clearly label leftover demo/seed data on production screens.~~ Offline/bundled catalog shows a sample-data banner; release builds do not prefill demo login.
4. ~~Inventory, promotions, and tour editor: disable double-submit while a write is in flight.~~ `writeBusy` plus per-form busy flags on listing, promo, tour, store register, staff, and auth submits.
5. Optional in-tour product hotspots (later; not a launch blocker).

### Wave E — production operations (do not claim done until hosted)

1. HTTPS reverse proxy; MySQL not on the public internet; secrets outside git/images.
2. Restore drill of a real MySQL backup into staging.
3. Error reporting, uptime, map/AI quota and budget alerts.
4. Commercial map-tile and routing license + on-screen attribution for the provider you ship.
5. Demo login shortcuts off; token expiry/revocation verified against the production API.

### Out of scope (do not implement)

- Cart, checkout, payments, delivery, rider tracking.
- Third-party Street View / Mapillary / KartaView / Panoramax.
- Background tracking of customers.
- Nationwide coverage claims; participating sellers only.

---

## Final Architecture Decision
Keep one Flutter app backed by a modular Laravel REST API and MySQL. The original six phases are reported by the project owner as technically complete; this revision specifies functional UI, stronger AI identification/search and privacy-safe 360° tours as the next enhancements.

The app must be fully interactive, not a static prototype: every visible control has a real action and screens use persisted API data with loading, empty, validation, permission and error handling. Product search supports all lawful product categories and combines exact/keyword search, taxonomy expansion, aliases, semantic text retrieval and visual similarity; exact identifiers take priority over weak semantic guesses. Broad queries such as “food near me”, “tech” and “hardware” must return appropriate category descendants and nearby listings.

Product image recognition combines visual classification/detection, OCR, optional barcode lookup and catalog-image similarity. It returns ranked suggestions and unknown fields rather than fabricated details; store owners confirm identity, price, unit, availability and relevant specifications before a listing is saved.

Keep the owner-created 360° store tour as an app-owned feature. Original panoramas remain private while a background job detects and blurs whole people where feasible, applies face detection as an additional pass, creates sanitized derivatives, and records processing status. The owner reviews the sanitized result and can add manual masks. Only sanitized derivatives may be published; failed/uncertain processing blocks publication. Keep originals private according to a documented retention policy, and do not promise perfect anonymity.

Preserve the in-app 2D map, foreground live location, in-app route preview, Docker Desktop + WSL 2 + Laravel Sail for local backend development, and a separate hardened production image/configuration. Production readiness still depends on security, quality evaluation, tests, backups, monitoring and controlled releases—not Docker alone.
