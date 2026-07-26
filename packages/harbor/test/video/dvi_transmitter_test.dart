import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// DviTransmitter is the reusable TMDS backend: it takes parallel RGB plus
/// HSYNC/VSYNC/DE (from any source) and serializes them onto the four GPDI
/// lanes. It is structural (encoder/serializer are unit-tested), so this
/// verifies it elaborates and wires three encoders and four serializers onto a
/// 4-bit GPDI output.
void main() {
  test('elaborates with three encoders and four serializers', () async {
    final pixelClk = Logic(name: 'pixel_clk');
    final shiftClk = Logic(name: 'shift_clk');
    final pixelReset = Logic(name: 'pixel_reset');
    final shiftReset = Logic(name: 'shift_reset');
    final de = Logic(name: 'de');
    final hsync = Logic(name: 'hsync');
    final vsync = Logic(name: 'vsync');
    final red = Logic(name: 'red', width: 8);
    final green = Logic(name: 'green', width: 8);
    final blue = Logic(name: 'blue', width: 8);

    final tx = DviTransmitter(
      pixelClk: pixelClk,
      shiftClk: shiftClk,
      pixelReset: pixelReset,
      shiftReset: shiftReset,
      de: de,
      hsync: hsync,
      vsync: vsync,
      red: red,
      green: green,
      blue: blue,
    );
    await tx.build();
    final sv = tx.generateSynth();

    expect(tx.gpdi.width, equals(4));
    expect('TmdsEncoder'.allMatches(sv).length, greaterThanOrEqualTo(3));
    expect('TmdsSerializer'.allMatches(sv).length, greaterThanOrEqualTo(4));
  });
}
