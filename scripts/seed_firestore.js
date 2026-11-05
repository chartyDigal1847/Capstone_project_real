/**
 * LocalSpot — Firestore Demo Data Seeder
 *
 * Usage:
 *   1. Go to Firebase Console → Project Settings → Service accounts
 *   2. Click "Generate new private key" and save it as serviceAccountKey.json
 *      inside this scripts/ folder (it is git-ignored).
 *   3. Run:  node scripts/seed_firestore.js
 *
 * This script creates demo stores, products, listings, promotions and tours
 * in your Firestore database. It also creates Firebase Auth accounts for the
 * demo users using the password "demo".
 *
 * Safe to run multiple times — it checks for existing docs by numericId.
 */

const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getAuth } = require('firebase-admin/auth');
const path = require('path');

const serviceAccount = require(path.join(__dirname, 'serviceAccountKey.json'));

initializeApp({ credential: cert(serviceAccount) });

const db = getFirestore();
const auth = getAuth();

// ── Helper ────────────────────────────────────────────────────────────────────
const now = new Date().toISOString();
const hoursAgo = (h) => new Date(Date.now() - h * 3600000).toISOString();
const daysFromNow = (d) => new Date(Date.now() + d * 86400000).toISOString();

function encodeGeohash(latitude, longitude, precision = 7) {
  const alphabet = '0123456789bcdefghjkmnpqrstuvwxyz';
  let latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  let even = true, bits = 0, value = 0, hash = '';
  while (hash.length < precision) {
    if (even) {
      const middle = (lngMin + lngMax) / 2;
      if (longitude >= middle) { value = (value << 1) | 1; lngMin = middle; }
      else { value <<= 1; lngMax = middle; }
    } else {
      const middle = (latMin + latMax) / 2;
      if (latitude >= middle) { value = (value << 1) | 1; latMin = middle; }
      else { value <<= 1; latMax = middle; }
    }
    even = !even;
    if (++bits === 5) {
      hash += alphabet[value];
      bits = 0;
      value = 0;
    }
  }
  return hash;
}

async function upsert(collection, numericId, data) {
  const snap = await db.collection(collection).where('numericId', '==', numericId).limit(1).get();
  if (snap.empty) {
    await db.collection(collection).add({ numericId, ...data });
    console.log(`  + ${collection}/${numericId}`);
  } else {
    console.log(`  ~ ${collection}/${numericId} (already exists, skipped)`);
  }
}

// ── Demo Auth Users ───────────────────────────────────────────────────────────
const demoUsers = [
  { uid: 'demo-customer-1', email: 'maria@localspot.ph',  displayName: 'Maria Santos',  role: 'customer', numericId: 1 },
  { uid: 'demo-owner-2',    email: 'nena@localspot.ph',   displayName: 'Aling Nena',    role: 'owner',    numericId: 2, ownedStoreIds: [1] },
  { uid: 'demo-owner-3',    email: 'tonyo@localspot.ph',  displayName: 'Mang Tonyo',    role: 'owner',    numericId: 3, ownedStoreIds: [2] },
  { uid: 'demo-staff-4',    email: 'ana@localspot.ph',    displayName: 'Ana Cruz',      role: 'staff',    numericId: 4, memberStoreIds: [1] },
  { uid: 'demo-admin-5',    email: 'admin@localspot.ph',  displayName: 'Admin Reyes',   role: 'admin',    numericId: 5 },
  { uid: 'demo-owner-6',    email: 'lito@localspot.ph',   displayName: 'Lito Mercado',  role: 'owner',    numericId: 6, ownedStoreIds: [6] },
  { uid: 'demo-owner-7',    email: 'bea@localspot.ph',    displayName: 'Bea Tan',       role: 'owner',    numericId: 7, ownedStoreIds: [7] },
];

