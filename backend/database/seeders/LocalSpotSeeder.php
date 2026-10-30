<?php

namespace Database\Seeders;

use App\Models\Product;
use App\Models\ProductAlias;
use App\Models\Promotion;
use App\Models\Report;
use App\Models\Store;
use App\Models\StoreProduct;
use App\Models\StoreTour;
use App\Models\TourConnection;
use App\Models\TourNode;
use App\Support\TourPrivacy;
use App\Models\User;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\DB;
class LocalSpotSeeder extends Seeder
{
    public function run(): void
    {

        $users = [
            ['name' => 'Maria Santos', 'email' => 'maria@localspot.ph', 'role' => 'customer'],
            ['name' => 'Aling Nena', 'email' => 'nena@localspot.ph', 'role' => 'owner'],
            ['name' => 'Mang Tonyo', 'email' => 'tonyo@localspot.ph', 'role' => 'owner'],
            ['name' => 'Ana Cruz', 'email' => 'ana@localspot.ph', 'role' => 'staff'],
            ['name' => 'Admin Reyes', 'email' => 'admin@localspot.ph', 'role' => 'admin'],
            ['name' => 'Lito Mercado', 'email' => 'lito@localspot.ph', 'role' => 'owner'],
            ['name' => 'Bea Tan', 'email' => 'bea@localspot.ph', 'role' => 'owner'],
        ];
        foreach ($users as $row) {
            User::create([...$row, 'password' => 'demo', 'status' => 'active']);
        }

        $now = now();
        $familyIds = [];
        foreach ([
            ['kind' => 'family', 'name' => 'Food', 'slug' => 'food'],
            ['kind' => 'family', 'name' => 'Tech', 'slug' => 'tech'],
            ['kind' => 'family', 'name' => 'Hardware', 'slug' => 'hardware-family'],
            ['kind' => 'family', 'name' => 'Clothing', 'slug' => 'clothing-family'],
            ['kind' => 'family', 'name' => 'Household', 'slug' => 'household-family'],
        ] as $family) {
            $familyIds[$family['slug']] = DB::table('categories')->insertGetId([...$family, 'created_at' => $now, 'updated_at' => $now]);
        }
        foreach ([
            ['kind' => 'product', 'name' => 'Produce', 'slug' => 'produce', 'parent' => 'food'],
            ['kind' => 'product', 'name' => 'Groceries', 'slug' => 'groceries', 'parent' => 'food'],
            ['kind' => 'product', 'name' => 'Staples', 'slug' => 'staples', 'parent' => 'food'],
            ['kind' => 'product', 'name' => 'Bakery', 'slug' => 'bakery', 'parent' => 'food'],
            ['kind' => 'product', 'name' => 'Street food', 'slug' => 'street-food', 'parent' => 'food'],
            ['kind' => 'product', 'name' => 'Hardware', 'slug' => 'hardware', 'parent' => 'hardware-family'],
            ['kind' => 'product', 'name' => 'Tools', 'slug' => 'tools', 'parent' => 'hardware-family'],
            ['kind' => 'product', 'name' => 'Electronics', 'slug' => 'electronics', 'parent' => 'tech'],
            ['kind' => 'product', 'name' => 'Appliances', 'slug' => 'appliances', 'parent' => 'tech'],
            ['kind' => 'product', 'name' => 'Clothing', 'slug' => 'clothing', 'parent' => 'clothing-family'],
            ['kind' => 'product', 'name' => 'Household', 'slug' => 'household', 'parent' => 'household-family'],
            ['kind' => 'product', 'name' => 'Automotive', 'slug' => 'automotive', 'parent' => 'household-family'],
            ['kind' => 'store', 'name' => 'Sari-sari store', 'slug' => 'sari-sari', 'parent' => null],
            ['kind' => 'store', 'name' => 'Fruit & vegetable vendor', 'slug' => 'fruit-vegetable', 'parent' => null],
            ['kind' => 'store', 'name' => 'Hardware / construction', 'slug' => 'hardware-store', 'parent' => null],
            ['kind' => 'store', 'name' => 'Electronics / technology', 'slug' => 'electronics-store', 'parent' => null],
        ] as $category) {
            $parent = $category['parent'];
            unset($category['parent']);
            DB::table('categories')->insert([
                ...$category,
                'parent_id' => $parent ? $familyIds[$parent] : null,
                'created_at' => $now,
                'updated_at' => $now,
            ]);
        }

        $nena = User::where('email', 'nena@localspot.ph')->first();
        $tonyo = User::where('email', 'tonyo@localspot.ph')->first();
        $ana = User::where('email', 'ana@localspot.ph')->first();
        $maria = User::where('email', 'maria@localspot.ph')->first();
        $lito = User::where('email', 'lito@localspot.ph')->first();
        $bea = User::where('email', 'bea@localspot.ph')->first();

        $s1 = Store::create([
            'owner_id' => $nena->id, 'name' => "Aling Nena's Sari-Sari", 'type' => 'sariSari', 'status' => 'approved',
            'lat' => 14.6198, 'lng' => 121.0562, 'barangay' => 'Socorro', 'city' => 'Quezon City',
            'address' => '12 P. Tuazon Blvd', 'landmark' => 'Beside the waiting shed near Aurora Blvd',
            'schedule' => 'Daily 6:00 AM – 10:00 PM', 'is_mobile' => false,
            'image' => 'https://images.unsplash.com/photo-1604719312566-8912e9227c6a?auto=format&fit=crop&w=900&q=80',
        ]);
        $s2 = Store::create([
            'owner_id' => $tonyo->id, 'name' => "Mang Tonyo's Fruit Stall", 'type' => 'fruitVegetable', 'status' => 'approved',
            'lat' => 14.6184, 'lng' => 121.0539, 'barangay' => 'South Triangle', 'city' => 'Quezon City',
            'address' => 'Farmer’s Market inner aisle 4', 'landmark' => 'Near the mango row, green tarpaulin',
            'schedule' => 'Tue–Sun 5:00 AM – 6:00 PM', 'is_mobile' => false,
            'image' => 'https://images.unsplash.com/photo-1488459716781-31db52582fe9?auto=format&fit=crop&w=900&q=80',
        ]);
        $s3 = Store::create([
            'owner_id' => $nena->id, 'name' => 'QuickGo Mini Mart', 'type' => 'convenience', 'status' => 'approved',
            'lat' => 14.6216, 'lng' => 121.0589, 'barangay' => 'E. Rodriguez', 'city' => 'Quezon City',
            'address' => 'G/F Gateway-adjacent strip', 'landmark' => 'Across the jeepney stop',
            'schedule' => 'Open 24 hours', 'is_mobile' => false,
            'image' => 'https://images.unsplash.com/photo-1604719311684-14b4bd8fda7c?auto=format&fit=crop&w=900&q=80',
        ]);
        Store::create([
            'owner_id' => $tonyo->id, 'name' => 'Kuya Ben Mobile Taho', 'type' => 'streetVendor', 'status' => 'approved',
            'lat' => 14.6171, 'lng' => 121.0551, 'barangay' => 'Kamuning', 'city' => 'Quezon City',
            'address' => 'Selling along Scout area', 'landmark' => 'Usually near the barangay hall mornings',
            'schedule' => 'Mon–Sat 6:00 AM – 11:00 AM', 'is_mobile' => true,
            'image' => 'https://images.unsplash.com/photo-1540189549336-e6e99c3679fe?auto=format&fit=crop&w=900&q=80',
        ]);
        Store::create([
            'owner_id' => $nena->id, 'name' => 'Bagong Palengke Dry Goods', 'type' => 'marketStall', 'status' => 'pending',
            'lat' => 14.6228, 'lng' => 121.0524, 'barangay' => 'Pinyahan', 'city' => 'Quezon City',
            'address' => 'Stall 18, wet & dry section', 'landmark' => 'Blue umbrella, next to rice sacks',
            'schedule' => 'Daily 5:30 AM – 5:00 PM', 'is_mobile' => false,
        ]);
        $hardware = Store::create([
            'owner_id' => $lito->id, 'name' => 'Cubao Hardware & Tools', 'type' => 'hardware', 'status' => 'approved',
            'lat' => 14.6209, 'lng' => 121.0548, 'barangay' => 'Socorro', 'city' => 'Quezon City',
            'address' => '18 Gen. Romulo Ave', 'landmark' => 'Orange facade beside the pawnshop',
            'schedule' => 'Mon–Sat 7:30 AM – 7:00 PM', 'is_mobile' => false,
            'image' => 'https://images.unsplash.com/photo-1504148455328-c376907d081c?auto=format&fit=crop&w=900&q=80',
        ]);
        $gadgets = Store::create([
            'owner_id' => $bea->id, 'name' => 'QC Gadget Hub', 'type' => 'electronics', 'status' => 'approved',
            'lat' => 14.6189, 'lng' => 121.0574, 'barangay' => 'Cubao', 'city' => 'Quezon City',
            'address' => '2/F Farmermarket annex', 'landmark' => 'Next to the phone repair alley',
            'schedule' => 'Daily 10:00 AM – 8:00 PM', 'is_mobile' => false,
            'image' => 'https://images.unsplash.com/photo-1519389950473-47ba0277781c?auto=format&fit=crop&w=900&q=80',
        ]);

        DB::table('store_members')->insert([
            'store_id' => $s1->id,
            'user_id' => $ana->id,
            'membership_role' => 'staff',
            'can_inventory' => true,
            'can_promotions' => false,
            'can_location' => false,
            'created_at' => now(),
            'updated_at' => now(),
        ]);

        $catalog = [
            ['Carabao mango', 'Produce', '', 'per kilo', ['mangga', 'indian mango', 'mango'], null, 'https://images.unsplash.com/photo-1553279768-865429fa0078?auto=format&fit=crop&w=800&q=80'],
            ['Cooking oil', 'Groceries', 'Minola', '1 L bottle', ['mantika', 'vegetable oil'], '4807770123456', 'https://images.unsplash.com/photo-1474979266404-7eaacbcd87c5?auto=format&fit=crop&w=800&q=80'],
            ['Well-milled rice', 'Staples', '', 'per kilo', ['bigas', 'sinandomeng', 'rice'], null, 'https://images.unsplash.com/photo-1586201375761-83865001e31c?auto=format&fit=crop&w=800&q=80'],
            ['Pan de sal', 'Bakery', '', 'per piece', ['pandesal', 'bread'], null, 'https://images.unsplash.com/photo-1509440159596-0249088772ff?auto=format&fit=crop&w=800&q=80'],
            ['Lakatan banana', 'Produce', '', 'per kilo', ['saging', 'banana', 'lakatan'], null, 'https://images.unsplash.com/photo-1571771894821-ce9b6c11b08e?auto=format&fit=crop&w=800&q=80'],
            ['Canned sardines', 'Groceries', "Young's Town", '155 g can', ['sardinas', 'sardines'], '4800015123456', 'https://images.unsplash.com/photo-1598515214211-89d3c73ae83b?auto=format&fit=crop&w=800&q=80'],
            ['Taho', 'Street food', '', 'per cup', ['taho', 'soy pudding'], null, 'https://images.unsplash.com/photo-1569718212165-3a8278d5f624?auto=format&fit=crop&w=800&q=80'],
            ['Instant noodles', 'Groceries', 'Lucky Me', '55 g pack', ['pancit canton', 'noodles', 'lucky me'], null, 'https://images.unsplash.com/photo-1612929635977-2bddc1c0c0b0?auto=format&fit=crop&w=800&q=80'],
            ['Claw hammer', 'Hardware', 'Stanley', '16 oz', ['martilyo', 'hammer'], '4808880123456', 'https://images.unsplash.com/photo-1586864387963-0a911f4c0c1d?auto=format&fit=crop&w=800&q=80'],
            ['USB-C cable', 'Electronics', 'Anker', '1 m', ['type c cable', 'charger cable', 'usb c'], '4809990123456', 'https://images.unsplash.com/photo-1583863788434-e58a36330cf0?auto=format&fit=crop&w=800&q=80'],
            ['Rubber slippers', 'Clothing', 'Havaianas', 'pair', ['tsinelas', 'slippers', 'flip flops'], null, 'https://images.unsplash.com/photo-1603487742131-4160ec999275?auto=format&fit=crop&w=800&q=80'],
            ['Motorcycle engine oil', 'Automotive', 'Motul', '1 L bottle', ['motor oil', 'engine oil'], '4811110123456', 'https://images.unsplash.com/photo-1486262715619-67b85e0b08d3?auto=format&fit=crop&w=800&q=80'],
        ];
        $products = [];
        foreach ($catalog as $row) {
            $product = Product::create([
                'name' => $row[0], 'category' => $row[1], 'brand' => $row[2],
                'package_size' => $row[3], 'barcode' => $row[5], 'image' => $row[6], 'status' => 'active',
                'specs' => match ($row[1]) {
                    'Produce' => ['variety' => $row[0]],
                    'Hardware' => ['material' => 'steel'],
                    'Electronics' => ['model' => $row[2] ?: $row[0], 'capacity' => $row[3], 'compatibility' => 'USB-C Samsung Type-C phones'],
                    default => [],
                },
            ]);
            foreach ($row[4] as $alias) {
                ProductAlias::create(['product_id' => $product->id, 'alias' => $alias]);
            }
            $products[] = $product;
        }

        $now = now();
        $listings = [
            [$s1->id, $products[1]->id, 98, 'bottle', 8, 'in_stock', $now->copy()->subHours(3)],
            [$s1->id, $products[2]->id, 56, 'kilo', 20, 'in_stock', $now->copy()->subHours(5)],
            [$s1->id, $products[3]->id, 4, 'piece', 40, 'low', $now->copy()->subHour()],
            [$s1->id, $products[5]->id, 28, 'can', 15, 'in_stock', $now->copy()->subHours(8)],
            [$s1->id, $products[7]->id, 16, 'pack', 24, 'in_stock', $now->copy()->subMinutes(40)],
            [$s2->id, $products[0]->id, 180, 'kilo', 12, 'in_stock', $now->copy()->subHours(2)],
            [$s2->id, $products[4]->id, 70, 'kilo', 18, 'in_stock', $now->copy()->subHours(2)],
            [$s3->id, $products[1]->id, 112, 'bottle', 30, 'in_stock', $now->copy()->subHours(12)],
            [$s3->id, $products[5]->id, 32, 'can', 40, 'in_stock', $now->copy()->subHours(12)],
            [$s3->id, $products[7]->id, 18, 'pack', 50, 'in_stock', $now->copy()->subHours(6)],
        ];
        $tahoStore = Store::where('name', 'Kuya Ben Mobile Taho')->first();
        $listings[] = [$tahoStore->id, $products[6]->id, 25, 'cup', 20, 'in_stock', $now->copy()->subHour()];
        $listings[] = [$hardware->id, $products[8]->id, 285, 'piece', 14, 'in_stock', $now->copy()->subHours(4)];
        $listings[] = [$gadgets->id, $products[9]->id, 249, 'piece', 22, 'in_stock', $now->copy()->subHours(6)];
        $listings[] = [$hardware->id, $products[10]->id, 120, 'pair', 18, 'in_stock', $now->copy()->subHours(9)];
        $listings[] = [$hardware->id, $products[11]->id, 390, 'bottle', 7, 'low', $now->copy()->subHours(2)];

        foreach ($listings as $row) {
            StoreProduct::create([
                'store_id' => $row[0], 'product_id' => $row[1], 'price' => $row[2], 'unit' => $row[3],
                'quantity' => $row[4], 'availability' => $row[5], 'status' => 'active', 'last_confirmed_at' => $row[6],
            ]);
        }

        Promotion::create([
            'store_id' => $s2->id, 'title' => 'Mangga of the week',
            'offer' => 'Ripe carabao mango ₱165/kilo until Sunday',
            'starts_at' => $now->copy()->subDay(), 'ends_at' => $now->copy()->addDays(5),
            'sponsored' => true, 'status' => 'approved',
        ]);
        Promotion::create([
            'store_id' => $s1->id, 'title' => 'Pandesal morning bundle',
            'offer' => '10 pieces for ₱35 before 8 AM',
            'starts_at' => $now, 'ends_at' => $now->copy()->addDays(10),
            'sponsored' => true, 'status' => 'approved',
        ]);

        $tour = StoreTour::create(['store_id' => $s1->id, 'title' => 'Walk through Aling Nena’s', 'status' => 'published']);
        $n1 = TourNode::create(['store_tour_id' => $tour->id, 'title' => 'Storefront', 'image' => 'https://images.unsplash.com/photo-1604719312566-8912e9227c6a?auto=format&fit=crop&w=1200&q=80', 'sort_order' => 1, 'privacy_status' => 'ready', 'owner_reviewed' => true, 'original_expires_at' => now()->addDays(30)]);
        $n2 = TourNode::create(['store_tour_id' => $tour->id, 'title' => 'Grocery shelf', 'image' => 'https://images.unsplash.com/photo-1578916171728-46686eac8d58?auto=format&fit=crop&w=1200&q=80', 'sort_order' => 2, 'privacy_status' => 'ready', 'owner_reviewed' => true, 'original_expires_at' => now()->addDays(30)]);
        $n3 = TourNode::create(['store_tour_id' => $tour->id, 'title' => 'Counter', 'image' => 'https://images.unsplash.com/photo-1534723452862-4c874018d66d?auto=format&fit=crop&w=1200&q=80', 'sort_order' => 3, 'privacy_status' => 'ready', 'owner_reviewed' => true, 'original_expires_at' => now()->addDays(30)]);
        $n1->update(['original_image' => TourPrivacy::stage('private://tour-originals/storefront', $n1->id)]);
        $n2->update(['original_image' => TourPrivacy::stage('private://tour-originals/aisle', $n2->id)]);
        $n3->update(['original_image' => TourPrivacy::stage('private://tour-originals/counter', $n3->id)]);
        foreach ([[$n1, $n2], [$n2, $n1], [$n2, $n3], [$n3, $n2]] as $pair) {
            TourConnection::create(['from_node_id' => $pair[0]->id, 'to_node_id' => $pair[1]->id]);
        }

        Report::create([
            'user_id' => $maria->id,
            'target' => 'QuickGo Mini Mart · cooking oil price',
            'reason' => 'Listed ₱112 but the shelf tag yesterday was ₱108.',
        ]);
    }
}
