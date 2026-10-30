import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'state.dart';
import 'theme.dart';

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState super.notifier, required super.child});

  static AppState of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.onBack, this.trailing, this.subtitle, this.onSubtitleTap});
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final VoidCallback? onSubtitleTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontFamily: 'Georgia', fontSize: 22, height: 1.1, color: charcoal)),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: taupe, fontSize: 13)),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Row(
        children: [
          if (onBack != null)
            IconButton.filledTonal(
              onPressed: onBack,
              style: IconButton.styleFrom(backgroundColor: paper, foregroundColor: charcoal),
              icon: const Icon(Icons.arrow_back_ios_new, size: 17),
            )
          else
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: leafDark,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [BoxShadow(color: Color(0x332E5A27), blurRadius: 10, offset: Offset(0, 4))],
              ),
              child: const Text('L', style: TextStyle(color: paper, fontFamily: 'Georgia', fontSize: 20)),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: onSubtitleTap == null ? titleBlock : InkWell(onTap: onSubtitleTap, borderRadius: BorderRadius.circular(8), child: titleBlock),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(color: taupe, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.4),
      );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.onTap, this.action = 'See all'});
  final String title;
  final VoidCallback? onTap;
  final String action;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontFamily: 'Georgia', fontSize: 21, color: charcoal))),
            if (onTap != null)
              TextButton(onPressed: onTap, child: Text(action, style: const TextStyle(color: taupe, fontSize: 11))),
          ],
        ),
      );
}

class SoftCard extends StatelessWidget {
  const SoftCard({super.key, required this.child, this.padding, this.onTap, this.color = paper});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final body = Container(
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: line),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, 8))],
      ),
      child: child,
    );
    return onTap == null ? body : Material(color: Colors.transparent, child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(18), child: body));
  }
}

class IconWell extends StatelessWidget {
  const IconWell(this.icon, {super.key, this.color = leafDark, this.size = 40});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, color: color, size: size * .46),
    );
  }
}

class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.iconColor = leafDark,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            IconWell(icon, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: charcoal)),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: const TextStyle(color: taupe, fontSize: 11, height: 1.35)),
                  ],
                ],
              ),
            ),
            trailing ?? (onTap == null ? const SizedBox.shrink() : const Icon(Icons.chevron_right, color: taupe)),
          ],
        ),
      ),
    );
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner(this.text, {super.key, this.icon = Icons.info_outline, this.tint = sand});
  final String text;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return SoftCard(
      color: tint,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: leafDark),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: charcoal, fontSize: 12, height: 1.45))),
        ],
      ),
    );
  }
}

class SeededDataBanner extends StatelessWidget {
  const SeededDataBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.usingSeededCatalog) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: InfoBanner(
        'Bundled Cubao sample listings. This is demo data, not a live nationwide catalog. Connect the LocalSpot API for participating stores.',
        icon: Icons.science_outlined,
      ),
    );
  }
}

class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key, this.icon = Icons.storefront_outlined});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SoftCard(
      child: Column(
        children: [
          IconWell(icon, size: 48, color: champagne),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: taupe, fontSize: 13, height: 1.45)),
        ],
      ),
    );
  }
}

class DashTile extends StatelessWidget {
  const DashTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SoftCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconWell(icon, color: leafDark),
          const Spacer(),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: charcoal)),
          const SizedBox(height: 4),
          Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: taupe, fontSize: 11, height: 1.3)),
        ],
      ),
    );
  }
}

class LabeledField extends StatelessWidget {
  const LabeledField(
    this.label,
    this.controller, {
    super.key,
    this.obscure = false,
    this.keyboardType,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Eyebrow(label),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          maxLines: obscure ? 1 : maxLines,
          decoration: InputDecoration(
            filled: true,
            fillColor: ivory,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: line)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: line)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: leaf, width: 1.4)),
          ),
        ),
      ],
    );
  }
}

class CaptureActions extends StatelessWidget {
  const CaptureActions({super.key, this.onCamera, this.onGallery, this.extra = const []});
  final VoidCallback? onCamera;
  final VoidCallback? onGallery;
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (onCamera != null)
          OutlinedButton.icon(onPressed: onCamera, icon: const Icon(Icons.photo_camera_outlined, size: 18), label: const Text('Camera')),
        if (onGallery != null)
          OutlinedButton.icon(onPressed: onGallery, icon: const Icon(Icons.photo_outlined, size: 18), label: const Text('Gallery')),
        ...extra,
      ],
    );
  }
}

class FilterMenu<T> extends StatelessWidget {
  const FilterMenu({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.selectedLabel,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String? selectedLabel;

  String get _closedLabel {
    if (selectedLabel != null && selectedLabel!.isNotEmpty) return selectedLabel!;
    return '$value';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 16,
          child: Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: taupe, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5, height: 1.2),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          child: Material(
            color: ivory,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: line),
            ),
            child: PopupMenuButton<T>(
              tooltip: label,
              initialValue: value,
              position: PopupMenuPosition.under,
              offset: const Offset(0, 4),
              color: paper,
              constraints: const BoxConstraints(maxHeight: 240, minWidth: 168),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: line)),
              onSelected: onChanged,
              itemBuilder: (context) => [
                for (final item in items)
                  PopupMenuItem<T>(
                    value: item.value,
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: item.child,
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _closedLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.2, color: charcoal),
                      ),
                    ),
                    const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: taupe),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Widget filterOptionLabel(String text, {bool nested = false}) {
  return Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: EdgeInsets.only(left: nested ? 12 : 0),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          height: 1.2,
          fontWeight: nested ? FontWeight.w500 : FontWeight.w600,
          color: charcoal,
        ),
      ),
    ),
  );
}

