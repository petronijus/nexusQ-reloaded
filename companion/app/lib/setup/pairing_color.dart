import 'dart:ui';

/// LED visual-pairing color from the BT MAC. Contract + shared vectors:
/// companion/pairing-color-vectors.json (device twin: nexusq-setupd
/// pairing_color()).
Color pairingColor(String mac) {
  final b = mac.split(':').map((x) => int.parse(x, radix: 16)).toList();
  final hue = ((b[4] << 8) | b[5]) % 360;
  const c = 1.0;
  final x = 1.0 - ((hue / 60.0) % 2.0 - 1.0).abs();
  final sect = hue ~/ 60;
  final f = [
    [c, x, 0.0], [x, c, 0.0], [0.0, c, x],
    [0.0, x, c], [x, 0.0, c], [c, 0.0, x],
  ][sect];
  int ch(double v) => (v * 255 + 0.5).floor();
  return Color.fromARGB(255, ch(f[0]), ch(f[1]), ch(f[2]));
}
