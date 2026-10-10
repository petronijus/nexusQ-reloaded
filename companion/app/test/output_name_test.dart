// The output picker shows the app's own English names for the outputs it
// knows. Bridges before nexusq-control r65 label them in Czech
// ("Reproduktor", "Optický výstup"); the label a bridge sends is used only
// for an output id the app has no name for.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/models.dart';

void main() {
  test('known outputs are named in English, whatever the bridge labels', () {
    final outputs = [
      {'id': 'speaker', 'label': 'Reproduktor'},
      {'id': 'spdif', 'label': 'Optický výstup'},
      {'id': 'hdmi', 'label': 'HDMI'},
    ].map(AudioOutput.fromJson).toList();
    expect(outputs.map((o) => o.name), ['Speaker', 'Optical', 'HDMI']);
  });

  test("an unknown output keeps the bridge's label, or its id", () {
    expect(
      AudioOutput.fromJson({'id': 'usb', 'label': 'USB DAC'}).name,
      'USB DAC',
    );
    expect(AudioOutput.fromJson({'id': 'usb'}).name, 'usb');
  });

  test('the outputs shown before the bridge answers are named too', () {
    expect(kDefaultOutputs.map((o) => o.name), ['Speaker', 'Optical']);
  });
}
