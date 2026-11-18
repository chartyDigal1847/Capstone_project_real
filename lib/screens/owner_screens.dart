import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cloud_firestore/cloud_firestore.dart' hide GeoPoint;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:image_picker/image_picker.dart';
import 'package:panorama_privacy_prototype/main.dart' as panorama_privacy;
import 'package:panorama_privacy_prototype/review_flow.dart' as panorama_review;
import 'package:panorama_privacy_prototype/review_model.dart'
    as panorama_review_model;
import 'package:panorama_viewer/panorama_viewer.dart';

import '../firebase/media_upload.dart';
import '../firebase/bootstrap.dart';
import '../firebase/build_mode.dart';
import '../api.dart';
import '../map_view.dart';
import '../models.dart';
import '../services/offline_psgc_locations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

class _FirebaseOwnerContext
    implements panorama_review_model.AuthenticatedOwnerContext {
  const _FirebaseOwnerContext(this.authenticatedUid);
  @override
  final String authenticatedUid;
}

Future<(double, double)?> _readOwnerMapLocation(
  BuildContext context,
  AppState app,
) async {
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (!context.mounted) return null;
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          permission == LocationPermission.deniedForever
              ? 'Allow location access in app settings to use My location.'
              : 'Location permission is required to use My location.',
        ),
        action:
            permission == LocationPermission.deniedForever
                ? SnackBarAction(
                  label: 'Settings',
                  onPressed: () => Geolocator.openAppSettings(),
                )
                : null,
      ),
    );
    return null;
  }
  await app.requestForegroundLocation();
  if (!context.mounted) return null;
  final latitude = app.deviceLat;
  final longitude = app.deviceLng;
  if (app.locationAllowed && latitude != null && longitude != null) {
    return (latitude, longitude);
  }
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(app.locationNote)));
  return null;
}