List<DropdownMenuItem<String>> productCategoryMenuItems() {
  final seen = <String>{};
  return [
    DropdownMenuItem(value: '', child: filterOptionLabel('All products')),
    for (final family in browseFamilies) ...[
      DropdownMenuItem(value: familyFilterValue(family.$2), child: filterOptionLabel('All ${family.$1}')),
      for (final category in categoryFamilies[family.$2] ?? const <String>[])
        if (seen.add(category)) DropdownMenuItem(value: category, child: filterOptionLabel(category, nested: true)),
    ],
    for (final category in productCategories)
      if (seen.add(category)) DropdownMenuItem(value: category, child: filterOptionLabel(category)),
  ];
}

class CatalogFilters extends StatelessWidget {
  const CatalogFilters({super.key, this.showCategory = true});
  final bool showCategory;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: FilterMenu<double>(
                    label: 'Distance',
                    value: app.radiusKm,
                    selectedLabel: '${app.radiusKm.toStringAsFixed(0)} km',
                    items: [
                      for (final km in radiiKm)
                        DropdownMenuItem(value: km, child: filterOptionLabel('${km.toStringAsFixed(0)} km')),
                    ],
                    onChanged: (km) {
                      if (km != null) app.setRadius(km);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilterMenu<String>(
                    label: 'Seller type',
                    value: app.typeFilter?.name ?? '',
                    selectedLabel: app.typeFilter?.label ?? 'All types',
                    items: [
                      DropdownMenuItem(value: '', child: filterOptionLabel('All types')),
                      for (final type in StoreType.values)
                        DropdownMenuItem(value: type.name, child: filterOptionLabel(type.label)),
                    ],
                    onChanged: (name) {
                      if (name == null || name.isEmpty) {
                        app.setTypeFilter(null);
                        return;
                      }
                      app.setTypeFilter(StoreType.values.firstWhere((type) => type.name == name));
                    },
                  ),
                ),
              ],
            ),
            if (showCategory) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: FilterMenu<String>(
                      label: 'Category',
                      value: app.categoryFilter ?? '',
                      selectedLabel: categoryFilterLabel(app.categoryFilter),
                      items: productCategoryMenuItems(),
                      onChanged: (category) => app.setCategoryFilter(category == null || category.isEmpty ? null : category),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilterMenu<SearchSort>(
                      label: 'Sort',
                      value: app.searchSort,
                      selectedLabel: searchSortLabel(app.searchSort),
                      items: [
                        for (final sort in SearchSort.values)
                          DropdownMenuItem(value: sort, child: filterOptionLabel(searchSortLabel(sort))),
                      ],
                      onChanged: (sort) {
                        if (sort != null) app.setSearchSort(sort);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.selected = false, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap?.call(),
          selectedColor: charcoal,
          labelStyle: TextStyle(color: selected ? paper : taupe, fontSize: 11),
          backgroundColor: paper,
          side: const BorderSide(color: line),
        ),
      );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, this.color = leaf});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700)),
      );
}

class StoreImageCard extends StatelessWidget {
  const StoreImageCard({
    super.key,
    required this.store,
    required this.distanceKm,
    required this.onTap,
    this.badge,
    this.width = 168,
    this.height = 188,
  });

  final Store store;
  final double distanceKm;
  final VoidCallback onTap;
  final String? badge;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              NetworkPhoto(store.image, radius: 0, width: width, height: height),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xA82A2A24)],
                  ),
                ),
              ),
              if (badge != null)
                Positioned(
                  top: 10,
                  left: 10,
                  child: StatusChip(badge!, color: champagne),
                ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(store.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: paper, fontWeight: FontWeight.w700, fontSize: 14, height: 1.2)),
                    const SizedBox(height: 2),
                    Text('${store.type.label} · ${distanceKm.toStringAsFixed(1)} km', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFE8DED0), fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NetworkPhoto extends StatelessWidget {
  const NetworkPhoto(this.url, {super.key, this.height, this.width, this.radius = 14});
  final String? url;
  final double? height;
  final double? width;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      height: height,
      width: width,
      color: sand,
      child: Icon(url == null ? Icons.storefront_outlined : Icons.image_outlined, color: taupe),
    );
    Widget image = fallback;
    if (url != null) {
      final source = url!.split('#').first;
      final remote = source.startsWith('http://') || source.startsWith('https://');
      image = (!kIsWeb && !remote)
          ? Image.file(File(source), height: height, width: width, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback)
          : Image.network(source, height: height, width: width, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: (width == null && height == null) ? SizedBox.expand(child: image) : image,
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: leafDark,
            foregroundColor: paper,
            padding: const EdgeInsets.all(16),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          child: Text(label),
        ),
      );
}

String peso(double value) => '₱${value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2)}';

String freshness(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 60) return 'Confirmed ${diff.inMinutes} min ago';
  if (diff.inHours < 24) return 'Confirmed ${diff.inHours}h ago';
  return 'Confirmed ${diff.inDays}d ago';
}

String availabilityLabel(Availability value) => switch (value) {
      Availability.inStock => 'In stock',
      Availability.low => 'Low stock',
      Availability.unavailable => 'Unavailable',
    };

String storeStatusLabel(StoreStatus value) => switch (value) {
      StoreStatus.pending => 'Pending review',
      StoreStatus.approved => 'Approved',
      StoreStatus.suspended => 'Suspended',
    };

String roleLabel(AppRole role) => switch (role) {
      AppRole.customer => 'Customer',
      AppRole.owner => 'Store owner',
      AppRole.staff => 'Staff',
      AppRole.admin => 'Admin',
    };