async function seedUsers() {
  console.log('\n── Users & Auth accounts ──');
  for (const u of demoUsers) {
    // Auth account
    try {
      await auth.getUser(u.uid);
      console.log(`  ~ auth/${u.email} (already exists)`);
    } catch (_) {
      try {
        await auth.createUser({ uid: u.uid, email: u.email, password: 'demo1234', displayName: u.displayName });
        console.log(`  + auth/${u.email}`);
      } catch (err) {
        console.warn(`  ! auth/${u.email}: ${err.message}`);
      }
    }
    // Firestore user doc
    const existing = await db.collection('users').doc(u.uid).get();
    if (!existing.exists) {
      await db.collection('users').doc(u.uid).set({
        numericId: u.numericId,
        name: u.displayName,
        email: u.email,
        role: u.role,
        ownedStoreIds: u.ownedStoreIds || [],
        memberStoreIds: u.memberStoreIds || [],
        storeGrants: [],
      });
      console.log(`  + users/${u.uid}`);
    } else {
      console.log(`  ~ users/${u.uid} (already exists, skipped)`);
    }
  }
}

// ── Stores ────────────────────────────────────────────────────────────────────
const stores = [
  {
    numericId: 1, ownerId: 2, ownerUid: 'demo-owner-2',
    name: "Aling Nena's Sari-Sari", type: 'sariSari', status: 'approved',
    lat: 14.6198, lng: 121.0562,
    barangay: 'Socorro', city: 'Quezon City',
    address: '12 P. Tuazon Blvd',
    landmark: 'Beside the waiting shed near Aurora Blvd',
    schedule: 'Daily 6:00 AM – 10:00 PM',
    is_mobile: false, location_mode: 'fixed',
    image: 'https://images.unsplash.com/photo-1604719312566-8912e9227c6a?auto=format&fit=crop&w=900&q=80',
    verification_note: '', location_updated_at: now,
  },
  {
    numericId: 2, ownerId: 3, ownerUid: 'demo-owner-3',
    name: "Mang Tonyo's Fruit Stall", type: 'fruitVegetable', status: 'approved',
    lat: 14.6184, lng: 121.0539,
    barangay: 'South Triangle', city: 'Quezon City',
    address: "Farmer's Market inner aisle 4",
    landmark: 'Near the mango row, green tarpaulin',
    schedule: 'Tue–Sun 5:00 AM – 6:00 PM',
    is_mobile: false, location_mode: 'fixed',
    image: 'https://images.unsplash.com/photo-1488459716781-31db52582fe9?auto=format&fit=crop&w=900&q=80',
    verification_note: '', location_updated_at: now,
  },
  {
    numericId: 3, ownerId: 2, ownerUid: 'demo-owner-2',
    name: 'QuickGo Mini Mart', type: 'convenience', status: 'approved',
    lat: 14.6216, lng: 121.0589,
    barangay: 'E. Rodriguez', city: 'Quezon City',
    address: 'G/F Gateway-adjacent strip',
    landmark: 'Across the jeepney stop',
    schedule: 'Open 24 hours',
    is_mobile: false, location_mode: 'fixed',
    image: 'https://images.unsplash.com/photo-1604719311684-14b4bd8fda7c?auto=format&fit=crop&w=900&q=80',
    verification_note: '', location_updated_at: now,
  },
  {
    numericId: 4, ownerId: 3, ownerUid: 'demo-owner-3',
    name: 'Kuya Ben Mobile Taho', type: 'streetVendor', status: 'approved',
    lat: 14.6171, lng: 121.0551,
    barangay: 'Kamuning', city: 'Quezon City',
    address: 'Selling along Scout area',
    landmark: 'Usually near the barangay hall mornings',
    schedule: 'Mon–Sat 6:00 AM – 11:00 AM',
    is_mobile: true, location_mode: 'regular',
    image: 'https://images.unsplash.com/photo-1540189549336-e6e99c3679fe?auto=format&fit=crop&w=900&q=80',
    verification_note: '', location_updated_at: now,
  },
  {
    numericId: 5, ownerId: 2, ownerUid: 'demo-owner-2',
    name: 'Bagong Palengke Dry Goods', type: 'marketStall', status: 'pending',
    lat: 14.6228, lng: 121.0524,
    barangay: 'Pinyahan', city: 'Quezon City',
    address: 'Stall 18, wet & dry section',
    landmark: 'Blue umbrella, next to rice sacks',
    schedule: 'Daily 5:30 AM – 5:00 PM',
    is_mobile: false, location_mode: 'fixed',
    image: null, verification_note: '', location_updated_at: now,
  },
  {
    numericId: 6, ownerId: 6, ownerUid: 'demo-owner-6',
    name: 'Cubao Hardware & Tools', type: 'hardware', status: 'approved',
    lat: 14.6209, lng: 121.0548,
    barangay: 'Socorro', city: 'Quezon City',
    address: '18 Gen. Romulo Ave',
    landmark: 'Orange facade beside the pawnshop',
    schedule: 'Mon–Sat 7:30 AM – 7:00 PM',
    is_mobile: false, location_mode: 'fixed',
    image: 'https://images.unsplash.com/photo-1504148455328-c376907d081c?auto=format&fit=crop&w=900&q=80',
    verification_note: '', location_updated_at: now,
  },
  {
    numericId: 7, ownerId: 7, ownerUid: 'demo-owner-7',
    name: 'QC Gadget Hub', type: 'electronics', status: 'approved',
    lat: 14.6189, lng: 121.0574,
    barangay: 'Cubao', city: 'Quezon City',
    address: '2/F Farmermarket annex',
    landmark: 'Next to the phone repair alley',
    schedule: 'Daily 10:00 AM – 8:00 PM',
    is_mobile: false, location_mode: 'fixed',
    image: 'https://images.unsplash.com/photo-1519389950473-47ba0277781c?auto=format&fit=crop&w=900&q=80',
    verification_note: '', location_updated_at: now,
  },
];