class OwnerDashboard extends StatelessWidget {
  const OwnerDashboard({
    super.key,
    required this.onAddProduct,
    required this.onInventory,
    required this.onRegister,
    required this.onPromos,
    required this.onTour,
    required this.onStaff,
    required this.onPin,
  });
  final VoidCallback onAddProduct;
  final VoidCallback onInventory;
  final VoidCallback onRegister;
  final VoidCallback onPromos;
  final VoidCallback onTour;
  final VoidCallback onStaff;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final store = app.ownedStore();
    if (store == null) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          PageHeader(
            'Home',
            subtitle:
                app.role == AppRole.staff
                    ? 'Staff workspace'
                    : 'Store owner workspace',
          ),
          const SeededDataBanner(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: EmptyNote(
              'Register your store to publish listings. Approval is required before customers can see it.',
              icon: Icons.storefront_outlined,
            ),
          ),
          const SizedBox(height: 16),
          if (app.role == AppRole.owner)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: PrimaryButton('Register a store', onPressed: onRegister),
            ),
        ],
      );
    }
    final listings = app.listingsForStore(store.id);
    final actions = [
      if (app.canEditInventory(store)) ...[
        DashTile(
          icon: Icons.add_a_photo_outlined,
          title: 'Add product',
          subtitle: 'Photo assist, then confirm',
          onTap: onAddProduct,
        ),
        DashTile(
          icon: Icons.inventory_2_outlined,
          title: 'Inventory',
          subtitle: 'Prices, units and stock',
          onTap: onInventory,
        ),
      ],
      if (app.canManagePromotions(store))
        DashTile(
          icon: Icons.campaign_outlined,
          title: 'Promotions',
          subtitle: 'Offers for review',
          onTap: onPromos,
        ),
      DashTile(
        icon: Icons.threesixty_outlined,
        title: '360° tour',
        subtitle: 'Linked store viewpoints',
        onTap: onTour,
      ),
      if (app.role == AppRole.owner)
        DashTile(
          icon: Icons.group_outlined,
          title: 'Staff',
          subtitle: 'Assign inventory, promo and live-pin grants',
          onTap: onStaff,
        ),
      if (app.managedStores().any(
        (item) => item.isMobile && app.canShareLiveLocation(item),
      ))
        DashTile(
          icon: Icons.my_location_outlined,
          title: 'Live pin',
          subtitle: 'Share a public location',
          onTap: onPin,
        ),
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        PageHeader('Home', subtitle: store.name),
        const SeededDataBanner(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                  child: NetworkPhoto(
                    store.image,
                    height: 120,
                    width: double.infinity,
                    radius: 0,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatusChip(storeStatusLabel(store.status)),
                      const SizedBox(height: 8),
                      Text(
                        store.name,
                        style: const TextStyle(
                          fontFamily: 'Georgia',
                          fontSize: 24,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        store.type.label,
                        style: const TextStyle(color: taupe),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${listings.length} active listings',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (listings.isNotEmpty)
                        Text(
                          'Last stock update ${freshness(listings.map((l) => l.lastConfirmed).reduce((a, b) => a.isAfter(b) ? a : b))}',
                          style: const TextStyle(color: taupe, fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        const SectionHeading('Store tools'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.92,
            children: actions,
          ),
        ),
      ],
    );
  }
}

class StoreRegisterPage extends StatefulWidget {
  const StoreRegisterPage({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<StoreRegisterPage> createState() => _StoreRegisterPageState();
}

class _StoreRegisterPageState extends State<StoreRegisterPage> {
  final name = TextEditingController();
  final barangay = TextEditingController();
  final city = TextEditingController();
  final address = TextEditingController();
  final landmark = TextEditingController();
  final schedule = TextEditingController(text: 'Daily 7:00 AM – 8:00 PM');
  final verification = TextEditingController();
  StoreType type = StoreType.sariSari;
  bool isMobile = false;
  bool uploadingPhoto = false;
  double photoProgress = 0;
  XFile? storePhoto;
  double lat = defaultCenterLat;
  double lng = defaultCenterLng;
  double mapCenterLat = defaultCenterLat;
  double mapCenterLng = defaultCenterLng;
  late Future<OfflinePsgcLocations> _offlineLocations;
  PsgcCityMunicipality? _selectedCity;
  PsgcBarangay? _selectedBarangay;

  // Field-level validation errors.
  String? nameError;
  String? cityError;
  String? barangayError;
  String? landmarkError;
  String? verificationError;
  bool submitting = false;
  int step = 0;

  @override
  void initState() {
    super.initState();
    _offlineLocations = OfflinePsgcLocations.load();
  }

  @override
  void dispose() {
    name.dispose();
    barangay.dispose();
    city.dispose();
    address.dispose();
    landmark.dispose();
    schedule.dispose();
    verification.dispose();
    super.dispose();
  }

  void _validate() {
    nameError = name.text.trim().isEmpty ? 'Enter a store name.' : null;
    cityError = _selectedCity == null ? 'Choose a city or municipality.' : null;
    barangayError = _selectedBarangay == null ? 'Choose a barangay.' : null;
    landmarkError = null;
    verificationError =
        verification.text.trim().isEmpty
            ? 'Add a verification note (e.g. business permit number).'
            : null;
  }

  bool get _hasErrors =>
      nameError != null ||
      cityError != null ||
      barangayError != null ||
      verificationError != null;

  void _continue() {
    var valid = false;
    setState(() {
      if (step == 0) {
        nameError = name.text.trim().isEmpty ? 'Enter a store name.' : null;
        valid = nameError == null;
      } else if (step == 1) {
        cityError =
            _selectedCity == null ? 'Choose a city or municipality.' : null;
        barangayError = _selectedBarangay == null ? 'Choose a barangay.' : null;
        valid = cityError == null && barangayError == null;
      }
      if (valid) step++;
    });
  }

  Future<void> _useMyLocation(AppState app) async {
    final point = await _readOwnerMapLocation(context, app);
    if (point == null || !mounted) return;
    setState(() {
      lat = point.$1;
      lng = point.$2;
      mapCenterLat = point.$1;
      mapCenterLng = point.$2;
    });
  }

  Future<T?> _chooseOfflineLocation<T>({
    required String title,
    required List<T> options,
    required String Function(T) labelOf,
    required String Function(T) searchTextOf,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        var query = '';
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final normalized = query.trim().toLowerCase();
            final matches =
                options
                    .where(
                      (option) =>
                          normalized.isEmpty ||
                          searchTextOf(
                            option,
                          ).toLowerCase().contains(normalized),
                    )
                    .take(100)
                    .toList();
            final media = MediaQuery.of(sheetContext);
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: media.viewInsets.bottom + 12,
                ),
                child: SizedBox(
                  height: media.size.height * 0.72,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        autofocus: true,
                        onChanged:
                            (value) => setSheetState(() => query = value),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Type to filter the offline list',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child:
                            matches.isEmpty
                                ? const Center(
                                  child: Text('No matching areas found.'),
                                )
                                : ListView.builder(
                                  itemCount: matches.length,
                                  itemBuilder: (context, index) {
                                    final option = matches[index];
                                    return ListTile(
                                      leading: const Icon(Icons.place_outlined),
                                      title: Text(labelOf(option)),
                                      onTap:
                                          () => Navigator.of(
                                            sheetContext,
                                          ).pop(option),
                                    );
                                  },
                                ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _selectOfflineCity() async {
    final catalog = await _offlineLocations;
    if (!mounted) return;
    final selected = await _chooseOfflineLocation<PsgcCityMunicipality>(
      title: 'Choose city or municipality',
      options: catalog.cities,
      labelOf: (item) => item.displayLabel,
      searchTextOf: (item) => item.searchLabel,
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedCity = selected;
      _selectedBarangay = null;
      city.text = selected.name;
      barangay.clear();
      cityError = null;
      barangayError = null;
      if (selected.latitude != null && selected.longitude != null) {
        lat = selected.latitude!;
        lng = selected.longitude!;
        mapCenterLat = selected.latitude!;
        mapCenterLng = selected.longitude!;
      }
    });
  }

  Future<void> _selectOfflineBarangay() async {
    final selectedCity = _selectedCity;
    if (selectedCity == null) return;
    final selected = await _chooseOfflineLocation<PsgcBarangay>(
      title: 'Choose barangay',
      options: selectedCity.barangays,
      labelOf: (item) => item.name,
      searchTextOf: (item) => item.name,
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedBarangay = selected;
      barangay.text = selected.name;
      barangayError = null;
      final newLat = selected.latitude ?? selectedCity.latitude;
      final newLng = selected.longitude ?? selectedCity.longitude;
      if (newLat != null && newLng != null) {
        lat = newLat;
        lng = newLng;
        mapCenterLat = newLat;
        mapCenterLng = newLng;
      }
    });
  }

  Future<void> _pickStorePhoto(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        imageQuality: 70,
      );
      if (file != null && mounted) setState(() => storePhoto = file);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Photo picker is unavailable. You can submit the application without a store photo.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        PageHeader('Store registration', onBack: widget.onBack),
        const InfoBanner(
          'Complete three short steps. Your store appears to customers after it is reviewed and approved.',
          icon: Icons.storefront_outlined,
        ),
        const SizedBox(height: 12),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'STEP ${step + 1} OF 3',
                style: const TextStyle(
                  color: taupe,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: (step + 1) / 3),
              const SizedBox(height: 12),
              Text(
                const [
                  'Business details',
                  'Store location',
                  'Final details',
                ][step],
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                const [
                  'Add the name and category customers will see.',
                  'Place the pin and describe how to find your store.',
                  'Confirm the business information for your application.',
                ][step],
                style: const TextStyle(color: taupe),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (step == 0)
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LabeledField('Business name', name),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          uploadingPhoto
                              ? null
                              : () => _pickStorePhoto(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Take photo'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          uploadingPhoto
                              ? null
                              : () => _pickStorePhoto(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Choose photo'),
                    ),
                  ],
                ),
                if (storePhoto != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Selected: ${storePhoto!.name}',
                      style: const TextStyle(color: taupe, fontSize: 12),
                    ),
                  ),
                if (uploadingPhoto) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: photoProgress == 0 ? null : photoProgress,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Uploading and preparing photo ${(photoProgress * 100).round()}%',
                    style: const TextStyle(color: taupe, fontSize: 11),
                  ),
                ],
                if (nameError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      nameError!,
                      style: const TextStyle(color: clay, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 12),
                FilterMenu<StoreType>(
                  label: 'Business category',
                  value: type,
                  items: [
                    for (final value in StoreType.values)
                      DropdownMenuItem(
                        value: value,
                        child: Text(
                          value.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => type = value);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mobile vendor'),
                  subtitle: const Text(
                    'For a stall or business that moves between locations.',
                  ),
                  value: isMobile,
                  onChanged: (v) => setState(() => isMobile = v),
                ),
              ],
            ),
          ),
        if (step == 1) ...[
          const InfoBanner(
            'Choose a city and barangay from the offline list. The map moves near that area; tap the map to place the pin at the exact store location.',
            icon: Icons.place_outlined,
          ),
          const SizedBox(height: 10),
          LocalMapView(
            stores: const [],
            centerLat: mapCenterLat,
            centerLng: mapCenterLng,
            userLat: app.deviceLat,
            userLng: app.deviceLng,
            pickedLocation: GeoPoint(lat, lng),
            onLocateUser: () => _useMyLocation(app),
            onPick: (pickedLat, pickedLng) {
              setState(() {
                lat = pickedLat;
                lng = pickedLng;
              });
            },
            height: 320,
          ),
          const SizedBox(height: 12),
        ],
        if (step == 1 || step == 2)
          SoftCard(
            child: Column(
              children: [
                if (step == 1) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'City or municipality',
                      style: TextStyle(
                        color: taupe,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _selectOfflineCity,
                      icon: const Icon(Icons.location_city_outlined),
                      label: Text(
                        _selectedCity?.displayLabel ??
                            'Choose city/municipality',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (cityError != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        cityError!,
                        style: const TextStyle(color: clay, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 10),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Barangay',
                      style: TextStyle(
                        color: taupe,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          _selectedCity == null ? null : _selectOfflineBarangay,
                      icon: const Icon(Icons.place_outlined),
                      label: Text(
                        _selectedBarangay?.name ?? 'Choose barangay',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (barangayError != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        barangayError!,
                        style: const TextStyle(color: clay, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 8),
                  LabeledField('Street address', address),
                  const SizedBox(height: 8),
                  LabeledField(
                    'More details (optional)',
                    landmark,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Map pin: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}\nBarangay centers are approximate. Adjust the pin to the storefront.',
                      style: const TextStyle(color: taupe, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Location names: Philippine Statistics Authority (PSA), PSGC Q3 2026.',
                      style: TextStyle(color: taupe, fontSize: 10),
                    ),
                  ),
                ],
                if (step == 2) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Application summary',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${name.text.trim()} · ${type.label}\n${address.text.trim()}, ${barangay.text.trim()}, ${city.text.trim()}${landmark.text.trim().isNotEmpty ? '\n${landmark.text.trim()}' : ''}',
                      style: const TextStyle(color: taupe, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const SizedBox(height: 8),
                  LabeledField('Operating hours', schedule),
                  const SizedBox(height: 8),
                  LabeledField(
                    'Verification information',
                    verification,
                    maxLines: 3,
                  ),
                  if (verificationError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        verificationError!,
                        style: const TextStyle(color: clay, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 12),
                  const InfoBanner(
                    'Your application is reviewed before the store appears to customers. Provide only details requested by the pilot team.',
                    icon: Icons.verified_user_outlined,
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 16),
        if (step > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => step--),
              child: const Text('Back'),
            ),
          ),
        if (step < 2) PrimaryButton('Continue', onPressed: _continue),
        if (step == 2)
          PrimaryButton(
            uploadingPhoto ? 'Uploading photo…' : 'Submit application',
            onPressed:
                submitting || uploadingPhoto || app.writeBusy
                    ? null
                    : () async {
                      setState(_validate);
                      if (_hasErrors) return;
                      setState(() => submitting = true);
                      String? imageAssetId;
                      if (storePhoto != null && app.apiOnline) {
                        setState(() {
                          uploadingPhoto = true;
                          photoProgress = 0;
                        });
                        try {
                          final media = await MediaUpload.uploadAndWait(
                            storePhoto!,
                            kind: 'store',
                            onProgress: (value) {
                              if (mounted) {
                                setState(() {
                                  photoProgress = value;
                                });
                              }
                            },
                          );
                          imageAssetId = media.assetId;
                        } catch (error) {
                          if (!mounted) return;
                          setState(() {
                            submitting = false;
                            uploadingPhoto = false;
                          });
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                error.toString().replaceFirst(
                                  'Bad state: ',
                                  '',
                                ),
                              ),
                            ),
                          );
                          return;
                        }
                      }
                      if (!context.mounted) return;
                      setState(() => uploadingPhoto = false);
                      app.registerStore(
                        name: name.text.trim(),
                        type: type,
                        lat: lat,
                        lng: lng,
                        barangay: barangay.text.trim(),
                        city: city.text.trim(),
                        address: address.text.trim(),
                        landmark: landmark.text.trim(),
                        schedule: schedule.text.trim(),
                        isMobile: isMobile,
                        verificationNote: verification.text.trim(),
                        imageAssetId: imageAssetId,
                      );
                      widget.onBack();
                    },
          ),
      ],
    );
  }
}

class StorePinPage extends StatefulWidget {
  const StorePinPage({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<StorePinPage> createState() => _StorePinPageState();
}

class _StorePinPageState extends State<StorePinPage> {
  double? lat;
  double? lng;
  double? mapCenterLat;
  double? mapCenterLng;

  Future<void> _useMyLocation(AppState app) async {
    final point = await _readOwnerMapLocation(context, app);
    if (point == null || !mounted) return;
    setState(() {
      lat = point.$1;
      lng = point.$2;
      mapCenterLat = point.$1;
      mapCenterLng = point.$2;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final store =
        app.managedStores().where((item) => item.isMobile).firstOrNull ??
        app.ownedStore();
    if (store == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          PageHeader('Vendor location', onBack: widget.onBack),
          const EmptyNote(
            'Register a store first.',
            icon: Icons.storefront_outlined,
          ),
        ],
      );
    }
    final pinLat = lat ?? store.lat;
    final pinLng = lng ?? store.lng;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        PageHeader('Vendor location', onBack: widget.onBack),
        const InfoBanner(
          'Drag the map to position your pin, or use My location to recenter. Fixed pins stay in place; live sharing always requires an explicit session.',
          icon: Icons.share_location_outlined,
        ),
        const SizedBox(height: 12),
        LocalMapView(
          stores: [store],
          centerLat: mapCenterLat ?? store.lat,
          centerLng: mapCenterLng ?? store.lng,
          userLat: app.deviceLat,
          userLng: app.deviceLng,
          pickedLocation: GeoPoint(pinLat, pinLng),
          selectedId: store.id,
          onLocateUser: () => _useMyLocation(app),
          onPick:
              (pickedLat, pickedLng) => setState(() {
                lat = pickedLat;
                lng = pickedLng;
              }),
          height: 320,
        ),
        const SizedBox(height: 12),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pin ${pinLat.toStringAsFixed(5)}, ${pinLng.toStringAsFixed(5)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                _sessionStatus(app, store),
                style: const TextStyle(fontSize: 12, color: taupe, height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          'Publish this regular pin',
          onPressed: () {
            app.updateStorePin(store, pinLat, pinLng);
            widget.onBack();
          },
        ),
        const SizedBox(height: 8),
        if (!app.canShareLiveLocation(store))
          const InfoBanner(
            'Only the store owner can start or stop live public sharing. Staff can update inventory and, if a session is already on, help keep the pin fresh.',
            icon: Icons.lock_outline,
          )
        else if (app.sessionFor(store)?.isActive == true)
          OutlinedButton(
            onPressed: () async {
              await app.stopVendorSession(store);
              setState(() {});
            },
            child: const Text('Stop live sharing'),
          )
        else
          OutlinedButton(
            onPressed: () async {
              await app.startVendorSession(store, lat: pinLat, lng: pinLng);
              setState(() {});
            },
            child: const Text('Start live public location'),
          ),
      ],
    );
  }
}

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final body = TextEditingController();
  String topic = 'search';
  bool submitting = false;

  @override
  void dispose() {
    body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        PageHeader('Pilot feedback', onBack: widget.onBack),
        const InfoBanner(
          'Cubao, Quezon City pilot. Tell us about failed searches, wrong pins, or listing freshness.',
          icon: Icons.forum_outlined,
        ),
        const SizedBox(height: 12),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FilterMenu<String>(
                label: 'Topic',
                value: topic,
                items: const [
                  DropdownMenuItem(value: 'search', child: Text('Search')),
                  DropdownMenuItem(value: 'location', child: Text('Location')),
                  DropdownMenuItem(
                    value: 'freshness',
                    child: Text('Listing freshness'),
                  ),
                  DropdownMenuItem(
                    value: 'onboarding',
                    child: Text('Onboarding'),
                  ),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => topic = value);
                },
              ),
              const SizedBox(height: 12),
              LabeledField(
                'What happened?',
                body,
                maxLines: 4,
                maxLength: 1000,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          submitting ? 'Sending feedback…' : 'Send feedback',
          onPressed:
              submitting
                  ? null
                  : () async {
                    if (body.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Enter feedback before sending.'),
                        ),
                      );
                      return;
                    }
                    setState(() => submitting = true);
                    final error = await app.addFeedback(
                      topic: topic,
                      body: body.text.trim(),
                      area: app.searchAreaLabel,
                    );
                    if (!context.mounted) return;
                    setState(() => submitting = false);
                    if (error != null) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(error)));
                      return;
                    }
                    widget.onBack();
                  },
        ),
      ],
    );
  }
}

