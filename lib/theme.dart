import 'package:flutter/material.dart';

const ivory = Color(0xFFF6F1E8);
const paper = Color(0xFFFFFDF8);
const charcoal = Color(0xFF2A2A24);
const taupe = Color(0xFF7A7368);
const line = Color(0xFFE4DCCF);
const sand = Color(0xFFE8DED0);
const leaf = Color(0xFF2F6B4F);
const leafDark = Color(0xFF1E4A36);
const champagne = Color(0xFFC4A56B);
const clay = Color(0xFF9E514B);

ThemeData localSpotTheme() {
  const radius = BorderRadius.all(Radius.circular(16));
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: ivory,
    colorScheme: ColorScheme.fromSeed(seedColor: leaf, surface: ivory, primary: leafDark),
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: ivory,
      foregroundColor: charcoal,
      elevation: 0,
    ),
    dividerColor: line,
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: paper,
      indicatorColor: Color(0xFFDCE6D7),
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: leafDark,
        foregroundColor: paper,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: leafDark,
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: leafDark,
        side: const BorderSide(color: line),
        shape: const RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: paper,
      hintStyle: const TextStyle(color: Color(0xFF9A9388), fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: leaf, width: 1.4)),
    ),
    chipTheme: ChipThemeData(
      selectedColor: charcoal,
      backgroundColor: paper,
      side: const BorderSide(color: line),
      labelStyle: const TextStyle(fontSize: 11, color: taupe),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
  );
}