// ── Products ──────────────────────────────────────────────────────────────────
const products = [
  { numericId: 1,  name: 'Carabao mango',         category: 'Produce',     brand: '',          package_size: 'per kilo',    aliases: ['mangga','indian mango','mango'],          barcode: null,           image: 'https://images.unsplash.com/photo-1553279768-865429fa0078?auto=format&fit=crop&w=800&q=80', attributes: { variety: 'Carabao' }, createdByUid: 'demo-owner-3' },
  { numericId: 2,  name: 'Cooking oil',            category: 'Groceries',   brand: 'Minola',    package_size: '1 L bottle',  aliases: ['mantika','vegetable oil'],                barcode: '4807770123456', image: 'https://images.unsplash.com/photo-1474979266404-7eaacbcd87c5?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-2' },
  { numericId: 3,  name: 'Well-milled rice',       category: 'Staples',     brand: '',          package_size: 'per kilo',    aliases: ['bigas','sinandomeng','rice'],              barcode: null,           image: 'https://images.unsplash.com/photo-1586201375761-83865001e31c?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-2' },
  { numericId: 4,  name: 'Pan de sal',             category: 'Bakery',      brand: '',          package_size: 'per piece',   aliases: ['pandesal','bread'],                       barcode: null,           image: 'https://images.unsplash.com/photo-1509440159596-0249088772ff?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-2' },
  { numericId: 5,  name: 'Lakatan banana',         category: 'Produce',     brand: '',          package_size: 'per kilo',    aliases: ['saging','banana','lakatan'],               barcode: null,           image: 'https://images.unsplash.com/photo-1571771894821-ce9b6c11b08e?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-3' },
  { numericId: 6,  name: 'Canned sardines',        category: 'Groceries',   brand: "Young's Town", package_size: '155 g can', aliases: ['sardinas','sardines'],                  barcode: '4800015123456', image: 'https://images.unsplash.com/photo-1598515214211-89d3c73ae83b?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-2' },
  { numericId: 7,  name: 'Taho',                   category: 'Street food', brand: '',          package_size: 'per cup',     aliases: ['taho','soy pudding'],                     barcode: null,           image: 'https://images.unsplash.com/photo-1569718212165-3a8278d5f624?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-3' },
  { numericId: 8,  name: 'Instant noodles',        category: 'Groceries',   brand: 'Lucky Me',  package_size: '55 g pack',   aliases: ['pancit canton','noodles','lucky me'],     barcode: null,           image: 'https://images.unsplash.com/photo-1612929635977-2bddc1c0c0b0?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-2' },
  { numericId: 9,  name: 'Claw hammer',            category: 'Hardware',    brand: 'Stanley',   package_size: '16 oz',       aliases: ['martilyo','hammer'],                      barcode: '4808880123456', image: 'https://images.unsplash.com/photo-1586864387963-0a911f4c0c1d?auto=format&fit=crop&w=800&q=80', attributes: { material: 'steel' }, createdByUid: 'demo-owner-6' },
  { numericId: 10, name: 'USB-C cable',            category: 'Electronics', brand: 'Anker',     package_size: '1 m',         aliases: ['type c cable','charger cable','usb c'],   barcode: '4809990123456', image: 'https://images.unsplash.com/photo-1583863788434-e58a36330cf0?auto=format&fit=crop&w=800&q=80', attributes: { model: 'USB-C', capacity: '1 m', compatibility: 'USB-C Samsung Type-C phones' }, createdByUid: 'demo-owner-7' },
  { numericId: 11, name: 'Rubber slippers',        category: 'Clothing',    brand: 'Havaianas', package_size: 'pair',        aliases: ['tsinelas','slippers','flip flops'],       barcode: null,           image: 'https://images.unsplash.com/photo-1603487742131-4160ec999275?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-6' },
  { numericId: 12, name: 'Motorcycle engine oil',  category: 'Automotive',  brand: 'Motul',     package_size: '1 L bottle',  aliases: ['motor oil','engine oil'],                 barcode: '4811110123456', image: 'https://images.unsplash.com/photo-1486262715619-67b85e0b08d3?auto=format&fit=crop&w=800&q=80', attributes: {}, createdByUid: 'demo-owner-6' },
];