class AddProductPage extends StatefulWidget {
  const AddProductPage({super.key, this.onBack});
  final VoidCallback? onBack;

  @override
  State<AddProductPage> createState() => _AddProductPageState();
}

class _AddProductPageState extends State<AddProductPage> {
  CatalogProduct? selected;
  bool manual = false;
  bool loading = false;
  bool uploading = false;
  double uploadProgress = 0;
  XFile? selectedPhoto;
  String? photoLabel;
  List<RecognitionSuggestion> suggestions = [];
  final name = TextEditingController();
  final brand = TextEditingController();
  final category = TextEditingController(text: 'Groceries');
  final size = TextEditingController();
  final barcode = TextEditingController();
  final price = TextEditingController();
  final unit = TextEditingController(text: 'piece');
  final qty = TextEditingController(text: '10');
  Availability availability = Availability.inStock;
  final attributeFields = <String, TextEditingController>{};

  TextEditingController _attr(String key) =>
      attributeFields.putIfAbsent(key, TextEditingController.new);

  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
  }

  @override
  void dispose() {
    _app?.cancelRecognition();
    name.dispose();
    brand.dispose();
    category.dispose();
    size.dispose();
    barcode.dispose();
    price.dispose();
    unit.dispose();
    qty.dispose();
    for (final controller in attributeFields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _applySuggestions(
    List<RecognitionSuggestion> next, {
    required String label,
  }) async {
    setState(() {
      photoLabel = label;
      suggestions = next;
      selected = null;
      manual = next.every((s) => s.product == null);
      loading = false;
    });
  }

  Future<void> _lookup({String? hint, String? code, String? image}) async {
    setState(() => loading = true);
    final app = AppScope.of(context);
    final next = await app.suggestFromCapture(
      hint: hint,
      barcode: code,
      image: image,
    );
    if (!mounted) return;
    await _applySuggestions(next, label: hint ?? code ?? 'capture');
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        imageQuality: 70,
      );
      if (file == null || !mounted) return;
      selectedPhoto = file;
      final stem = file.name.toLowerCase();
      final hint =
          stem.contains('mango')
              ? 'mango'
              : stem.contains('oil')
              ? 'oil'
              : stem.contains('sardine')
              ? 'sardines'
              : name.text.trim().isNotEmpty
              ? name.text.trim()
              : stem.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
      String? image;
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty && bytes.length <= 1500000) {
          image = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        }
      } catch (_) {}
      await _lookup(hint: hint, image: image);
    } catch (_) {
      if (!mounted) return;
      setState(() => manual = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Camera unavailable here. Use a demo photo or encode manually.',
          ),
        ),
      );
    }
  }

  void _choose(RecognitionSuggestion suggestion) {
    setState(() {
      selected = suggestion.product;
      manual = suggestion.product == null;
      if (suggestion.product != null) {
        name.text = suggestion.product!.name;
        brand.text = suggestion.product!.brand;
        category.text = suggestion.product!.category;
        size.text = suggestion.product!.packageSize;
        barcode.text = suggestion.product!.barcode ?? barcode.text;
      } else {
        name.text = suggestion.suggestedName ?? name.text;
        brand.text = suggestion.suggestedBrand ?? brand.text;
        category.text = suggestion.suggestedCategory ?? category.text;
        size.text = suggestion.suggestedPackageSize ?? size.text;
      }
      for (final field in categoryAttributeFields(category.text)) {
        final catalogValue = suggestion.product?.attributes[field.$1] ?? '';
        final suggestedValue = suggestion.suggestedAttributes[field.$1] ?? '';
        _attr(field.$1).text =
            catalogValue.isNotEmpty ? catalogValue : suggestedValue;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final store = app.ownedStore();
    if (store == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          PageHeader('Add product', onBack: widget.onBack),
          const EmptyNote(
            'Register a store first.',
            icon: Icons.storefront_outlined,
          ),
        ],
      );
    }
    if (!app.canEditInventory(store)) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          PageHeader('Add product', onBack: widget.onBack),
          const EmptyNote(
            'You do not have inventory access for this store.',
            icon: Icons.lock_outline,
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        PageHeader('Add product', onBack: widget.onBack),
        const InfoBanner(
          'Take a normal photo or scan a barcode if it has one. Suggestions are not inventory until you confirm identity, price and stock. Confirmed photos for new products are metadata-stripped and shown in the public catalog.',
          icon: Icons.photo_camera_outlined,
        ),
        const SizedBox(height: 12),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CaptureActions(
                onCamera: () => _pick(ImageSource.camera),
                onGallery: () => _pick(ImageSource.gallery),
                extra: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (barcode.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Enter a barcode first, or type the product name.',
                            ),
                          ),
                        );
                        return;
                      }
                      await _lookup(code: barcode.text.trim());
                    },
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('Lookup barcode'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Eyebrow('DEMO PHOTOS IF CAMERA IS UNAVAILABLE'),
              const SizedBox(height: 4),
              for (final key in const [
                'mango',
                'oil',
                'sardines',
                'hammer',
                'unknown',
              ])
                MenuRow(
                  icon: Icons.image_outlined,
                  title: 'Photo: $key',
                  subtitle: photoLabel == key ? 'Selected' : null,
                  onTap: () => _lookup(hint: key),
                ),
              LabeledField('Optional barcode', barcode),
            ],
          ),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Eyebrow('AI / OCR / BARCODE SUGGESTIONS'),
          const SizedBox(height: 8),
          SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < suggestions.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  MenuRow(
                    icon: Icons.auto_awesome_outlined,
                    title: suggestions[i].label,
                    subtitle: [
                      if (suggestions[i].isAiGenerated)
                        'AI candidate · verify or edit before saving'
                      else
                        'Owner confirmation required · ${(suggestions[i].confidence * 100).round()}%',
                      if (suggestions[i].ocrText != null)
                        'OCR ${suggestions[i].ocrText}',
                      'Not filled: ${suggestions[i].unknownFields.join(', ')}',
                    ].join(' · '),
                    onTap: () => _choose(suggestions[i]),
                  ),
                ],
                const Divider(height: 1),
                MenuRow(
                  icon: Icons.edit_outlined,
                  title: 'Encode manually instead',
                  onTap: () => setState(() => manual = true),
                ),
              ],
            ),
          ),
        ],
        if (manual || selected != null) ...[
          const Padding(
            padding: EdgeInsets.only(top: 12, bottom: 8),
            child: InfoBanner(
              'AI suggestions are not inventory. Confirm identity yourself. Price, stock, safety ratings and compatibility are never invented when evidence is missing.',
              icon: Icons.verified_user_outlined,
            ),
          ),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LabeledField('Product name', name),
                const SizedBox(height: 8),
                LabeledField('Brand (optional)', brand),
                const SizedBox(height: 12),
                FilterMenu<String>(
                  label: 'Category',
                  value:
                      productCategories.contains(category.text)
                          ? category.text
                          : productCategories.first,
                  items: [
                    for (final item in productCategories)
                      DropdownMenuItem(value: item, child: Text(item)),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => category.text = value);
                  },
                ),
                const SizedBox(height: 12),
                LabeledField('Package size / unit hint', size),
                for (final field in categoryAttributeFields(category.text)) ...[
                  const SizedBox(height: 12),
                  LabeledField(field.$2, _attr(field.$1)),
                ],
                const Divider(height: 28),
                const Text(
                  'Store-specific details',
                  style: TextStyle(fontFamily: 'Georgia', fontSize: 18),
                ),
                const SizedBox(height: 12),
                LabeledField(
                  'Price (PHP)',
                  price,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                LabeledField('Selling unit (kilo, piece, bundle…)', unit),
                const SizedBox(height: 12),
                LabeledField(
                  'Quantity',
                  qty,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                FilterMenu<Availability>(
                  label: 'Availability',
                  value: availability,
                  items: [
                    for (final value in Availability.values)
                      DropdownMenuItem(
                        value: value,
                        child: Text(availabilityLabel(value)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => availability = value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            uploading
                ? 'Uploading photo ${(uploadProgress * 100).round()}% · processing'
                : 'Confirm and publish listing',
            onPressed:
                app.writeBusy || uploading
                    ? null
                    : () async {
                      final parsed = double.tryParse(price.text);
                      if (parsed == null ||
                          parsed < 0 ||
                          name.text.trim().isEmpty ||
                          unit.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Confirm the product name, a valid price and a selling unit.',
                            ),
                          ),
                        );
                        return;
                      }
                      String? imageUrl;
                      String? imageAssetId;
                      if (selectedPhoto != null &&
                          selected == null &&
                          app.apiOnline) {
                        setState(() {
                          uploading = true;
                          uploadProgress = 0;
                        });
                        try {
                          final image = await MediaUpload.uploadAndWait(
                            selectedPhoto!,
                            kind: 'product',
                            onProgress: (value) {
                              if (mounted) {
                                setState(() => uploadProgress = value);
                              }
                            },
                          );
                          imageUrl = image.downloadUrl;
                          imageAssetId = image.assetId;
                        } catch (error) {
                          if (!mounted) return;
                          setState(() => uploading = false);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                error.toString().replaceFirst(
                                  'Bad state: ',
                                  '',
                                ),
                              ),
                            ),
                          );
                          return;
                        }
                        if (!mounted) return;
                        setState(() => uploading = false);
                      }
                      app.addListing(
                        storeId: store.id,
                        productId: selected?.id,
                        name: name.text.trim(),
                        category: category.text.trim(),
                        brand: brand.text.trim(),
                        packageSize: size.text.trim(),
                        barcode:
                            barcode.text.trim().isEmpty
                                ? null
                                : barcode.text.trim(),
                        price: parsed,
                        unit: unit.text.trim(),
                        quantity: int.tryParse(qty.text) ?? 0,
                        availability: availability,
                        attributes: {
                          for (final field in categoryAttributeFields(
                            category.text,
                          ))
                            if (_attr(field.$1).text.trim().isNotEmpty)
                              field.$1: _attr(field.$1).text.trim(),
                        },
                        imageUrl: imageUrl,
                        imageAssetId: imageAssetId,
                      );
                      widget.onBack?.call();
                    },
          ),
        ],
      ],
    );
  }
}

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key, this.onBack, required this.onAdd});
  final VoidCallback? onBack;
  final VoidCallback onAdd;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _history(StoreListing listing, CatalogProduct? product) async {
    final app = AppScope.of(context);
    final rows = await app.loadMovements(listing);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('${product?.name ?? 'Listing'} history'),
            content: SizedBox(
              width: 360,
              child:
                  rows.isEmpty
                      ? const Text('No stock movements recorded yet.')
                      : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final row in rows.take(12))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '${row.kind} · ${row.quantityDelta >= 0 ? '+' : ''}${row.quantityDelta}${row.note.isEmpty ? '' : ' · ${row.note}'}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                        ],
                      ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }

  Future<void> _edit(StoreListing listing, CatalogProduct? product) async {
    final app = AppScope.of(context);
    final price = TextEditingController(text: listing.price.toString());
    final unit = TextEditingController(text: listing.unit);
    final qty = TextEditingController(text: listing.quantity.toString());
    var availability = listing.availability;
    final saved = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(product?.name ?? 'Listing'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: price,
                  decoration: const InputDecoration(labelText: 'Price (PHP)'),
                ),
                TextField(
                  controller: unit,
                  decoration: const InputDecoration(labelText: 'Unit'),
                ),
                TextField(
                  controller: qty,
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  availability = Availability.unavailable;
                  Navigator.pop(context, true);
                },
                child: const Text('Mark unavailable'),
              ),
              FilledButton(
                onPressed:
                    app.writeBusy ? null : () => Navigator.pop(context, true),
                child: const Text('Save'),
              ),
            ],
          ),
    );
    if (saved != true) return;
    listing.price = double.tryParse(price.text) ?? listing.price;
    listing.unit = unit.text.trim().isEmpty ? listing.unit : unit.text.trim();
    listing.quantity = int.tryParse(qty.text) ?? listing.quantity;
    listing.availability = availability;
    if (availability == Availability.unavailable) listing.quantity = 0;
    app.updateListing(listing);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final store = app.ownedStore();
    if (store == null) return const SizedBox.shrink();
    if (!app.canEditInventory(store)) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          PageHeader('Inventory', onBack: widget.onBack),
          const EmptyNote(
            'You do not have inventory access for this store.',
            icon: Icons.lock_outline,
          ),
        ],
      );
    }
    final q = query.text.trim().toLowerCase();
    final rows =
        app.listingsForStore(store.id).where((listing) {
          final product = app.productById(listing.productId);
          if (q.isEmpty) return true;
          return (product?.name ?? '').toLowerCase().contains(q) ||
              listing.unit.toLowerCase().contains(q);
        }).toList();
    return Column(
      children: [
        PageHeader(
          'Inventory',
          onBack: widget.onBack,
          trailing: TextButton(
            onPressed: widget.onAdd,
            child: const Text('Add'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: TextField(
            controller: query,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Search listings',
              prefixIcon: Icon(Icons.search),
              filled: true,
              fillColor: paper,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              for (final listing in rows)
                Builder(
                  builder: (context) {
                    final product = app.productById(listing.productId);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SoftCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              product?.name ?? 'Product',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${peso(listing.price)} / ${listing.unit} · qty ${listing.quantity} · ${availabilityLabel(listing.availability)}',
                            ),
                            Text(
                              freshness(listing.lastConfirmed),
                              style: const TextStyle(
                                color: taupe,
                                fontSize: 11,
                              ),
                            ),
                            Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => _edit(listing, product),
                                  child: const Text('Edit'),
                                ),
                                TextButton(
                                  onPressed: () => _history(listing, product),
                                  child: const Text('History'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    final previous = listing.quantity;
                                    listing.availability =
                                        Availability.unavailable;
                                    listing.quantity = 0;
                                    app.updateListing(
                                      listing,
                                      quantityDelta: -previous,
                                      note: 'Marked unavailable',
                                    );
                                    setState(() {});
                                  },
                                  child: const Text('Unavailable'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    listing.quantity += 5;
                                    listing.availability = Availability.inStock;
                                    app.updateListing(
                                      listing,
                                      quantityDelta: 5,
                                      note: 'Restock',
                                    );
                                    setState(() {});
                                  },
                                  child: const Text('Restock'),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder:
                                          (context) => AlertDialog(
                                            title: const Text(
                                              'Archive listing?',
                                            ),
                                            content: Text(
                                              'Customers will stop seeing ${product?.name ?? 'this item'} at this store.',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed:
                                                    () => Navigator.pop(
                                                      context,
                                                      false,
                                                    ),
                                                child: const Text('Cancel'),
                                              ),
                                              FilledButton(
                                                onPressed:
                                                    () => Navigator.pop(
                                                      context,
                                                      true,
                                                    ),
                                                child: const Text('Archive'),
                                              ),
                                            ],
                                          ),
                                    );
                                    if (ok != true) return;
                                    app.archiveListing(listing);
                                    setState(() {});
                                  },
                                  child: const Text('Archive'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class PromotionsPage extends StatefulWidget {
  const PromotionsPage({super.key, this.onBack});
  final VoidCallback? onBack;

  @override
  State<PromotionsPage> createState() => _PromotionsPageState();
}

class _PromotionsPageState extends State<PromotionsPage> {
  final title = TextEditingController();
  final offer = TextEditingController();
  final days = TextEditingController(text: '14');
  bool sponsored = true;
  String? titleError;
  String? offerError;
  var submitting = false;

  @override
  void initState() {
    super.initState();
    title.addListener(() => setState(() {}));
    offer.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    title.dispose();
    offer.dispose();
    days.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final store = app.ownedStore();
    if (store == null) return const SizedBox.shrink();
    final mine = app.promotions.where((p) => p.storeId == store.id).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        PageHeader('Promotions', onBack: widget.onBack),
        const InfoBanner(
          'Sponsored cards appear on Home after admin approval and only during the offer dates.',
          icon: Icons.campaign_outlined,
        ),
        const SizedBox(height: 12),
        ...mine.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${p.offer} · ${p.status.name}${p.sponsored ? ' · sponsored' : ''}',
                    style: const TextStyle(color: taupe, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SoftCard(
          child: Column(
            children: [
              LabeledField('Title', title),
              if (titleError != null)
                Text(
                  titleError!,
                  style: const TextStyle(color: clay, fontSize: 12),
                ),
              const SizedBox(height: 8),
              LabeledField('Offer details', offer),
              if (offerError != null)
                Text(
                  offerError!,
                  style: const TextStyle(color: clay, fontSize: 12),
                ),
              const SizedBox(height: 8),
              LabeledField('Duration (days)', days),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Request sponsored placement'),
                value: sponsored,
                onChanged: (v) => setState(() => sponsored = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (title.text.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const StatusChip('Preview'),
                  const SizedBox(height: 6),
                  Text(
                    title.text.trim(),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${store.name} · ${offer.text.trim()}',
                    style: const TextStyle(color: taupe, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        if (!app.canManagePromotions(store))
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: EmptyNote(
              'You can view promotions, but this account cannot submit new offers.',
              icon: Icons.lock_outline,
            ),
          )
        else
          PrimaryButton(
            'Submit for moderation',
            onPressed:
                submitting || app.writeBusy
                    ? null
                    : () {
                      setState(() {
                        titleError =
                            title.text.trim().isEmpty
                                ? 'Enter an offer title.'
                                : null;
                        offerError =
                            offer.text.trim().isEmpty
                                ? 'Describe the offer.'
                                : null;
                      });
                      if (titleError != null || offerError != null) return;
                      setState(() => submitting = true);
                      app.addPromotion(
                        storeId: store.id,
                        title: title.text.trim(),
                        offer: offer.text.trim(),
                        sponsored: sponsored,
                        days: int.tryParse(days.text) ?? 14,
                      );
                      title.clear();
                      offer.clear();
                      setState(() => submitting = false);
                    },
          ),
      ],
    );
  }
}

class TourEditorPage extends StatefulWidget {
  const TourEditorPage({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<TourEditorPage> createState() => _TourEditorPageState();
}

class _TourEditorPageState extends State<TourEditorPage> {
  final title = TextEditingController();
  final image = TextEditingController(
    text:
        'https://images.unsplash.com/photo-1441986300917-64674bd600d8?auto=format&fit=crop&w=1200&q=80',
  );
  TourNode? connectFrom;
  XFile? selectedPanorama;
  String? panoramaAssetId;
  String? uploadedOriginalPath;
  panorama_review.PanoramaPrivacyReceipt? privacyReceipt;
  Map<String, dynamic>? verifiedPanoramaDerivative;
  int? pendingPanoramaNodeId;
  int? replacePanoramaNodeId;
  bool panoramaReplacementLinked = false;
  String? replacedPanoramaOldPath;
  bool recoveringPanorama = false;
  bool uploadingPanorama = false;
  double panoramaProgress = 0;
  var creatingTour = false;
  var _panoramaR2CutoverReady = false;
  var _checkedPanoramaR2Availability = false;
  var _checkingPanoramaR2Availability = false;
  bool get _panoramaUploadReady =>
      _panoramaR2CutoverReady || localPanoramaE2EEnabled;

  Future<void> _refreshPanoramaR2Availability() async {
    final app = AppScope.of(context);
    if (!app.apiOnline || localPanoramaE2EEnabled) return;
    setState(() => _checkingPanoramaR2Availability = true);
    var available = false;
    try {
      available = await app.api.getStorageAvailability();
    } catch (_) {
      available = false;
    }
    if (!mounted) return;
    setState(() {
      _panoramaR2CutoverReady = available;
      _checkingPanoramaR2Availability = false;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checkedPanoramaR2Availability) return;
    _checkedPanoramaR2Availability = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _refreshPanoramaR2Availability();
    });
  }

  static const samples = [
    (
      'Storefront',
      'https://images.unsplash.com/photo-1604719312566-8912e9227c6a?auto=format&fit=crop&w=1200&q=80',
    ),
    (
      'Aisle',
      'https://images.unsplash.com/photo-1578916171728-46686eac8d58?auto=format&fit=crop&w=1200&q=80',
    ),
    (
      'Counter',
      'https://images.unsplash.com/photo-1534723452862-4c874018d66d?auto=format&fit=crop&w=1200&q=80',
    ),
  ];

  @override
  void dispose() {
    title.dispose();
    image.dispose();
    super.dispose();
  }

  Future<void> _pickPanorama({int? replaceNodeId, StoreTour? tour}) async {
    if (replaceNodeId != null && tour?.status == TourStatus.published) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: const Text('Edit published tour?'),
              content: const Text(
                'Changing this panorama briefly returns the tour to draft. It will publish automatically after the new panorama is verified.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Continue'),
                ),
              ],
            ),
      );
      if (confirmed != true || !mounted) return;
    }
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      final name = file.name.toLowerCase();
      if (!(name.endsWith('.jpg') || name.endsWith('.jpeg'))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Panorama uploads currently support JPEG files only.',
            ),
          ),
        );
        return;
      }
      final signature = await file
          .openRead(0, 3)
          .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
      if (!mounted) return;
      if (signature.length < 3 ||
          signature[0] != 0xff ||
          signature[1] != 0xd8 ||
          signature[2] != 0xff) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The selected file is not a valid JPEG image.'),
          ),
        );
        return;
      }
      setState(() {
        selectedPanorama = file;
        panoramaAssetId = MediaUpload.createAssetId();
        uploadedOriginalPath = null;
        privacyReceipt = null;
        verifiedPanoramaDerivative = null;
        pendingPanoramaNodeId = null;
        replacePanoramaNodeId = replaceNodeId;
        panoramaReplacementLinked = false;
        replacedPanoramaOldPath = null;
        panoramaProgress = 0;
        image.text = file.name;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Gallery unavailable. Demo tours can use samples; online tours require a file upload.',
          ),
        ),
      );
    }
  }

  Future<void> _processAndReviewPanorama() async {
    final file = selectedPanorama;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (file == null || uid == null) return;
    final receipt = await Navigator.of(
      context,
    ).push<panorama_review.PanoramaPrivacyReceipt>(
      MaterialPageRoute(
        builder:
            (_) => panorama_privacy.PrototypeScreen(
              initialPath: file.path,
              initialName: file.name,
              integratedMode: true,
              ownerContext: _FirebaseOwnerContext(uid),
            ),
      ),
    );
    if (!mounted || receipt == null) return;
    setState(() => privacyReceipt = receipt);
    verifiedPanoramaDerivative = null;
    pendingPanoramaNodeId = null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Face blur is prepared. You can upload it or use the original panorama.',
        ),
      ),
    );
  }

  void _useOriginalPanorama() {
    if (uploadingPanorama) return;
    setState(() {
      privacyReceipt = null;
      verifiedPanoramaDerivative = null;
      pendingPanoramaNodeId = null;
      panoramaProgress = 0;
    });
  }

  Future<void> _uploadAndAddOnlinePanorama(StoreTour tour) async {
    final receipt = privacyReceipt;
    final selected = selectedPanorama;
    final assetId = panoramaAssetId;
    if (!_panoramaUploadReady || selected == null || assetId == null) {
      return;
    }
    if (tour.status == TourStatus.published && replacePanoramaNodeId == null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: const Text('Update the live tour?'),
              content: const Text(
                'The tour briefly returns to draft while this viewpoint uploads, then publishes automatically when ready.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Continue'),
                ),
              ],
            ),
      );
      if (confirmed != true || !mounted) return;
    }
    final derivativePath = receipt?.derivativePath ?? selected.path;
    final processingVersion =
        receipt?.processingVersion ?? 'localspot-panorama-original-v1';
    final app = AppScope.of(context);
    setState(() {
      uploadingPanorama = true;
      panoramaProgress = 0;
    });
    try {
      var originalPath = uploadedOriginalPath;
      if (originalPath == null) {
        originalPath = await MediaUpload.uploadPanorama(
          selected,
          tourId: tour.id,
          assetId: assetId,
          onProgress: (value) {
            if (mounted) setState(() => panoramaProgress = value * .35);
          },
        );
        if (!mounted) return;
        setState(() => uploadedOriginalPath = originalPath);
      }
      var nodeId = replacePanoramaNodeId ?? pendingPanoramaNodeId;
      if (replacePanoramaNodeId != null) {
        nodeId = replacePanoramaNodeId;
        if (!panoramaReplacementLinked) {
          final currentNode = tour.nodes.firstWhere(
            (item) => item.id == replacePanoramaNodeId,
          );
          final oldPath = currentNode.originalStoragePath;
          if (oldPath == null) {
            throw StateError(
              'This viewpoint has no stored panorama to replace.',
            );
          }
          final response = await app.replaceTourNodePanorama(
            tour,
            currentNode,
            originalPath,
          );
          replacedPanoramaOldPath =
              response['replacedOriginalPath'] as String? ?? oldPath;
          panoramaReplacementLinked = true;
        }
      } else if (nodeId == null) {
        final existing =
            tour.nodes
                .where((node) => node.originalStoragePath == originalPath)
                .firstOrNull;
        if (existing != null) {
          nodeId = existing.id;
        } else {
          final label =
              title.text.trim().isEmpty
                  ? 'Viewpoint ${tour.nodes.length + 1}'
                  : title.text.trim();
          final error = await app.addTourNode(
            tour,
            label,
            '',
            originalStoragePath: originalPath,
          );
          if (error != null) throw StateError(error);
          final refreshed = app.draftOrPublishedTour(tour.storeId) ?? tour;
          nodeId =
              refreshed.nodes
                  .firstWhere(
                    (node) => node.originalStoragePath == originalPath,
                  )
                  .id;
        }
        pendingPanoramaNodeId = nodeId;
      }
      final resolvedNodeId = nodeId;
      if (resolvedNodeId == null) {
        throw StateError('The viewpoint could not be identified for upload.');
      }

      var derivative = verifiedPanoramaDerivative;
      if (derivative == null ||
          (receipt != null &&
              derivative['sha256'] != receipt.derivativeSha256)) {
        final digest =
            receipt?.derivativeSha256 ??
            (await sha256.bind(File(derivativePath).openRead()).first)
                .toString();
        derivative = await MediaUpload.uploadPanoramaDerivative(
          File(derivativePath),
          tourId: tour.id,
          nodeId: resolvedNodeId,
          assetId: assetId,
          derivativeSha256: digest,
          processingVersion: processingVersion,
          onProgress: (value) {
            if (mounted) setState(() => panoramaProgress = .35 + value * .5);
          },
        );
        verifiedPanoramaDerivative = derivative;
      }
      if (receipt != null) {
        await app.api.post('/tours/${tour.id}/nodes/$resolvedNodeId/review', {
          'derivative_sha256': receipt.derivativeSha256,
          'processing_version': receipt.processingVersion,
          'inspected_directions': receipt.inspectedDirections.toList()..sort(),
          'acknowledged_miss_risk': receipt.acknowledgedMissRisk,
          'acknowledged_manual_inspection':
              receipt.acknowledgedManualInspection,
          'unblurred_consent': false,
        });
      }
      app.markOnlineTourNodeVerified(
        tour,
        resolvedNodeId,
        unblurred: receipt == null,
      );
      final publicationError = await app.publishTour(tour);
      if (publicationError != null) {
        throw StateError(
          'Panorama uploaded, but publishing failed: $publicationError',
        );
      }
      final oldPath = replacedPanoramaOldPath;
      if (oldPath != null && oldPath != originalPath) {
        try {
          await app.api.deleteMediaAsset(oldPath.split('/').last);
        } catch (_) {
          // The active viewpoint is already replaced; quota reconciliation can
          // safely remove an unlinked old object if cleanup is temporarily down.
        }
      }
      if (!mounted) return;
      setState(() {
        selectedPanorama = null;
        panoramaAssetId = null;
        uploadedOriginalPath = null;
        privacyReceipt = null;
        verifiedPanoramaDerivative = null;
        pendingPanoramaNodeId = null;
        replacePanoramaNodeId = null;
        panoramaReplacementLinked = false;
        replacedPanoramaOldPath = null;
        panoramaProgress = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            receipt == null
                ? 'Panorama uploaded. The tour is now live for customers.'
                : 'Blurred panorama uploaded. The tour is now live for customers.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => uploadingPanorama = false);
    }
  }

  Future<void> _recoverUploadedPanorama(StoreTour tour) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => recoveringPanorama = true);
    try {
      final media =
          await FirebaseFirestore.instance
              .collection('mediaAssets')
              .where('uid', isEqualTo: user.uid)
              .where('tourId', isEqualTo: tour.id)
              .limit(100)
              .get();
      final candidates =
          media.docs.where((doc) {
              final data = doc.data();
              return data['mediaType'] == 'panorama' &&
                  data['status'] == 'awaiting-privacy-processing' &&
                  data['originalPath'] is String &&
                  !tour.nodes.any(
                    (node) => node.originalStoragePath == data['originalPath'],
                  );
            }).toList()
            ..sort((a, b) {
              final left = a.data()['updatedAt'];
              final right = b.data()['updatedAt'];
              final leftTime = left is Timestamp ? left : Timestamp(0, 0);
              final rightTime = right is Timestamp ? right : Timestamp(0, 0);
              return rightTime.compareTo(leftTime);
            });
      if (!mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No validated uploaded panorama is available to recover yet.',
            ),
          ),
        );
        return;
      }
      setState(() {
        uploadedOriginalPath =
            candidates.first.data()['originalPath'] as String;
        selectedPanorama = null;
        panoramaAssetId = null;
        title.text = 'Viewpoint ${tour.nodes.length + 1}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Uploaded panorama recovered. Add the viewpoint to save it to this tour.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not recover the upload: $error')),
      );
    } finally {
      if (mounted) setState(() => recoveringPanorama = false);
    }
  }

  Future<void> _removeTourPanorama(StoreTour tour, TourNode node) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Remove this viewpoint?'),
            content: Text(
              tour.status == TourStatus.published
                  ? 'This removes “${node.title}” and its panorama. The tour will publish automatically again if another viewpoint remains.'
                  : 'This removes “${node.title}” and its stored panorama from the tour.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Remove viewpoint'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    final app = AppScope.of(context);
    setState(() => uploadingPanorama = true);
    var mediaCleanupPending = false;
    try {
      final response = await app.removeTourNodePanorama(tour, node);
      final oldPath = response['removedOriginalPath'];
      if (oldPath is String && oldPath.isNotEmpty) {
        try {
          await app.api.deleteMediaAsset(oldPath.split('/').last);
        } catch (_) {
          mediaCleanupPending = true;
        }
      }
      String? publicationError;
      final updatedTour = app.draftOrPublishedTour(tour.storeId);
      if (updatedTour != null && updatedTour.nodes.isNotEmpty) {
        publicationError = await app.publishTour(updatedTour);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              publicationError != null
                  ? 'Viewpoint removed. The tour is saved as a draft and could not be published: $publicationError'
                  : mediaCleanupPending
                  ? 'Viewpoint removed and tour updated. Storage cleanup is temporarily pending.'
                  : updatedTour != null && updatedTour.nodes.isNotEmpty
                  ? 'Viewpoint removed. The updated tour is live for customers.'
                  : 'Viewpoint removed. Add a panorama to publish the tour again.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove viewpoint: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => uploadingPanorama = false);
    }
  }

  Future<void> _showPrivatePanorama(
    StoreTour tour,
    int nodeId,
    String variant,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final access =
          await AppScope.of(context).api.get(
                '/tours/${tour.id}/nodes/$nodeId/private-media',
                {'variant': variant},
              )
              as Map;
      final url = access['url'];
      final gatewayToken = access['token'];
      final firebaseToken = await user.getIdToken();
      if (!mounted ||
          url is! String ||
          gatewayToken is! String ||
          firebaseToken == null ||
          url.isEmpty ||
          gatewayToken.isEmpty) {
        throw StateError('Private media access was not granted.');
      }
      await showDialog<void>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: Text(
                variant == 'original'
                    ? 'Private original'
                    : 'Verified derivative',
              ),
              content: SizedBox(
                width: 560,
                child: NetworkPhoto(
                  url,
                  height: 320,
                  radius: 8,
                  headers: {
                    'Authorization': 'Bearer $firebaseToken',
                    'X-Gateway-Authorization': 'Bearer $gatewayToken',
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Private media unavailable: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final store = app.ownedStore();
    if (store == null) return const SizedBox.shrink();
    final tour = app.draftOrPublishedTour(store.id);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        PageHeader('360° tour editor', onBack: widget.onBack),
        if (tour == null)
          PrimaryButton(
            creatingTour ? 'Creating tour…' : 'Create tour',
            onPressed:
                creatingTour
                    ? null
                    : () async {
                      setState(() => creatingTour = true);
                      final error = await app.addTour(
                        store.id,
                        '${store.name} tour',
                      );
                      if (!mounted) return;
                      setState(() => creatingTour = false);
                      if (error != null) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(error)));
                      }
                    },
          )
        else ...[
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tour.title,
                  style: const TextStyle(fontFamily: 'Georgia', fontSize: 22),
                ),
                const SizedBox(height: 6),
                StatusChip('Status: ${tour.status.name}'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ...tour.nodes.map(
            (n) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SoftCard(
                child: Row(
                  children: [
                    const IconWell(Icons.threesixty_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            n.title,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            n.connections.isEmpty
                                ? 'Not connected yet'
                                : 'Connected to ${n.connections.map((id) => tour.nodes.firstWhere((o) => o.id == id).title).join(', ')}',
                            style: const TextStyle(color: taupe, fontSize: 11),
                          ),
                          const SizedBox(height: 6),
                          StatusChip(
                            n.publishedWithoutFaceBlur
                                ? 'Unblurred · owner consent'
                                : n.canPublish && !app.apiOnline
                                ? 'Owner review complete'
                                : app.apiOnline
                                ? n.ownerReviewed
                                    ? 'Panorama reviewed'
                                    : n.originalStoragePath == null
                                    ? 'Choose a panorama'
                                    : 'Awaiting owner choice'
                                : n.privacyStatus == PrivacyStatus.failed
                                ? 'Privacy failed · original stays private'
                                : n.privacyStatus == PrivacyStatus.processing
                                ? 'Processing'
                                : 'Choose blur option',
                            color:
                                n.publishedWithoutFaceBlur
                                    ? champagne
                                    : n.canPublish && !app.apiOnline
                                    ? leaf
                                    : champagne,
                          ),
                          if (n.originalRetained)
                            const Text(
                              'Original retained privately',
                              style: TextStyle(color: taupe, fontSize: 11),
                            ),
                          if (n.manualBlur)
                            Text(
                              'Manual blur regions: ${n.blurRegions.length}',
                              style: const TextStyle(
                                color: taupe,
                                fontSize: 11,
                              ),
                            ),
                          const SizedBox(height: 8),
                          if (n.privacyStatus == PrivacyStatus.failed)
                            const Text(
                              'No public preview. Failed processing never publishes the original.',
                              style: TextStyle(color: taupe, fontSize: 11),
                            )
                          else if (app.apiOnline &&
                              n.privacyStatus == PrivacyStatus.ready &&
                              n.image.trim().isEmpty)
                            const Text(
                              'Verified in R2 · ready to publish',
                              style: TextStyle(color: taupe, fontSize: 11),
                            )
                          else if (n.image.trim().isEmpty)
                            const Text(
                              'Choose a panorama to create a preview.',
                              style: TextStyle(color: taupe, fontSize: 11),
                            )
                          else
                            NetworkPhoto(n.image, height: 72, width: 120),
                        ],
                      ),
                    ),
                    Column(
                      children: [
                        if (n.privacyStatus != PrivacyStatus.ready &&
                            !app.apiOnline)
                          TextButton(
                            onPressed: () async {
                              await app.processTourNode(tour, n);
                              if (mounted) setState(() {});
                            },
                            child: const Text('Process'),
                          )
                        else if (app.apiOnline &&
                            n.privacyStatus != PrivacyStatus.ready)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              'Waiting for verified upload',
                              style: TextStyle(color: taupe, fontSize: 10),
                            ),
                          ),
                        TextButton(
                          onPressed: () {
                            final error = app.addManualTourBlur(tour, n);
                            if (error != null && context.mounted) {
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(error)));
                            } else {
                              setState(() {});
                            }
                          },
                          child: const Text('Add blur region'),
                        ),
                        if (!n.ownerReviewed)
                          TextButton(
                            onPressed: () {
                              final error = app.reviewTourNode(tour, n);
                              if (error != null && context.mounted) {
                                ScaffoldMessenger.of(
                                  context,
                                ).showSnackBar(SnackBar(content: Text(error)));
                              } else {
                                setState(() {});
                              }
                            },
                            child: const Text('Review'),
                          ),
                        TextButton(
                          onPressed: () => setState(() => connectFrom = n),
                          child: Text(
                            connectFrom?.id == n.id ? 'From here' : 'Connect',
                          ),
                        ),
                        if (app.apiOnline && n.originalStoragePath != null) ...[
                          TextButton.icon(
                            onPressed:
                                uploadingPanorama
                                    ? null
                                    : () => _pickPanorama(
                                      replaceNodeId: n.id,
                                      tour: tour,
                                    ),
                            icon: const Icon(Icons.swap_horiz),
                            label: const Text('Change panorama'),
                          ),
                          TextButton.icon(
                            onPressed:
                                uploadingPanorama || app.writeBusy
                                    ? null
                                    : () => _removeTourPanorama(tour, n),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remove viewpoint'),
                          ),
                          TextButton(
                            onPressed:
                                () => _showPrivatePanorama(
                                  tour,
                                  n.id,
                                  'original',
                                ),
                            child: const Text('View private original'),
                          ),
                          TextButton(
                            onPressed:
                                () => _showPrivatePanorama(
                                  tour,
                                  n.id,
                                  'derivative',
                                ),
                            child: const Text('View private derivative'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (connectFrom != null) ...[
            const SizedBox(height: 8),
            SoftCard(
              child: FilterMenu<int>(
                label: 'Connect ${connectFrom!.title} to',
                value: -1,
                items: [
                  const DropdownMenuItem(
                    value: -1,
                    child: Text('Choose viewpoint'),
                  ),
                  for (final n in tour.nodes.where(
                    (node) => node.id != connectFrom!.id,
                  ))
                    DropdownMenuItem(value: n.id, child: Text(n.title)),
                ],
                onChanged: (id) async {
                  if (id == null || id == -1) return;
                  final target = tour.nodes.firstWhere((node) => node.id == id);
                  final error = await app.connectTourNodes(
                    tour,
                    connectFrom!,
                    target,
                  );
                  setState(() => connectFrom = null);
                  if (error != null && context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(error)));
                  }
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LabeledField('Viewpoint title', title),
                const SizedBox(height: 12),
                if (app.apiOnline)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Choose a full 360° JPEG panorama (2:1 aspect ratio). Preview it here, then select Detect faces and blur to prepare the reviewed version required before online publishing. Standard photos and partial panoramas are not supported.',
                      style: TextStyle(color: taupe, fontSize: 11),
                    ),
                  ),
                if (!app.apiOnline) ...[
                  LabeledField('Panorama image', image),
                  const SizedBox(height: 12),
                  FilterMenu<String>(
                    label: 'Sample viewpoint',
                    value: '',
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Choose a sample'),
                      ),
                      for (final sample in samples)
                        DropdownMenuItem(
                          value: sample.$1,
                          child: Text(sample.$1),
                        ),
                    ],
                    onChanged: (name) {
                      final sample =
                          samples.where((item) => item.$1 == name).firstOrNull;
                      if (sample == null) return;
                      setState(() {
                        title.text = sample.$1;
                        image.text = sample.$2;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  onPressed:
                      uploadingPanorama
                          ? null
                          : () => _pickPanorama(
                            replaceNodeId: replacePanoramaNodeId,
                            tour: tour,
                          ),
                  icon: const Icon(Icons.photo_outlined, size: 18),
                  label: Text(
                    selectedPanorama == null
                        ? 'Choose 360° panorama (JPEG)'
                        : 'Choose another file',
                  ),
                ),
                if (selectedPanorama != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '360° preview',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 220,
                    width: double.infinity,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: PanoramaViewer(
                        key: ValueKey(
                          'tour-panorama-${selectedPanorama!.path}',
                        ),
                        child: Image.file(
                          File(selectedPanorama!.path),
                          fit: BoxFit.cover,
                          errorBuilder:
                              (context, error, stackTrace) => const Center(
                                child: Text(
                                  'The selected panorama preview is unavailable.',
                                ),
                              ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Drag to look around. Previewing does not change or upload the original.',
                    style: TextStyle(color: taupe, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed:
                        uploadingPanorama ? null : _processAndReviewPanorama,
                    icon: const Icon(Icons.face_retouching_natural_outlined),
                    label: Text(
                      privacyReceipt == null
                          ? 'Optional: detect faces and blur'
                          : 'Review or update face blur',
                    ),
                  ),
                  if (privacyReceipt != null)
                    TextButton.icon(
                      onPressed:
                          uploadingPanorama ? null : _useOriginalPanorama,
                      icon: const Icon(Icons.visibility_outlined),
                      label: const Text('Use original without blur'),
                    ),
                  Text(
                    privacyReceipt == null
                        ? 'Ready to upload without blur. People may be identifiable in the public tour.'
                        : 'Face blur is applied. Review the result before uploading.',
                    style: const TextStyle(color: taupe, fontSize: 11),
                  ),
                ],
                if (uploadingPanorama) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: panoramaProgress == 0 ? null : panoramaProgress,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Secure panorama upload ${(panoramaProgress * 100).round()}%',
                    style: const TextStyle(color: taupe, fontSize: 11),
                  ),
                ],
                if (app.apiOnline && uploadedOriginalPath == null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed:
                          recoveringPanorama || uploadingPanorama
                              ? null
                              : () => _recoverUploadedPanorama(tour),
                      icon: const Icon(Icons.restore_outlined),
                      label: Text(
                        recoveringPanorama
                            ? 'Checking uploads…'
                            : 'Recover a previously uploaded panorama',
                      ),
                    ),
                  ),
                if (app.apiOnline && uploadedOriginalPath != null)
                  const Text(
                    'Validated upload recovered. Upload it to finish saving the viewpoint.',
                    style: TextStyle(color: taupe, fontSize: 11),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed:
                app.apiOnline
                    ? (_panoramaUploadReady &&
                            !uploadingPanorama &&
                            !app.writeBusy &&
                            selectedPanorama != null &&
                            panoramaAssetId != null
                        ? () => _uploadAndAddOnlinePanorama(tour)
                        : null)
                    : app.writeBusy || uploadingPanorama
                    ? null
                    : () async {
                      final label =
                          title.text.trim().isEmpty
                              ? 'Viewpoint ${tour.nodes.length + 1}'
                              : title.text.trim();
                      String? originalPath;
                      if (app.apiOnline) {
                        if (uploadedOriginalPath == null &&
                            (selectedPanorama == null ||
                                panoramaAssetId == null)) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Choose a panorama file before adding an online viewpoint.',
                              ),
                            ),
                          );
                          return;
                        }
                        originalPath = uploadedOriginalPath;
                        if (originalPath == null) {
                          setState(() {
                            uploadingPanorama = true;
                            panoramaProgress = 0;
                          });
                          try {
                            originalPath = await MediaUpload.uploadPanorama(
                              selectedPanorama!,
                              tourId: tour.id,
                              assetId: panoramaAssetId!,
                              onProgress: (value) {
                                if (mounted) {
                                  setState(() => panoramaProgress = value);
                                }
                              },
                            );
                            uploadedOriginalPath = originalPath;
                          } catch (error) {
                            if (!mounted) return;
                            setState(() => uploadingPanorama = false);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  error.toString().replaceFirst(
                                    'Bad state: ',
                                    '',
                                  ),
                                ),
                              ),
                            );
                            return;
                          }
                          if (!mounted) return;
                          setState(() => uploadingPanorama = false);
                        }
                      }
                      final error = await app.addTourNode(
                        tour,
                        label,
                        app.apiOnline ? '' : image.text.trim(),
                        originalStoragePath: originalPath,
                      );
                      if (!mounted) return;
                      if (error != null) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(error)));
                        return;
                      }
                      title.clear();
                      image.clear();
                      setState(() {
                        selectedPanorama = null;
                        panoramaAssetId = null;
                        uploadedOriginalPath = null;
                        panoramaProgress = 0;
                      });
                    },
            child: Text(
              app.apiOnline
                  ? privacyReceipt == null
                      ? replacePanoramaNodeId == null
                          ? 'Upload'
                          : 'Replace panorama'
                      : replacePanoramaNodeId == null
                      ? 'Upload with face blur'
                      : 'Replace with blurred panorama'
                  : uploadingPanorama
                  ? 'Uploading panorama…'
                  : 'Add demo viewpoint',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: 12),
            child: InfoBanner(
              app.apiOnline
                  ? _panoramaUploadReady
                      ? tour.status == TourStatus.published
                          ? 'Live for customers. Uploading, replacing, or removing a viewpoint publishes the updated tour automatically. The first viewpoint is the starting view.'
                          : 'Upload a panorama to publish automatically. The first viewpoint is the starting view; face blur is optional.'
                      : 'Face blur is optional. Unblurred panoramas may show identifiable people. Online upload and publishing stay disabled until R2 storage reconciliation is complete.'
                  : 'Demo processing is only a preview. Face blur is optional; unblurred panoramas may show identifiable people. Online publishing requires verified storage.',
              icon: Icons.privacy_tip_outlined,
            ),
          ),
          if (app.apiOnline && !localPanoramaE2EEnabled)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed:
                    _checkingPanoramaR2Availability
                        ? null
                        : _refreshPanoramaR2Availability,
                icon:
                    _checkingPanoramaR2Availability
                        ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.refresh),
                label: Text(
                  _panoramaUploadReady
                      ? 'Refresh storage status'
                      : 'Check storage availability',
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class StaffPage extends StatefulWidget {
  const StaffPage({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<StaffPage> createState() => _StaffPageState();
}

class _StaffPageState extends State<StaffPage> {
  final email = TextEditingController();
  String? message;
  String? emailError;
  String? staffLoadError;
  int? loadedStoreId;
  var loadingStaff = false;
  var invitingStaff = false;
  final updatingStaffIds = <int>{};
  var inventory = true;
  var promotions = false;
  var location = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final store = app.ownedStore();
    if (store == null || loadedStoreId == store.id) return;
    loadedStoreId = store.id;
    if (!app.apiOnline) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _loadStaff(app, store.id),
    );
  }

  Future<void> _loadStaff(AppState app, int storeId) async {
    if (!mounted) return;
    setState(() {
      loadingStaff = true;
      staffLoadError = null;
    });
    final error = await app.loadStoreStaff(storeId);
    if (!mounted) return;
    setState(() {
      loadingStaff = false;
      staffLoadError = error;
    });
  }

  Future<void> _updateGrant(
    AppState app,
    int storeId,
    UserAccount member, {
    bool? inventory,
    bool? promotions,
    bool? location,
  }) async {
    if (updatingStaffIds.contains(member.id)) return;
    setState(() => updatingStaffIds.add(member.id));
    final error = await app.setStaffGrant(
      storeId,
      member,
      inventory: inventory,
      promotions: promotions,
      location: location,
    );
    if (mounted) setState(() => updatingStaffIds.remove(member.id));
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update staff access: $error')),
      );
    }
  }

  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final store = app.ownedStore();
    if (store == null) return const SizedBox.shrink();
    final staff = app.staffForStore(store.id);
    final canInvite = app.role == AppRole.owner || app.role == AppRole.admin;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        PageHeader('Staff', onBack: widget.onBack),
        const InfoBanner(
          'Assign what each staff account may do. Only the owner can invite staff or change grants.',
          icon: Icons.group_outlined,
        ),
        const SizedBox(height: 12),
        if (loadingStaff) const LinearProgressIndicator(minHeight: 2),
        if (staffLoadError != null)
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Could not load staff: $staffLoadError'),
                TextButton(
                  onPressed: () => _loadStaff(app, store.id),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        if (staff.isEmpty)
          loadingStaff
              ? const SizedBox.shrink()
              : const EmptyNote(
                'No staff invited yet.',
                icon: Icons.person_add_alt_1_outlined,
              )
        else
          SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < staff.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    staff[i].name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    staff[i].email,
                                    style: const TextStyle(
                                      color: taupe,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove staff',
                              icon: const Icon(Icons.person_remove_outlined),
                              onPressed:
                                  canInvite
                                      ? () async {
                                        final confirmed = await showDialog<
                                          bool
                                        >(
                                          context: context,
                                          builder:
                                              (context) => AlertDialog(
                                                title: const Text(
                                                  'Remove staff access?',
                                                ),
                                                content: Text(
                                                  '${staff[i].name} will lose access to this store.',
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed:
                                                        () => Navigator.pop(
                                                          context,
                                                          false,
                                                        ),
                                                    child: const Text('Cancel'),
                                                  ),
                                                  FilledButton(
                                                    onPressed:
                                                        () => Navigator.pop(
                                                          context,
                                                          true,
                                                        ),
                                                    child: const Text('Remove'),
                                                  ),
                                                ],
                                              ),
                                        );
                                        if (confirmed == true &&
                                            context.mounted) {
                                          final error = await app.removeStaff(
                                            store.id,
                                            staff[i],
                                          );
                                          if (error != null &&
                                              context.mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(content: Text(error)),
                                            );
                                          }
                                        }
                                      }
                                      : null,
                            ),
                          ],
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Inventory',
                            style: TextStyle(fontSize: 14),
                          ),
                          value:
                              staff[i].storeGrants[store.id]?.inventory ?? true,
                          onChanged:
                              canInvite &&
                                      !updatingStaffIds.contains(staff[i].id)
                                  ? (value) => _updateGrant(
                                    app,
                                    store.id,
                                    staff[i],
                                    inventory: value,
                                  )
                                  : null,
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Promotions',
                            style: TextStyle(fontSize: 14),
                          ),
                          value:
                              staff[i].storeGrants[store.id]?.promotions ??
                              false,
                          onChanged:
                              canInvite &&
                                      !updatingStaffIds.contains(staff[i].id)
                                  ? (value) => _updateGrant(
                                    app,
                                    store.id,
                                    staff[i],
                                    promotions: value,
                                  )
                                  : null,
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Live location',
                            style: TextStyle(fontSize: 14),
                          ),
                          value:
                              staff[i].storeGrants[store.id]?.location ?? false,
                          onChanged:
                              canInvite &&
                                      !updatingStaffIds.contains(staff[i].id)
                                  ? (value) => _updateGrant(
                                    app,
                                    store.id,
                                    staff[i],
                                    location: value,
                                  )
                                  : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (canInvite) ...[
          const SizedBox(height: 16),
          SoftCard(
            child: Column(
              children: [
                LabeledField('Account email', email),
                if (emailError != null)
                  Text(
                    emailError!,
                    style: const TextStyle(color: clay, fontSize: 12),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Inventory'),
                  value: inventory,
                  onChanged: (v) => setState(() => inventory = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Promotions'),
                  value: promotions,
                  onChanged: (v) => setState(() => promotions = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Live location'),
                  value: location,
                  onChanged: (v) => setState(() => location = v),
                ),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      message!,
                      style: const TextStyle(color: clay, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            invitingStaff ? 'Inviting staff…' : 'Invite staff',
            onPressed:
                app.writeBusy || invitingStaff
                    ? null
                    : () async {
                      setState(
                        () =>
                            emailError =
                                email.text.contains('@')
                                    ? null
                                    : 'Enter the staff account email.',
                      );
                      if (emailError != null) return;
                      setState(() => invitingStaff = true);
                      final error = await app.inviteStaff(
                        storeId: store.id,
                        email: email.text,
                        inventory: inventory,
                        promotions: promotions,
                        location: location,
                      );
                      if (!mounted) return;
                      setState(() {
                        invitingStaff = false;
                        message = error;
                        if (error == null) email.clear();
                      });
                    },
          ),
        ],
      ],
    );
  }
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, this.onBack});
  final VoidCallback? onBack;

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  var _loaded = false;
  Future<Map<String, dynamic>>? _storageQuota;

  String _storageErrorMessage(Object error, String fallback) {
    if (error is ApiException) return error.message;
    if (error is FirebaseFunctionsException) return error.message ?? fallback;
    return fallback;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    AppScope.of(context).loadAudit();
    _refreshStorageQuota();
  }

  void _refreshStorageQuota() {
    if (!mounted || localSpotPreviewRelease) return;
    setState(() {
      _storageQuota = AppScope.of(context).api.getStorageQuota();
    });
  }

  String _storageSize(num value) {
    final bytes = value.toDouble();
    return '${(bytes / 1000000).toStringAsFixed(1)} MB · ${(bytes / 1000000000).toStringAsFixed(3)} GB';
  }

  Future<void> _runStorageReconciliation() async {
    if (localSpotPreviewRelease) return;
    try {
      await AppScope.of(context).api.requestStorageReconciliation();
      _refreshStorageQuota();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _storageErrorMessage(
              error,
              'Storage reconciliation could not run.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _deleteStorageOrphan(String key) async {
    if (localSpotPreviewRelease) return;
    try {
      await AppScope.of(context).api.deleteStorageOrphan(key);
      await _runStorageReconciliation();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _storageErrorMessage(error, 'The orphan could not be removed.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      children: [
        PageHeader(
          'Admin review',
          onBack: widget.onBack,
          subtitle: 'Cubao pilot moderation',
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: InfoBanner(
            'Approve stores and sponsored offers before they appear to customers in the Cubao pilot.',
            icon: Icons.admin_panel_settings_outlined,
          ),
        ),
        const SectionHeading('R2 storage'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: FutureBuilder<Map<String, dynamic>>(
            future: _storageQuota,
            builder: (context, snapshot) {
              if (localSpotPreviewRelease) {
                return const SoftCard(
                  child: Text(
                    'R2 quota tools need the configured backend and are disabled in the read-only preview.',
                  ),
                );
              }
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SoftCard(child: LinearProgressIndicator());
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return SoftCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Storage usage is unavailable.'),
                      TextButton(
                        onPressed: _refreshStorageQuota,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              }
              final data = snapshot.data!;
              final used = data['usedBytes'] as num? ?? 0;
              final reserved = data['reservedBytes'] as num? ?? 0;
              final limit = data['limitBytes'] as num? ?? 9000000000;
              final percent =
                  (data['usagePercent'] as num? ?? 0).toDouble().clamp(0, 100) /
                  100;
              final latest = data['latestReport'] as Map?;
              final orphanSamples =
                  (latest?['orphanedObjectSamples'] as List? ?? const [])
                      .whereType<String>();
              final latestAt = data['lastReconciledAt'] as String? ?? 'Never';
              final activity =
                  (data['recentActivity'] as List? ?? const []).cast<Map>();
              return SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Bucket quota',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          '${(data['usagePercent'] as num? ?? 0).toStringAsFixed(1)}%',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: percent),
                    const SizedBox(height: 10),
                    Text('Used: ${_storageSize(used)}'),
                    Text('Reserved: ${_storageSize(reserved)}'),
                    Text(
                      'Remaining: ${_storageSize(data['remainingBytes'] as num? ?? 0)}',
                    ),
                    Text('Limit: ${_storageSize(limit)}'),
                    Text(
                      'Images: ${data['storedImages'] ?? 0} · Panoramas: ${data['storedPanoramas'] ?? 0}',
                    ),
                    Text(
                      'Pending uploads: ${data['pendingUploads'] ?? 0} · Failed: ${data['failedUploads'] ?? 0}',
                    ),
                    Text(
                      'Orphans: ${data['orphanedObjects'] ?? 0} · Missing: ${data['missingObjects'] ?? 0}',
                    ),
                    Text(
                      'Uploads ${data['uploadEnabled'] == true ? 'enabled' : 'paused'} · Last check: $latestAt',
                    ),
                    if (latest != null)
                      Text(
                        'Latest reconciliation: ${latest['status'] ?? 'unknown'}',
                      ),
                    if (orphanSamples.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Orphaned objects need review',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      ...orphanSamples
                          .take(5)
                          .map(
                            (key) => Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _deleteStorageOrphan(key),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          ),
                    ],
                    if (activity.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Recent activity',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      ...activity
                          .take(5)
                          .map(
                            (entry) => Text(
                              '${entry['action'] ?? 'storage event'} · ${entry['createdAt'] ?? ''}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                    ],
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: _refreshStorageQuota,
                          child: const Text('Refresh'),
                        ),
                        TextButton(
                          onPressed: _runStorageReconciliation,
                          child: const Text('Reconcile now'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (app.auditLogs.isNotEmpty) ...[
          const SectionHeading('Audit log'),
          ...app.auditLogs
              .take(12)
              .map(
                (entry) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: SoftCard(
                    child: Text(
                      entry.action,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
        ],
        const SectionHeading('Stores'),
        ...app.stores.map(
          (store) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: SoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          store.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      StatusChip(
                        storeStatusLabel(store.status),
                        color:
                            store.status == StoreStatus.approved
                                ? leaf
                                : champagne,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    store.type.label,
                    style: const TextStyle(color: taupe, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  if (store.status == StoreStatus.pending)
                    Row(
                      children: [
                        TextButton(
                          onPressed: () async {
                            final error = await app.setStoreStatus(
                              store,
                              StoreStatus.approved,
                            );
                            if (error != null && context.mounted) {
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(error)));
                            }
                          },
                          child: const Text('Approve'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final error = await app.setStoreStatus(
                              store,
                              StoreStatus.rejected,
                            );
                            if (error != null && context.mounted) {
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(error)));
                            }
                          },
                          child: const Text('Decline'),
                        ),
                      ],
                    )
                  else if (store.status == StoreStatus.approved)
                    TextButton(
                      onPressed: () async {
                        final error = await app.setStoreStatus(
                          store,
                          StoreStatus.suspended,
                        );
                        if (error != null && context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text(error)));
                        }
                      },
                      child: const Text('Suspend'),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SectionHeading('Promotions'),
        ...app.promotions.map(
          (promo) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: SoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    promo.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${promo.offer} · ${promo.status.name}',
                    style: const TextStyle(color: taupe, fontSize: 12),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed:
                            () => app.setPromotionStatus(
                              promo,
                              PromotionStatus.approved,
                            ),
                        child: const Text('Approve'),
                      ),
                      TextButton(
                        onPressed:
                            () => app.setPromotionStatus(
                              promo,
                              PromotionStatus.rejected,
                            ),
                        child: const Text('Reject'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SectionHeading('Pilot feedback'),
        if (app.feedback.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: EmptyNote('No pilot notes yet.', icon: Icons.forum_outlined),
          )
        else
          ...app.feedback.map(
            (item) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.topic,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.body,
                      style: const TextStyle(
                        color: taupe,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SectionHeading('Reports'),
        ...app.reports.map(
          (report) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: SoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    report.target,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    report.reason,
                    style: const TextStyle(
                      color: taupe,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child:
                        report.resolved
                            ? const StatusChip('Resolved')
                            : TextButton(
                              onPressed: () => app.resolveReport(report),
                              child: const Text('Resolve'),
                            ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _sessionStatus(AppState app, Store store) {
  final session = app.sessionFor(store);
  if (session != null && session.isActive) {
    return 'Live sharing is on · last update ${freshness(session.lastUpdateAt)} · stops ${session.expiresAt.hour.toString().padLeft(2, '0')}:${session.expiresAt.minute.toString().padLeft(2, '0')}';
  }
  if (store.locationMode == LocationMode.stale) {
    return 'The last live session expired. Customers see the regular selling area.';
  }
  return 'Live sharing is off. Customers see this regular pin.';
}
