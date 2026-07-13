import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Loader for the (gitignored) original stock imagery. When the assets were
/// not extracted (public checkout without private/), every screen falls back
/// to Material icons — the wizard must work either way.
class StockAssets {
  static bool available = false;

  /// Call once at app start: probe one sentinel asset.
  static Future<void> init() async {
    try {
      await rootBundle.load('assets/stock/drawable/setup_static.png');
      available = true;
    } catch (_) {
      available = false;
    }
  }
}

/// A stock drawable by basename, or [fallback] icon when unavailable.
Widget stockImage(String name,
    {double? width, double? height, IconData fallback = Icons.image, Color? color}) {
  if (!StockAssets.available) {
    return Icon(fallback, size: width ?? height ?? 48, color: color);
  }
  return Image.asset('assets/stock/drawable/$name',
      width: width, height: height, fit: BoxFit.contain);
}