// ── Listings ──────────────────────────────────────────────────────────────────
const listings = [
  { numericId: 1,  storeId: 1, productId: 2,  price: 98,  unit: 'bottle', quantity: 8,  availability: 'in_stock', last_confirmed_at: hoursAgo(3),  status: 'active', ownerUid: 'demo-owner-2' },
  { numericId: 2,  storeId: 1, productId: 3,  price: 56,  unit: 'kilo',   quantity: 20, availability: 'in_stock', last_confirmed_at: hoursAgo(5),  status: 'active', ownerUid: 'demo-owner-2' },
  { numericId: 3,  storeId: 1, productId: 4,  price: 4,   unit: 'piece',  quantity: 40, availability: 'low',      last_confirmed_at: hoursAgo(1),  status: 'active', ownerUid: 'demo-owner-2' },
  { numericId: 4,  storeId: 1, productId: 6,  price: 28,  unit: 'can',    quantity: 15, availability: 'in_stock', last_confirmed_at: hoursAgo(8),  status: 'active', ownerUid: 'demo-owner-2' },
  { numericId: 5,  storeId: 1, productId: 8,  price: 16,  unit: 'pack',   quantity: 24, availability: 'in_stock', last_confirmed_at: hoursAgo(0.7),status: 'active', ownerUid: 'demo-owner-2' },
  { numericId: 6,  storeId: 2, productId: 1,  price: 180, unit: 'kilo',   quantity: 12, availability: 'in_stock', last_confirmed_at: hoursAgo(2),  status: 'active', ownerUid: 'demo-owner-3' },
  { numericId: 7,  storeId: 2, productId: 5,  price: 70,  unit: 'kilo',   quantity: 18, availability: 'in_stock', last_confirmed_at: hoursAgo(2),  status: 'active', ownerUid: 'demo-owner-3' },
  { numericId: 8,  storeId: 3, productId: 2,  price: 112, unit: 'bottle', quantity: 30, availability: 'in_stock', last_confirmed_at: hoursAgo(12), status: 'active', ownerUid: 'demo-owner-2' },
  { numericId: 9,  storeId: 3, productId: 6,  price: 32,  unit: 'can',    quantity: 40, availability: 'in_stock', last_confirmed_at: hoursAgo(12), status: 'active', ownerUid: 'demo-owner-2' },
  { numericId: 10, storeId: 3, productId: 8,  price: 18,  unit: 'pack',   quantity: 50, availability: 'in_stock', last_confirmed_at: hoursAgo(6),  status: 'active', ownerUid: 'demo-owner-2' },
  { numericId: 11, storeId: 4, productId: 7,  price: 25,  unit: 'cup',    quantity: 20, availability: 'in_stock', last_confirmed_at: hoursAgo(1),  status: 'active', ownerUid: 'demo-owner-3' },
  { numericId: 12, storeId: 6, productId: 9,  price: 285, unit: 'piece',  quantity: 14, availability: 'in_stock', last_confirmed_at: hoursAgo(4),  status: 'active', ownerUid: 'demo-owner-6' },
  { numericId: 13, storeId: 7, productId: 10, price: 249, unit: 'piece',  quantity: 22, availability: 'in_stock', last_confirmed_at: hoursAgo(6),  status: 'active', ownerUid: 'demo-owner-7' },
  { numericId: 14, storeId: 6, productId: 11, price: 120, unit: 'pair',   quantity: 18, availability: 'in_stock', last_confirmed_at: hoursAgo(9),  status: 'active', ownerUid: 'demo-owner-6' },
  { numericId: 15, storeId: 6, productId: 12, price: 390, unit: 'bottle', quantity: 7,  availability: 'low',      last_confirmed_at: hoursAgo(2),  status: 'active', ownerUid: 'demo-owner-6' },
];

