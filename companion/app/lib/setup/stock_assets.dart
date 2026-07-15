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
    {Key? key,
    double? width,
    double? height,
    IconData fallback = Icons.image,
    Color? color}) {
  if (!StockAssets.available) {
    return Icon(key: key, fallback, size: width ?? height ?? 48, color: color);
  }
  return Image.asset('assets/stock/drawable/$name',
      key: key,
      width: width,
      height: height,
      fit: BoxFit.contain,
      // gaplessPlayback: keep the current frame on screen until the next one
      // has decoded, instead of blanking between swaps — kills the flicker on
      // the frame-by-frame welcome sphere animation.
      gaplessPlayback: true);
}
