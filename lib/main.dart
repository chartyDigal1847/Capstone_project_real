import 'package:flutter/material.dart';

import 'models.dart';
import 'screens/auth_screens.dart';
import 'screens/customer_screens.dart';
import 'screens/detail_screens.dart';
import 'screens/owner_screens.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

void main() => runApp(const LocalSpotRoot());

class LocalSpotRoot extends StatefulWidget {
  const LocalSpotRoot({super.key});
  @override
  State<LocalSpotRoot> createState() => _LocalSpotRootState();
}

class _LocalSpotRootState extends State<LocalSpotRoot> {
  final state = AppState();

  @override
  void initState() {
    super.initState();
    state.bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      notifier: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'LocalSpot',
        theme: localSpotTheme(),
        home: const LocalSpotShell(),
      ),
    );
  }
}

enum AuthView { welcome, login, register }

enum OverlayView {
  none,
  product,
  store,
  tour,
  location,
  report,
  cameraSearch,
  registerStore,
  addProduct,
  inventory,
  promotions,
  tourEditor,
  staff,
  storePin,
  feedback,
  admin,
  route,
}

class LocalSpotShell extends StatefulWidget {
  const LocalSpotShell({super.key});
  @override
  State<LocalSpotShell> createState() => _LocalSpotShellState();
}

class _LocalSpotShellState extends State<LocalSpotShell> {
  AuthView authView = AuthView.welcome;
  int tab = 0;
  OverlayView overlay = OverlayView.none;
  CatalogProduct? product;
  Store? store;
  StoreTour? tour;
  String reportTarget = '';

  void _openProduct(CatalogProduct value) => setState(() {
        product = value;
        overlay = OverlayView.product;
      });

  void _openStore(Store value) => setState(() {
        store = value;
        overlay = OverlayView.store;
      });

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    Widget body;
    var showNav = false;

    if (!app.signedIn) {
      body = switch (authView) {
        AuthView.welcome => WelcomePage(
            onLogin: () => setState(() => authView = AuthView.login),
            onRegister: () => setState(() => authView = AuthView.register),
          ),
        AuthView.login => LoginPage(
            onBack: () => setState(() => authView = AuthView.welcome),
            onRegister: () => setState(() => authView = AuthView.register),
            onSuccess: () => setState(() {
              tab = 0;
              overlay = OverlayView.none;
            }),
          ),
        AuthView.register => RegisterPage(
            onBack: () => setState(() => authView = AuthView.welcome),
            onSuccess: () => setState(() {
              tab = 0;
              overlay = OverlayView.none;
            }),
          ),
      };
    } else {
      showNav = overlay == OverlayView.none;
      body = switch (overlay) {
        OverlayView.product => ProductDetailPage(
            product: product!,
            onBack: () => setState(() => overlay = OverlayView.none),
            onStore: _openStore,
          ),
        OverlayView.store => StoreDetailPage(
            store: store!,
            onBack: () => setState(() => overlay = OverlayView.none),
            onProduct: _openProduct,
            onTour: () {
              final published = app.tourForStore(store!.id);
              if (published == null) return;
              setState(() {
                tour = published;
                overlay = OverlayView.tour;
              });
            },
            onReport: () => setState(() {
              reportTarget = store!.name;
              overlay = OverlayView.report;
            }),
            onRoute: () => setState(() => overlay = OverlayView.route),
          ),
        OverlayView.route => RoutePreviewPage(
            store: store!,
            onBack: () => setState(() => overlay = OverlayView.store),
          ),
        OverlayView.tour => TourViewerPage(tour: tour!, onBack: () => setState(() => overlay = OverlayView.store)),
        OverlayView.location => LocationPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.report => ReportPage(target: reportTarget, onBack: () => setState(() => overlay = OverlayView.store)),
        OverlayView.cameraSearch => CameraSearchPage(
            onBack: () => setState(() => overlay = OverlayView.none),
            onProduct: _openProduct,
            onStore: _openStore,
          ),
        OverlayView.registerStore => StoreRegisterPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.addProduct => AddProductPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.inventory => InventoryPage(
            onBack: () => setState(() => overlay = OverlayView.none),
            onAdd: () => setState(() => overlay = OverlayView.addProduct),
          ),
        OverlayView.promotions => PromotionsPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.tourEditor => TourEditorPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.staff => StaffPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.storePin => StorePinPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.feedback => FeedbackPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.admin => AdminPage(onBack: () => setState(() => overlay = OverlayView.none)),
        OverlayView.none => _tabBody(app),
      };
    }