// ── Promotions ────────────────────────────────────────────────────────────────
const promotions = [
  {
    numericId: 1, storeId: 2, ownerUid: 'demo-owner-3',
    title: 'Mangga of the week',
    offer: 'Ripe carabao mango ₱165/kilo until Sunday',
    starts_at: hoursAgo(24), ends_at: daysFromNow(5),
    sponsored: true, status: 'approved',
  },
  {
    numericId: 2, storeId: 1, ownerUid: 'demo-owner-2',
    title: 'Pandesal morning bundle',
    offer: '10 pieces for ₱35 before 8 AM',
    starts_at: now, ends_at: daysFromNow(10),
    sponsored: true, status: 'approved',
  },
];

// ── Tours ─────────────────────────────────────────────────────────────────────
const tours = [
  {
    numericId: 1, storeId: 1, ownerUid: 'demo-owner-2',
    title: "Walk through Aling Nena's",
    status: 'published',
    nodes: [
      {
        id: 1, title: 'Storefront',
        image: 'https://images.unsplash.com/photo-1604719312566-8912e9227c6a?auto=format&fit=crop&w=1200&q=80',
        connections: [2], privacy_status: 'ready', owner_reviewed: true,
        manual_blur: false, original_retained: false, blur_regions: [],
      },
      {
        id: 2, title: 'Inside – counter',
        image: 'https://images.unsplash.com/photo-1524678516-5d57b5b6b4bc?auto=format&fit=crop&w=1200&q=80',
        connections: [1, 3], privacy_status: 'ready', owner_reviewed: true,
        manual_blur: false, original_retained: false, blur_regions: [],
      },
      {
        id: 3, title: 'Shelves',
        image: 'https://images.unsplash.com/photo-1604719312566-8912e9227c6a?auto=format&fit=crop&w=1200&q=80',
        connections: [2], privacy_status: 'ready', owner_reviewed: true,
        manual_blur: false, original_retained: false, blur_regions: [],
      },
    ],
  },
];

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  console.log('LocalSpot Firestore Seeder');
  console.log('==========================');

  await seedUsers();

  console.log('\n── Stores ──');
  for (const s of stores) {
    await upsert('stores', s.numericId, { ...s, geohash: encodeGeohash(s.lat, s.lng) });
  }

  console.log('\n── Products ──');
  for (const p of products) await upsert('products', p.numericId, p);

  console.log('\n── Listings ──');
  for (const l of listings) await upsert('listings', l.numericId, l);

  console.log('\n── Promotions ──');
  for (const p of promotions) await upsert('promotions', p.numericId, p);

  console.log('\n── Tours ──');
  for (const t of tours) await upsert('tours', t.numericId, t);

  console.log('\n✔ Seed complete!');
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
