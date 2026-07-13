import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/setup/pairing_color.dart';

void main() {
  test('matches the shared vectors', () {
    final raw = File('../pairing-color-vectors.json').readAsStringSync();
    final vectors = (jsonDecode(raw)['vectors'] as List).cast<Map<String, dynamic>>();
    for (final v in vectors) {
      final rgb = (v['rgb'] as List).cast<int>();
      final c = pairingColor(v['mac'] as String);
      expect(c, Color.fromARGB(255, rgb[0], rgb[1], rgb[2]), reason: v['mac'] as String);
    }
  });
}