    final destinations = _destinations(app.role);
    if (tab >= destinations.length) tab = 0;

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth > 700;
      return Scaffold(
        body: SizedBox.expand(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: wide ? 520 : constraints.maxWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: ivory,
                    boxShadow: wide ? [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 30)] : null,
                  ),
                  child: Material(
                    color: ivory,
                    child: SafeArea(bottom: !showNav, child: body),
                  ),
                ),
            ),
          ),
        ),
        bottomNavigationBar: showNav
            ? SizedBox(
                height: 72,
                child: Center(
                  child: Container(
                    width: wide ? 520 : constraints.maxWidth,
                    decoration: const BoxDecoration(color: paper, border: Border(top: BorderSide(color: line))),
                    child: NavigationBar(
                      height: 72,
                      backgroundColor: paper,
                      indicatorColor: const Color(0xFFDCE6D7),
                      selectedIndex: tab,
                      onDestinationSelected: (i) => setState(() => tab = i),
                      destinations: destinations,
                    ),
                  ),
                ),
              )
            : null,
      );
    });
  }

  Widget _tabBody(AppState app) {
    final ownerish = app.role == AppRole.owner || app.role == AppRole.staff;
    if (ownerish) {
      return switch (tab) {
        0 => OwnerDashboard(
            onAddProduct: () => setState(() => overlay = OverlayView.addProduct),
            onInventory: () => setState(() => overlay = OverlayView.inventory),
            onRegister: () => setState(() => overlay = OverlayView.registerStore),
            onPromos: () => setState(() => overlay = OverlayView.promotions),
            onTour: () => setState(() => overlay = OverlayView.tourEditor),
            onStaff: () => setState(() => overlay = OverlayView.staff),
            onPin: () => setState(() => overlay = OverlayView.storePin),
          ),
        1 => InventoryPage(
            onAdd: () => setState(() => overlay = OverlayView.addProduct),
          ),
        2 => const AddProductPage(),
        3 => const PromotionsPage(),
        _ => ProfilePage(
            onLocation: () => setState(() => overlay = OverlayView.location),
            onLogout: () => setState(() {
              AppScope.of(context).logout();
              authView = AuthView.welcome;
              tab = 0;
            }),
            onAdmin: () => setState(() => overlay = OverlayView.admin),
            onFeedback: () => setState(() => overlay = OverlayView.feedback),
          ),
      };
    }

    if (app.role == AppRole.admin) {
      return switch (tab) {
        0 => const AdminPage(),
        1 => SearchPage(onProduct: _openProduct, onStore: _openStore),
        2 => MapPage(
            onStore: _openStore,
            onRoute: (value) => setState(() {
              store = value;
              overlay = OverlayView.route;
            }),
          ),
        _ => ProfilePage(
            onLocation: () => setState(() => overlay = OverlayView.location),
            onLogout: () => setState(() {
              AppScope.of(context).logout();
              authView = AuthView.welcome;
              tab = 0;
            }),
            onAdmin: () => setState(() => overlay = OverlayView.admin),
            onFeedback: () => setState(() => overlay = OverlayView.feedback),
          ),
      };
    }

    return switch (tab) {
      0 => HomePage(
          onSearch: () => setState(() => tab = 1),
          onMap: () => setState(() => tab = 2),
          onStore: _openStore,
          onLocation: () => setState(() => overlay = OverlayView.location),
          onCameraSearch: () => setState(() => overlay = OverlayView.cameraSearch),
          onSaved: () => setState(() => tab = 3),
        ),
      1 => SearchPage(onProduct: _openProduct, onStore: _openStore),
      2 => MapPage(
          onStore: _openStore,
          onRoute: (value) => setState(() {
            store = value;
            overlay = OverlayView.route;
          }),
        ),
      3 => SavedPage(onProduct: _openProduct, onStore: _openStore),
      _ => ProfilePage(
          onLocation: () => setState(() => overlay = OverlayView.location),
          onLogout: () => setState(() {
            AppScope.of(context).logout();
            authView = AuthView.welcome;
            tab = 0;
          }),
          onAdmin: () => setState(() => overlay = OverlayView.admin),
          onFeedback: () => setState(() => overlay = OverlayView.feedback),
        ),
    };
  }

  List<NavigationDestination> _destinations(AppRole role) {
    if (role == AppRole.owner || role == AppRole.staff) {
      return const [
        NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.inventory_2_outlined), label: 'Inventory'),
        NavigationDestination(icon: Icon(Icons.photo_camera_outlined), label: 'Scan'),
        NavigationDestination(icon: Icon(Icons.campaign_outlined), label: 'Promos'),
        NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
      ];
    }
    if (role == AppRole.admin) {
      return const [
        NavigationDestination(icon: Icon(Icons.admin_panel_settings_outlined), label: 'Review'),
        NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
        NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
        NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
      ];
    }
    return const [
      NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
      NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
      NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
      NavigationDestination(icon: Icon(Icons.bookmark_border), selectedIcon: Icon(Icons.bookmark), label: 'Saved'),
      NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
    ];
  }
}
